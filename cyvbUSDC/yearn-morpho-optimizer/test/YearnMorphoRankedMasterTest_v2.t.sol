// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseStrategy} from "../contracts/YearnBaseStrategyKatana_v1.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {YearnMorphoRankedMaster_v2} from "../contracts/YearnMorphoRankedMaster_v2.sol";

contract MockAssetRankedV1 is ERC20 {
    constructor() ERC20("Mock vbUSDC", "mvbUSDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Test child uses genuine Yearn V3 ERC4626 delegatecall accounting.
///      Morpho integration belongs to separate Katana fork qualification.
contract MockReportedChildV1 is BaseStrategy {
    MockAssetRankedV1 public immutable underlying;
    uint256 public pendingGain;
    uint256 public claimCount;

    constructor(address token) BaseStrategy(token, "Reported child") {
        underlying = MockAssetRankedV1(token);
    }

    function setNextGain(uint256 gain) external { pendingGain = gain; }

    function claimAndCompound(
        address[] calldata, address[] calldata, uint256[] calldata,
        bytes32[][] calldata, uint256, uint256
    ) external returns (uint256 gain) {
        gain = pendingGain;
        pendingGain = 0;
        claimCount++;
        if (gain != 0) underlying.mint(address(this), gain);
    }

    function _deployFunds(uint256) internal override {}
    function _freeFunds(uint256) internal override {}
    function _harvestAndReport() internal view override returns (uint256) {
        return underlying.balanceOf(address(this));
    }
}

contract YearnMorphoRankedMasterTest_v2 is Test {
    MockAssetRankedV1 asset;
    YearnMorphoRankedMaster_v2 master;
    MockReportedChildV1 a;
    MockReportedChildV1 b;
    MockReportedChildV1 c;
    uint256 constant UNIT = 1e18;

    function setUp() public {
        vm.warp(1000);
        TokenizedStrategy impl = new TokenizedStrategy(address(0));
        // The test contract's second CREATE deterministically uses Yearn's
        // fixture implementation address. Consume that nonce before etching.
        new MockAssetRankedV1();
        asset = new MockAssetRankedV1();
        vm.etch(0x310f5Db015E9d6E542fd41bd4542640790791e76, address(impl).code);
        master = new YearnMorphoRankedMaster_v2(address(asset), "Master");
        ITokenizedStrategy(address(master)).setPerformanceFee(0);
        a = _child();
        b = _child();
        master.addChild(address(a));
        master.addChild(address(b));
        asset.mint(address(this), 1000 * UNIT);
        asset.approve(address(master), type(uint256).max);
        ITokenizedStrategy(address(master)).deposit(1000 * UNIT, address(this));
    }

    function _child() internal returns (MockReportedChildV1 result) {
        result = new MockReportedChildV1(address(asset));
        ITokenizedStrategy(address(result)).setPerformanceFee(0);
        ITokenizedStrategy(address(result)).setProfitMaxUnlockTime(0);
        ITokenizedStrategy(address(result)).setKeeper(address(master));
    }

    function _claims() internal view returns (YearnMorphoRankedMaster_v2.ClaimBundle[] memory result) {
        uint256 n = master.childCount();
        result = new YearnMorphoRankedMaster_v2.ClaimBundle[](n);
        for (uint256 i; i < n; ++i) {
            result[i].child = master.children(i);
        }
    }

    function testDefault70_30AndWinnerReallocation() public {
        assertApproxEqAbs(ITokenizedStrategy(address(a)).convertToAssets(ITokenizedStrategy(address(a)).balanceOf(address(master))), 69996 * UNIT / 100, 2);
        assertApproxEqAbs(ITokenizedStrategy(address(b)).convertToAssets(ITokenizedStrategy(address(b)).balanceOf(address(master))), 30004 * UNIT / 100, 2);
        b.setNextGain(30 * UNIT);
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        assertEq(master.lastRanking(0), address(b), "higher PPS winner");
        assertEq(master.lastRanking(1), address(a), "runner up");
        assertEq(a.claimCount(), 1, "claim before reporting");
        assertEq(b.claimCount(), 1);
        uint256 bValue = ITokenizedStrategy(address(b)).convertToAssets(ITokenizedStrategy(address(b)).balanceOf(address(master)));
        uint256 aValue = ITokenizedStrategy(address(a)).convertToAssets(ITokenizedStrategy(address(a)).balanceOf(address(master)));
        assertApproxEqAbs(bValue, (1030 * UNIT - 2 * master.minimumChildDeposit()) * 70 / 100 + master.minimumChildDeposit(), 3);
        assertApproxEqAbs(aValue, (1030 * UNIT - 2 * master.minimumChildDeposit()) * 30 / 100 + master.minimumChildDeposit(), 3);
    }

    function testThreeRanksOwnerConfig() public {
        c = _child();
        master.addChild(address(c));
        // Probe funding is required to establish a PPS track record in
        // an otherwise unallocated third strategy.
        master.setProbeBps(50);
        asset.mint(address(this), 100 * UNIT);
        ITokenizedStrategy(address(master)).deposit(100 * UNIT, address(this));
        uint16[] memory weights = new uint16[](3);
        weights[0] = 6000;
        weights[1] = 3000;
        weights[2] = 1000;
        master.setRankWeights(weights);
        c.setNextGain(1e15); // modest 0.2% PPS increase on the 0.5-token probe
        b.setNextGain(10 * UNIT);
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        assertEq(master.lastRanking(0), address(b));
        assertEq(master.lastRanking(1), address(c));
        assertEq(master.lastRanking(2), address(a));
        uint256 sum = asset.balanceOf(address(master));
        for (uint256 i; i < master.childCount(); ++i) {
            MockReportedChildV1 child = MockReportedChildV1(master.children(i));
            sum += ITokenizedStrategy(address(child)).convertToAssets(ITokenizedStrategy(address(child)).balanceOf(address(master)));
        }
        assertApproxEqAbs(sum, 1110 * UNIT + 1e15, 4);
    }

    function testOneHundredPercentSingleWinnerAndRemoveSecond() public {
        a.setNextGain(5 * UNIT);
        // Owner can disable floor before removing an unused child.
        master.setMinimumChildDeposit(0);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;
        master.setRankWeights(weights);
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        assertEq(master.lastRanking(0), address(a));
        assertEq(ITokenizedStrategy(address(b)).balanceOf(address(master)), 0);
        master.removeChild(address(b));
        assertEq(master.childCount(), 1);
    }

    function testRejectsUnreportedChildProfitLock() public {
        ITokenizedStrategy(address(b)).setProfitMaxUnlockTime(1 days);
        vm.warp(block.timestamp + 1 days);
        YearnMorphoRankedMaster_v2.ClaimBundle[] memory bundles = _claims();
        vm.expectRevert(YearnMorphoRankedMaster_v2.BadChild.selector);
        master.optimizeFunds(bundles);
    }

    function testRejectsExternalReportBeforeCycle() public {
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        vm.warp(block.timestamp + 1 days);
        ITokenizedStrategy(address(a)).report();
        YearnMorphoRankedMaster_v2.ClaimBundle[] memory bundles = _claims();
        vm.expectRevert(YearnMorphoRankedMaster_v2.UnauthorizedReport.selector);
        master.optimizeFunds(bundles);
    }
    function testDefaultMinimumIsOneTenthToken() public {
        assertEq(master.minimumChildDeposit(), UNIT / 10);
        assertGe(ITokenizedStrategy(address(a)).convertToAssets(
            ITokenizedStrategy(address(a)).balanceOf(address(master))), UNIT / 10);
        assertGe(ITokenizedStrategy(address(b)).convertToAssets(
            ITokenizedStrategy(address(b)).balanceOf(address(master))), UNIT / 10);
    }

    function testOwnerUpdatesMinimumAndSeedsNewChild() public {
        master.setMinimumChildDeposit(2 * UNIT);
        c = _child();
        master.addChild(address(c));
        asset.mint(address(this), 10 * UNIT);
        ITokenizedStrategy(address(master)).deposit(10 * UNIT, address(this));
        assertGe(ITokenizedStrategy(address(c)).convertToAssets(
            ITokenizedStrategy(address(c)).balanceOf(address(master))), 2 * UNIT);
    }

    function testRejectsInsufficientCapitalForMinimums() public {
        master.setMinimumChildDeposit(600 * UNIT);
        asset.mint(address(this), 1 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(YearnMorphoRankedMaster_v2.InsufficientSeedCapital.selector, 1200 * UNIT, 1001 * UNIT));
        ITokenizedStrategy(address(master)).deposit(1 * UNIT, address(this));
    }

}

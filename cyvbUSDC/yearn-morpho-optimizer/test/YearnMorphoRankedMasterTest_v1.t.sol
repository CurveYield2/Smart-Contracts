// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {YearnMorphoRankedMaster_v1} from "../contracts/YearnMorphoRankedMaster_v1.sol";

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

contract YearnMorphoRankedMasterTest_v1 is Test {
    MockAssetRankedV1 asset;
    YearnMorphoRankedMaster_v1 master;
    MockReportedChildV1 a;
    MockReportedChildV1 b;
    MockReportedChildV1 c;
    uint256 constant UNIT = 1e18;

    function setUp() public {
        vm.warp(1000);
        TokenizedStrategy impl = new TokenizedStrategy(address(0));
        vm.etch(0x2e234DAe75C793f67A35089C9d99245E1C58470b, address(impl).code);
        asset = new MockAssetRankedV1();
        master = new YearnMorphoRankedMaster_v1(address(asset), "Master");
        master.setPerformanceFee(0);
        a = _child();
        b = _child();
        master.addChild(address(a));
        master.addChild(address(b));
        asset.mint(address(this), 1000 * UNIT);
        asset.approve(address(master), type(uint256).max);
        master.deposit(1000 * UNIT, address(this));
    }

    function _child() internal returns (MockReportedChildV1 result) {
        result = new MockReportedChildV1(address(asset));
        result.setPerformanceFee(0);
        result.setProfitMaxUnlockTime(0);
        result.setKeeper(address(master));
    }

    function _claims() internal view returns (YearnMorphoRankedMaster_v1.ClaimBundle[] memory result) {
        uint256 n = master.childCount();
        result = new YearnMorphoRankedMaster_v1.ClaimBundle[](n);
        for (uint256 i; i < n; ++i) {
            result[i].child = master.children(i);
        }
    }

    function testDefault70_30AndWinnerReallocation() public {
        assertApproxEqAbs(a.convertToAssets(a.balanceOf(address(master))), 700 * UNIT, 2);
        assertApproxEqAbs(b.convertToAssets(b.balanceOf(address(master))), 300 * UNIT, 2);
        b.setNextGain(30 * UNIT);
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        assertEq(master.lastRanking(0), address(b), "higher PPS winner");
        assertEq(master.lastRanking(1), address(a), "runner up");
        assertEq(a.claimCount(), 1, "claim before reporting");
        assertEq(b.claimCount(), 1);
        uint256 bValue = b.convertToAssets(b.balanceOf(address(master)));
        uint256 aValue = a.convertToAssets(a.balanceOf(address(master)));
        assertApproxEqAbs(bValue, 721 * UNIT, 3);
        assertApproxEqAbs(aValue, 309 * UNIT, 3);
    }

    function testThreeRanksOwnerConfig() public {
        c = _child();
        master.addChild(address(c));
        uint16[] memory weights = new uint16[](3);
        weights[0] = 6000;
        weights[1] = 3000;
        weights[2] = 1000;
        master.setRankWeights(weights);
        c.setNextGain(5 * UNIT);
        b.setNextGain(10 * UNIT);
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        assertEq(master.lastRanking(0), address(b));
        assertEq(master.lastRanking(1), address(c));
        assertEq(master.lastRanking(2), address(a));
        uint256 sum = asset.balanceOf(address(master));
        for (uint256 i; i < master.childCount(); ++i) {
            MockReportedChildV1 child = MockReportedChildV1(master.children(i));
            sum += child.convertToAssets(child.balanceOf(address(master)));
        }
        assertApproxEqAbs(sum, 1015 * UNIT, 4);
    }

    function testOneHundredPercentSingleWinnerAndRemoveSecond() public {
        a.setNextGain(5 * UNIT);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;
        master.setRankWeights(weights);
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        assertEq(master.lastRanking(0), address(a));
        assertEq(b.balanceOf(address(master)), 0);
        master.removeChild(address(b));
        assertEq(master.childCount(), 1);
    }

    function testRejectsUnreportedChildProfitLock() public {
        b.setProfitMaxUnlockTime(1 days);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(YearnMorphoRankedMaster_v1.BadChild.selector);
        master.optimizeFunds(_claims());
    }

    function testRejectsExternalReportBeforeCycle() public {
        vm.warp(block.timestamp + 1 days);
        master.optimizeFunds(_claims());
        vm.warp(block.timestamp + 1 days);
        a.report();
        vm.expectRevert(YearnMorphoRankedMaster_v1.UnauthorizedReport.selector);
        master.optimizeFunds(_claims());
    }
}

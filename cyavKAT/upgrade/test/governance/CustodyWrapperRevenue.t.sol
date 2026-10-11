// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldRevenueCustodyV2} from "../../src/protection/CurveYieldRevenueCustodyV2.sol";

contract WrapperAssetMock is ERC20 {
    constructor() ERC20("avKAT", "AVKAT") {}
    function mint(address account, uint256 amount) external { _mint(account, amount); }
}

contract WrapperSharesMock is ERC20 {
    IERC20 public immutable UNDERLYING;
    constructor(IERC20 underlying) ERC20("cyavKAT", "cyavKAT") { UNDERLYING = underlying; }
    function mint(address account, uint256 amount) external { _mint(account, amount); }
    function convertToAssets(uint256 shares) external pure returns (uint256) { return shares; }
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(msg.sender == owner, "owner only");
        _burn(owner, shares);
        require(UNDERLYING.transfer(receiver, shares), "underlying transfer");
        return shares;
    }
}

contract WrapperLoopMock {
    uint256 public deployments;
    function deployAll() external { deployments++; }
    function positionSnapshot() external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }
}

contract CustodyWrapperRevenueTest is Test {
    CurveYieldRevenueCustodyV2 custody;
    WrapperSharesMock vault;
    WrapperLoopMock loop;
    address outsider = makeAddr("outsider");
    address constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;

    function setUp() public {
        WrapperAssetMock assetCode = new WrapperAssetMock();
        vm.etch(AVKAT, address(assetCode).code);
        vm.etch(KAT, address(assetCode).code);
        vault = new WrapperSharesMock(IERC20(AVKAT));
        loop = new WrapperLoopMock();
        address[] memory operators = new address[](0);
        custody = new CurveYieldRevenueCustodyV2(
            address(this), address(this), address(vault), address(0x1234),
            address(0x5678), address(loop), address(0x99AB), operators
        );
        vault.mint(address(custody), 100 ether);
        WrapperAssetMock(AVKAT).mint(address(vault), 100 ether);
    }

    function test_unredeemedSharesNotPartOfFarmAllocationOrVaultBalanceFuse() public {
        assertEq(vault.balanceOf(address(custody)), 100 ether);
        assertEq(custody.farmValueAvkat(), 0);
        assertEq(custody.idleAvkat(), 0);
        assertEq(custody.polBudgetAvkat(), 0);
    }

    function test_redeemToLoop_keepsPolReserveEmptyAndLeavesNoWrapperShares() public {
        uint256 out = custody.redeemWrapperRevenue(100 ether, 100 ether);
        assertEq(out, 100 ether);
        assertEq(vault.balanceOf(address(custody)), 0);
        assertEq(IERC20(AVKAT).balanceOf(address(custody)), 100 ether);
        custody.deployAll();
        assertEq(IERC20(AVKAT).balanceOf(address(loop)), 100 ether);
        assertEq(custody.polBudgetAvkat(), 0);
        assertEq(loop.deployments(), 1);
    }

    function test_redeemThenReservePol_doesNotRouteReservedAvkatToLoop() public {
        custody.redeemWrapperRevenue(100 ether, 100 ether);
        custody.reserveAvkatForPolBps(4_000);
        assertEq(custody.polBudgetAvkat(), 40 ether);
        assertEq(custody.idleAvkat(), 60 ether);
        custody.deployAll();
        assertEq(IERC20(AVKAT).balanceOf(address(loop)), 60 ether);
        assertEq(IERC20(AVKAT).balanceOf(address(custody)), 40 ether);
        assertEq(custody.polBudgetAvkat(), 40 ether);
    }

    function test_minimumRedemptionIsAtomicAndAccessControlled() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldRevenueCustodyV2.NotOperator.selector, outsider));
        custody.redeemWrapperRevenue(1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldRevenueCustodyV2.WrapperRedeemBelowMinimum.selector, 10 ether, 11 ether));
        custody.redeemWrapperRevenue(10 ether, 11 ether);
        assertEq(vault.balanceOf(address(custody)), 100 ether);
        assertEq(IERC20(AVKAT).balanceOf(address(custody)), 0);
    }

    function test_reservationIsOnlyOperatorControlledAndDoesNotAllocateExternalFees() public {
        WrapperAssetMock(AVKAT).mint(address(custody), 70 ether);
        custody.reserveAvkatForPolBps(2_000);
        assertEq(custody.polBudgetAvkat(), 14 ether);
        assertEq(custody.idleAvkat(), 56 ether);
        custody.reserveAvkatForPolBps(0);
        assertEq(custody.polBudgetAvkat(), 0, "no feeder budget remains");
        assertEq(custody.idleAvkat(), 70 ether);
    }

    function test_partialWrapperRedeemKeepsOtherRevenueOffBooks() public {
        assertEq(vault.balanceOf(address(custody)), 100 ether);
        uint256 redeemed = custody.redeemWrapperRevenue(37 ether, 37 ether);
        assertEq(redeemed, 37 ether);
        assertEq(vault.balanceOf(address(custody)), 63 ether);
        assertEq(custody.idleAvkat(), 37 ether);
        assertEq(custody.polBudgetAvkat(), 0);
    }

    function test_polReservationsAreWholeBalanceBpsReplaceableAndOperatorOnly() public {
        custody.redeemWrapperRevenue(100 ether, 100 ether);
        custody.reserveAvkatForPolBps(4_000);
        assertEq(custody.polBudgetAvkat(), 40 ether);
        assertEq(custody.idleAvkat(), 60 ether);
        // Same target does not double-reserve; reducing it releases the excess allocation.
        custody.reserveAvkatForPolBps(4_000);
        assertEq(custody.polBudgetAvkat(), 40 ether);
        custody.reserveAvkatForPolBps(2_500);
        assertEq(custody.polBudgetAvkat(), 25 ether);
        custody.reserveAvkatForPolBps(0);
        assertEq(custody.polBudgetAvkat(), 0);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldRevenueCustodyV2.InvalidPolReserveBps.selector, 10_001));
        custody.reserveAvkatForPolBps(10_001);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldRevenueCustodyV2.NotOperator.selector, outsider));
        custody.reserveAvkatForPolBps(100);
    }
}

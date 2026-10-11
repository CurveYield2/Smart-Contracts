// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";

struct InstantWithdrawalFusesParamsStruct {
    address fuse;
    bytes32[] params;
}

interface IDepositFeeP23 {
    function setDepositFee(uint256 fee) external;
    function getDepositFee() external view returns (uint256);
}

interface IVaultCutover {
    function addFuses(address[] calldata fuses) external;
    function removeFuses(address[] calldata fuses) external;
    function execute(FuseAction[] calldata calls) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses) external;
    function getInstantWithdrawalFuses() external view returns (address[] memory);
}

interface IAccessManagerCutover {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
    function revokeRole(uint64 roleId, address account) external;
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
}

interface IWmCutover {
    function activeRequestedShares() external view returns (uint256);
    function getSharesToRelease() external view returns (uint256);
    function setDependencies(address controller, address burnFuse, address requestFeeFuse, address previousManager) external;
    function controller() external view returns (address);
}

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface IVkatNftP23 {
    function balanceOf(address owner) external view returns (uint256);
}

/// M3 / M4a (IPOR_FUSE_CONFORMANCE_SPEC §6): the cutover. Refuses to run unless the old withdraw manager has no open or
/// released requests and holds no fee shares, and unless the vault holds no vKAT (F5: removal needs no wind-down). In order:
///   1. executor: ALPHA (200), UPDATE_MARKETS_BALANCES (1000), UPDATE_REWARDS_BALANCE (1100: the profit split pays the rewards
///      manager); WM v2: ALPHA. The executor claims nothing: Merkl claiming leaves the vault (D11)
///   2. vault withdraw manager -> WM v2 (IPOR UpdateWithdrawManagerMaintenanceFuse: added, executed, removed)
///   3. WM v2 dependencies: controller = executor, fresh burn fuse, request-fee fuse = CurveYieldRequestFeeSharesFuse
///      (rotates the allowance)
///   4. instant withdrawals: ONLY official fuses that pay avKAT: lending (IPOR MorphoSupplyFuse). The loop and the USDC
///      strategy are served through withdrawal requests (B3, D6)
///   5. revoke ALPHA from ControllerV2 and the old withdraw manager, CLAIM_REWARDS from ControllerV2
/// The rewards claim manager keeps vesting its avKAT; its reward fuses go in P2_04. Old v1 fuses stay installed but inert (no
/// controller can call them) until P2_04.
///
///   forge script script/P2_03_Cutover.s.sol --root <upgrade path> --rpc-url katana     (add --broadcast ... to send)
contract P2_03_Cutover is Phase2Base {
    address internal constant FEE_MANAGER_P23 = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        string memory d = _readDeployments();
        address executor = _addr(d, "executor");
        address wm = _addr(d, "withdrawManagerV2");
        address maintenance = _addr(d, "withdrawManagerMaintenanceFuse");
        IAccessManagerCutover am = IAccessManagerCutover(ACCESS_MANAGER);
        IVaultCutover vault = IVaultCutover(VAULT);

        require(IWmCutover(WM_OLD).activeRequestedShares() == 0, "old WM has open requests");
        require(IWmCutover(WM_OLD).getSharesToRelease() == 0, "old WM has released, unredeemed shares");
        require(IBalanceOf(VAULT).balanceOf(WM_OLD) == 0, "old WM holds fee shares");
        require(IVkatNftP23(VKAT_NFT).balanceOf(VAULT) == 0, "F5: the vault still holds vKAT locks");

        _start();
        am.grantRole(ROLE_ALPHA, executor, 0);
        am.grantRole(ROLE_UPDATE_MARKETS_BALANCES, executor, 0);
        am.grantRole(1100, executor, 0); // UPDATE_REWARDS_BALANCE: the executor's profit split calls RCM.updateBalance
        am.grantRole(ROLE_ALPHA, wm, 0);

        address[] memory one = new address[](1);
        one[0] = maintenance;
        vault.addFuses(one);
        FuseAction[] memory sw = new FuseAction[](1);
        sw[0] = FuseAction(maintenance, abi.encodeWithSignature("enter((address))", wm));
        vault.execute(sw);
        vault.removeFuses(one);

        IWmCutover(wm).setDependencies(executor, _addr(d, "burnRequestFeeFuse"), _addr(d, "requestFeeSharesFuse"), WM_OLD);

        // B3: only the lending supply fuse (official, pays avKAT) is an instant source
        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = LEND_MARKET; // IPOR MorphoSupplyFuse: [amount, morphoMarketId]
        iw[0] = InstantWithdrawalFusesParamsStruct(_addr(d, "lendSupplyFuse"), lendParams);
        vault.configureInstantWithdrawalFuses(iw);
        // ONBOARDING_FEE_SPEC: 0.30% onboarding (deposit) fee, minted to WM v2 (now the vault's withdraw manager)
        IDepositFeeP23(FEE_MANAGER_P23).setDepositFee(0.003e18);

        am.revokeRole(ROLE_ALPHA, CONTROLLER_V2);
        am.revokeRole(ROLE_CLAIM_REWARDS, CONTROLLER_V2);
        am.revokeRole(ROLE_ALPHA, WM_OLD);
        _stop();

        // post-conditions
        require(address(uint160(uint256(vm.load(VAULT, WITHDRAW_MANAGER_SLOT)))) == wm, "vault WM not switched");
        require(IWmCutover(wm).controller() == executor, "WM v2 controller");
        (bool alpha,) = am.hasRole(ROLE_ALPHA, executor);
        (bool oldAlpha,) = am.hasRole(ROLE_ALPHA, CONTROLLER_V2);
        require(alpha && !oldAlpha, "ALPHA not moved");
        require(vault.getInstantWithdrawalFuses().length == 1, "instant withdrawal fuses");
        console2.log("cutover complete: executor", executor, "withdraw manager v2", wm);
    }
}

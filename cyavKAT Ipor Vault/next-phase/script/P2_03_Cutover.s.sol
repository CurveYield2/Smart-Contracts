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

interface IRcmCutover {
    function addRewardFuses(address[] calldata fuses) external;
    function isRewardFuseSupported(address fuse) external view returns (bool);
}

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// Phase 2 step 3/3: the cutover. Refuses to run unless the old withdraw manager has no open or released requests and
/// holds no fee shares. In order:
///   1. executor: ALPHA (200), UPDATE_MARKETS_BALANCES (1000), CLAIM_REWARDS (600); WM v2: ALPHA
///   2. vault withdraw manager -> WM v2 (IPOR UpdateWithdrawManagerMaintenanceFuse: added, executed, removed)
///   3. rewards claim manager: reward fuses = IPOR MerklClaimFuse + swap fuse v2 (harvest: claim, then sweep to avKAT)
///   4. WM v2 dependencies: controller = executor, fresh burn fuse, request-fee fuse = the withdrawal request fuse
///      (rotates the allowance). The live CallerRewardFuse 0x70a2 is no longer used by cyavKAT.
///   5. instant withdrawals: lending (IPOR supply fuse) -> vKAT -> LP (generic planned fuse; each never reverts)
///   6. revoke ALPHA from ControllerV2 and the old withdraw manager, CLAIM_REWARDS from ControllerV2
/// Old v1 fuses stay installed but inert (no controller can call them); remove them later (#4).
///
///   forge script script/P2_03_Cutover.s.sol --root <phase2 path> --rpc-url katana     (add --broadcast ... to send)
contract P2_03_Cutover is Phase2Base {
    address internal constant FEE_MANAGER_P23 = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;
    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory d = _readDeployments();
        address executor = _addr(d, "executor");
        address wm = _addr(d, "withdrawManagerV2");
        address maintenance = _addr(d, "withdrawManagerMaintenanceFuse");
        IAccessManagerCutover am = IAccessManagerCutover(ACCESS_MANAGER);
        IVaultCutover vault = IVaultCutover(VAULT);

        require(IWmCutover(WM_OLD).activeRequestedShares() == 0, "old WM has open requests");
        require(IWmCutover(WM_OLD).getSharesToRelease() == 0, "old WM has released, unredeemed shares");
        require(IBalanceOf(VAULT).balanceOf(WM_OLD) == 0, "old WM holds fee shares");

        _start();
        am.grantRole(ROLE_ALPHA, executor, 0);
        am.grantRole(ROLE_UPDATE_MARKETS_BALANCES, executor, 0);
        am.grantRole(ROLE_CLAIM_REWARDS, executor, 0);
        am.grantRole(ROLE_ALPHA, wm, 0);
        am.grantRole(1100, executor, 0); // UPDATE_REWARDS_BALANCE: the executor's profit split calls RCM.updateBalance

        address[] memory one = new address[](1);
        one[0] = maintenance;
        vault.addFuses(one);
        FuseAction[] memory sw = new FuseAction[](1);
        sw[0] = FuseAction(maintenance, abi.encodeWithSignature("enter((address))", wm));
        vault.execute(sw);
        vault.removeFuses(one);

        address[] memory rewardFuses = new address[](2);
        (rewardFuses[0], rewardFuses[1]) = (_addr(d, "merklClaimFuse"), _addr(d, "swapFuseV2"));
        address[] memory toAdd = new address[](2);
        uint256 nAdd;
        for (uint256 i; i < 2; ++i) if (!IRcmCutover(RCM).isRewardFuseSupported(rewardFuses[i])) toAdd[nAdd++] = rewardFuses[i];
        assembly {
            mstore(toAdd, nAdd)
        }
        if (nAdd != 0) IRcmCutover(RCM).addRewardFuses(toAdd); // the Merkl claim fuse is usually already there
        IWmCutover(wm).setDependencies(executor, _addr(d, "burnRequestFeeFuse"), _addr(d, "requestFuse"), WM_OLD);

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](4);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = LEND_MARKET; // IPOR MorphoSupplyFuse: [amount, morphoMarketId]
        // USDC_SUPPLY_LOOP_SPEC: first after idle, ahead of everything that costs money: [amount, morphoMarketId]
        bytes32[] memory usdcLoopParams = new bytes32[](2);
        usdcLoopParams[1] = USDC_LOOP_MARKET;
        // generic planned instant-withdraw fuse: params [amount (filled by IPOR), planner]
        bytes32[] memory vkatPlanner = new bytes32[](2);
        vkatPlanner[1] = bytes32(uint256(uint160(_addr(d, "vkatController"))));
        bytes32[] memory lpPlanner = new bytes32[](2);
        lpPlanner[1] = bytes32(uint256(uint160(_addr(d, "lpController"))));
        iw[0] = InstantWithdrawalFusesParamsStruct(_addr(d, "usdcLoopFuse"), usdcLoopParams);
        iw[1] = InstantWithdrawalFusesParamsStruct(_addr(d, "lendSupplyFuse"), lendParams);
        iw[2] = InstantWithdrawalFusesParamsStruct(_addr(d, "plannedInstantFuse"), vkatPlanner);
        iw[3] = InstantWithdrawalFusesParamsStruct(_addr(d, "plannedInstantFuse"), lpPlanner);
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
        require(IRcmCutover(RCM).isRewardFuseSupported(rewardFuses[0]) && IRcmCutover(RCM).isRewardFuseSupported(rewardFuses[1]), "reward fuses");
        (bool alpha,) = am.hasRole(ROLE_ALPHA, executor);
        (bool oldAlpha,) = am.hasRole(ROLE_ALPHA, CONTROLLER_V2);
        require(alpha && !oldAlpha, "ALPHA not moved");
        require(vault.getInstantWithdrawalFuses().length == 4, "instant withdrawal fuses");
        console2.log("cutover complete: executor", executor, "withdraw manager v2", wm);
    }
}

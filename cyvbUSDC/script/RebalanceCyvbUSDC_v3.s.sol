// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

struct FuseActionCyvbUSDCV3 {
    address fuse;
    bytes data;
}

struct MorphoSupplyEnterDataCyvbUSDCV3 {
    bytes32 morphoMarketId;
    uint256 amount;
}

struct MorphoSupplyExitDataCyvbUSDCV3 {
    bytes32 morphoMarketId;
    uint256 amount;
}

struct AllocationCyvbUSDCV3 {
    uint256 avKatBps;
    uint256 siUsdBps;
    uint256 weEthBps;
}

interface IPlasmaVaultExecuteCyvbUSDCV3 {
    function execute(FuseActionCyvbUSDCV3[] calldata calls_) external;
    function getAccessManagerAddress() external view returns (address);
}

interface IAccessManagerKeeperCyvbUSDCV3 {
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
}

interface IERC20BalanceCyvbUSDCV3 {
    function balanceOf(address account) external view returns (uint256);
}

/// @title RebalanceCyvbUSDC_v3
/// @notice Keeper/ALPHA allocation script for cyvbUSDC.
/// @dev No target allocation is stored in the vault. The keeper supplies the ratios on every run.
contract RebalanceCyvbUSDC_v3 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;
    uint64 internal constant ALPHA_ROLE = 200;

    address internal constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant MORPHO_SUPPLY_FUSE = 0x1f657229ec2D261be7dCD63ca82abed334d1f28b;

    bytes32 internal constant AVKAT_VBUSDC_MARKET =
        0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138;
    bytes32 internal constant SIUSD_VBUSDC_MARKET =
        0xf7fc5cc82200ddf8f23188ddbd6727eda2c8bc41863e91fb767bbc6e4f71890e;
    bytes32 internal constant WEETH_VBUSDC_MARKET =
        0x76e311d4b0e2e6ae88ad9bab18063452a6d39837d7104c430ff62457b91cb2cb;

    function run() external {
        require(block.chainid == KATANA_CHAIN_ID, "not Katana");

        address vaultAddress = vm.envAddress("VAULT");
        require(vaultAddress.code.length != 0, "VAULT missing");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        _requireImmediateAlpha(vaultAddress, vm.addr(privateKey));

        AllocationCyvbUSDCV3 memory allocation = _loadAllocation();
        bool fullRebalance = vm.envOr("FULL_REBALANCE", true);

        vm.startBroadcast(privateKey);

        IPlasmaVaultExecuteCyvbUSDCV3 vault = IPlasmaVaultExecuteCyvbUSDCV3(vaultAddress);
        if (fullRebalance) {
            vault.execute(_withdrawAllActions());
        }

        _deployIdle(vaultAddress, vault, allocation);

        vm.stopBroadcast();

        require(_idleBalance(vaultAddress) == 0, "idle vbUSDC remains");
    }

    function _loadAllocation() internal view returns (AllocationCyvbUSDCV3 memory allocation) {
        allocation.avKatBps = vm.envOr("ALLOC_AVKAT_BPS", uint256(3334));
        allocation.siUsdBps = vm.envOr("ALLOC_SIUSD_BPS", uint256(3333));
        allocation.weEthBps = vm.envOr("ALLOC_WEETH_BPS", uint256(3333));

        require(
            allocation.avKatBps + allocation.siUsdBps + allocation.weEthBps == 10_000,
            "allocations != 10000"
        );
    }

    function _requireImmediateAlpha(address vaultAddress_, address keeper_) internal view {
        address accessManager = IPlasmaVaultExecuteCyvbUSDCV3(vaultAddress_).getAccessManagerAddress();
        (bool isAlpha, uint32 delay) =
            IAccessManagerKeeperCyvbUSDCV3(accessManager).hasRole(ALPHA_ROLE, keeper_);
        require(isAlpha && delay == 0, "signer lacks immediate ALPHA");
    }

    function _deployIdle(
        address vaultAddress_,
        IPlasmaVaultExecuteCyvbUSDCV3 vault_,
        AllocationCyvbUSDCV3 memory allocation_
    ) internal {
        uint256 idle = _idleBalance(vaultAddress_);
        require(idle != 0, "no idle vbUSDC");

        uint256 avKatAmount = (idle * allocation_.avKatBps) / 10_000;
        uint256 siUsdAmount = (idle * allocation_.siUsdBps) / 10_000;
        uint256 weEthAmount = idle - avKatAmount - siUsdAmount;

        vault_.execute(_supplyActions(avKatAmount, siUsdAmount, weEthAmount));
    }

    function _idleBalance(address vaultAddress_) internal view returns (uint256) {
        return IERC20BalanceCyvbUSDCV3(VB_USDC).balanceOf(vaultAddress_);
    }

    function _withdrawAllActions() internal pure returns (FuseActionCyvbUSDCV3[] memory actions) {
        actions = new FuseActionCyvbUSDCV3[](3);
        actions[0] = _exitAction(AVKAT_VBUSDC_MARKET);
        actions[1] = _exitAction(SIUSD_VBUSDC_MARKET);
        actions[2] = _exitAction(WEETH_VBUSDC_MARKET);
    }

    function _supplyActions(
        uint256 avKatAmount_,
        uint256 siUsdAmount_,
        uint256 weEthAmount_
    ) internal pure returns (FuseActionCyvbUSDCV3[] memory actions) {
        actions = new FuseActionCyvbUSDCV3[](3);
        actions[0] = _enterAction(AVKAT_VBUSDC_MARKET, avKatAmount_);
        actions[1] = _enterAction(SIUSD_VBUSDC_MARKET, siUsdAmount_);
        actions[2] = _enterAction(WEETH_VBUSDC_MARKET, weEthAmount_);
    }

    function _exitAction(bytes32 marketId_) internal pure returns (FuseActionCyvbUSDCV3 memory) {
        MorphoSupplyExitDataCyvbUSDCV3 memory data = MorphoSupplyExitDataCyvbUSDCV3({
            morphoMarketId: marketId_,
            amount: type(uint256).max
        });

        return FuseActionCyvbUSDCV3({
            fuse: MORPHO_SUPPLY_FUSE,
            data: abi.encodeWithSignature("exit((bytes32,uint256))", data)
        });
    }

    function _enterAction(
        bytes32 marketId_,
        uint256 amount_
    ) internal pure returns (FuseActionCyvbUSDCV3 memory) {
        MorphoSupplyEnterDataCyvbUSDCV3 memory data = MorphoSupplyEnterDataCyvbUSDCV3({
            morphoMarketId: marketId_,
            amount: amount_
        });

        return FuseActionCyvbUSDCV3({
            fuse: MORPHO_SUPPLY_FUSE,
            data: abi.encodeWithSignature("enter((bytes32,uint256))", data)
        });
    }
}

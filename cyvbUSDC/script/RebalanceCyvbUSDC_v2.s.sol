// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

struct FuseActionCyvbUSDCV2 {
    address fuse;
    bytes data;
}

struct MorphoSupplyEnterDataCyvbUSDCV2 {
    bytes32 morphoMarketId;
    uint256 amount;
}

struct MorphoSupplyExitDataCyvbUSDCV2 {
    bytes32 morphoMarketId;
    uint256 amount;
}

interface IPlasmaVaultExecuteCyvbUSDCV2 {
    function execute(FuseActionCyvbUSDCV2[] calldata calls_) external;
    function getAccessManagerAddress() external view returns (address);
}

interface IAccessManagerKeeperCyvbUSDCV2 {
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
}

interface IERC20BalanceCyvbUSDCV2 {
    function balanceOf(address account) external view returns (uint256);
}

/// @title RebalanceCyvbUSDC_v2
/// @notice Keeper/ALPHA allocation script for cyvbUSDC.
/// @dev Allocation percentages are supplied at execution time; the vault stores no fixed strategy ratio.
///
/// Required env:
///   VAULT=<deployed cyvbUSDC>
///   PRIVATE_KEY=<keeper private key>
///
/// Optional:
///   FULL_REBALANCE=true|false  default true
///   ALLOC_AVKAT_BPS            default 3334
///   ALLOC_SIUSD_BPS            default 3333
///   ALLOC_WEETH_BPS            default 3333
contract RebalanceCyvbUSDC_v2 is Script {
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

        IPlasmaVaultExecuteCyvbUSDCV2 vault = IPlasmaVaultExecuteCyvbUSDCV2(vaultAddress);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address keeper = vm.addr(privateKey);

        IAccessManagerKeeperCyvbUSDCV2 access =
            IAccessManagerKeeperCyvbUSDCV2(vault.getAccessManagerAddress());
        (bool isAlpha, uint32 delay) = access.hasRole(ALPHA_ROLE, keeper);
        require(isAlpha && delay == 0, "signer lacks immediate ALPHA");

        uint256 avKatBps = vm.envOr("ALLOC_AVKAT_BPS", uint256(3334));
        uint256 siUsdBps = vm.envOr("ALLOC_SIUSD_BPS", uint256(3333));
        uint256 weEthBps = vm.envOr("ALLOC_WEETH_BPS", uint256(3333));
        require(avKatBps + siUsdBps + weEthBps == 10_000, "allocations != 10000");

        bool fullRebalance = vm.envOr("FULL_REBALANCE", true);

        vm.startBroadcast(privateKey);

        if (fullRebalance) {
            vault.execute(_withdrawAllActions());
        }

        // This read occurs after the withdrawal transaction, so allocation uses the exact idle amount.
        uint256 idle = IERC20BalanceCyvbUSDCV2(VB_USDC).balanceOf(vaultAddress);
        require(idle != 0, "no idle vbUSDC");

        uint256 avKatAmount = (idle * avKatBps) / 10_000;
        uint256 siUsdAmount = (idle * siUsdBps) / 10_000;
        uint256 weEthAmount = idle - avKatAmount - siUsdAmount;

        vault.execute(_supplyActions(avKatAmount, siUsdAmount, weEthAmount));

        vm.stopBroadcast();

        require(IERC20BalanceCyvbUSDCV2(VB_USDC).balanceOf(vaultAddress) == 0, "idle vbUSDC remains");
    }

    function _withdrawAllActions() internal pure returns (FuseActionCyvbUSDCV2[] memory actions) {
        actions = new FuseActionCyvbUSDCV2[](3);

        actions[0] = _exitAction(AVKAT_VBUSDC_MARKET);
        actions[1] = _exitAction(SIUSD_VBUSDC_MARKET);
        actions[2] = _exitAction(WEETH_VBUSDC_MARKET);
    }

    function _supplyActions(
        uint256 avKatAmount_,
        uint256 siUsdAmount_,
        uint256 weEthAmount_
    ) internal pure returns (FuseActionCyvbUSDCV2[] memory actions) {
        actions = new FuseActionCyvbUSDCV2[](3);

        actions[0] = _enterAction(AVKAT_VBUSDC_MARKET, avKatAmount_);
        actions[1] = _enterAction(SIUSD_VBUSDC_MARKET, siUsdAmount_);
        actions[2] = _enterAction(WEETH_VBUSDC_MARKET, weEthAmount_);
    }

    function _exitAction(bytes32 marketId_) internal pure returns (FuseActionCyvbUSDCV2 memory) {
        MorphoSupplyExitDataCyvbUSDCV2 memory exitData = MorphoSupplyExitDataCyvbUSDCV2({
            morphoMarketId: marketId_,
            amount: type(uint256).max
        });

        return FuseActionCyvbUSDCV2({
            fuse: MORPHO_SUPPLY_FUSE,
            data: abi.encodeWithSignature("exit((bytes32,uint256))", exitData)
        });
    }

    function _enterAction(
        bytes32 marketId_,
        uint256 amount_
    ) internal pure returns (FuseActionCyvbUSDCV2 memory) {
        MorphoSupplyEnterDataCyvbUSDCV2 memory enterData = MorphoSupplyEnterDataCyvbUSDCV2({
            morphoMarketId: marketId_,
            amount: amount_
        });

        return FuseActionCyvbUSDCV2({
            fuse: MORPHO_SUPPLY_FUSE,
            data: abi.encodeWithSignature("enter((bytes32,uint256))", enterData)
        });
    }
}

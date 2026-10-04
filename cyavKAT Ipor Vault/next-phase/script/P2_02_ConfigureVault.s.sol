// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

interface IPriceSourcesP22 {
    function setAssetsPriceSources(address[] calldata assets, address[] calldata sources) external;
    function getSourceOfAssetPrice(address asset) external view returns (address);
}

interface IVaultConfig {
    function getPriceOracleMiddleware() external view returns (address);
    function addFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function updateDependencyBalanceGraphs(uint256[] calldata marketIds, uint256[][] calldata dependencies) external;
    function updateCallbackHandler(address handler, address sender, bytes4 sig) external;
    function isFuseSupported(address fuse) external view returns (bool);
    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool);
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function totalAssets() external view returns (uint256);
}

/// Phase 2 step 2/3: additive vault configuration. Safe before the cutover: every new fuse only obeys the Phase 2
/// executor, which holds no vault role until step 3.
///   - registers the Morpho flash-loan callback handler (needed by every flash unwind; the vault has none today)
///   - adds all Phase 2 fuses + the fresh BurnRequestFeeFuse (the live 0x44D3 reads the pre-IL-6952 slot)
///   - accounting uses IPOR-registered markets only:
///       market 7 (ERC20_VAULT_BALANCE): balance fuse replaced by CurveYieldErc20BalanceFuse = IPOR's ERC20 logic plus
///         the Sushi LP holder's avKAT/KAT (net of its debt) and exiting avKAT. Before the cutover both are empty, so
///         the swap changes no value (asserted).
///       market 14 (MORPHO): the loop 0x80e6 only (asserted). Live dependency 14 -> [7] is kept.
///       market 41 (MORPHO_LIQUIDITY_IN_MARKETS, "Lend Only"): the lending market (asserted; installed by L1 / L9).
///
///   forge script script/P2_02_ConfigureVault.s.sol --root <phase2 path> --rpc-url katana     (add --broadcast ... to send)
interface IProfitLegs {
    function growthCustody() external view returns (address);
    function contributorsRecipient() external view returns (address);
}

contract P2_02_ConfigureVault is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory d = _readDeployments();
        IVaultConfig vault = IVaultConfig(VAULT);

        // fuse standardization: generic fuses (src/generic) + IPOR fuses; controllers plan, fuses are stateless
        string[20] memory fuseKeys = [
            "usdcLoopFuse",
            "loopCycleFuse", "loopUnwindFuse", "transferFuse", "guardFuse", "plannedInstantFuse", "swapFuseV2", "requestFuse",
            "burnRequestFeeFuse",
            "vkatLockFuse", "vkatConvertFuse", "vkatVoteFuse", "vkatExitBeginFuse", "vkatExitWithdrawFuse",
            "lendSupplyFuse", "lpOpenFuse", "lpIncreaseFuse", "lpWithdrawFuse", "lpRebalanceFuse", "lpEmergencyFuse"
        ];
        uint256 n;
        address[] memory toAdd = new address[](fuseKeys.length);
        for (uint256 i; i < fuseKeys.length; ++i) {
            address f = _addr(d, fuseKeys[i]);
            if (!vault.isFuseSupported(f)) toAdd[n++] = f;
        }
        assembly { mstore(toAdd, n) }

        _start();
        vault.updateCallbackHandler(
            _addr(d, "callbackHandlerMorpho"), MORPHO, bytes4(keccak256("onMorphoFlashLoan(uint256,bytes)"))
        );
        if (n != 0) vault.addFuses(toAdd);
        uint256 totalBefore = vault.totalAssets();
        _addBalance(vault, MARKET_ERC20, _addr(d, "erc20BalanceFuse"));
        _substrates54(d);
        // USDC_SUPPLY_LOOP_SPEC: market 14 = the avKAT/KAT loop + the avKAT/vbUSDC supply loop; vbUSDC priced at $1.00
        bytes32[] memory subs14 = vault.getMarketSubstrates(MARKET_LOOP);
        require(subs14.length != 0 && subs14[0] == LOOP_MARKET, "market 14 must start with the loop");
        if (subs14.length == 1) {
            bytes32[] memory both = new bytes32[](2);
            (both[0], both[1]) = (LOOP_MARKET, USDC_LOOP_MARKET);
            vault.grantMarketSubstrates(MARKET_LOOP, both);
        }
        IPriceSourcesP22 mw = IPriceSourcesP22(vault.getPriceOracleMiddleware());
        if (mw.getSourceOfAssetPrice(VBUSDC_TOKEN) == address(0)) {
            address[] memory assets = new address[](1);
            address[] memory sources = new address[](1);
            (assets[0], sources[0]) = (VBUSDC_TOKEN, _addr(d, "vbUsdcPriceFeed"));
            mw.setAssetsPriceSources(assets, sources);
        }
        _stop();
        subs14 = vault.getMarketSubstrates(MARKET_LOOP);
        require(subs14.length == 2 && subs14[0] == LOOP_MARKET && subs14[1] == USDC_LOOP_MARKET, "market 14 substrates");
        require(mw.getSourceOfAssetPrice(VBUSDC_TOKEN) == _addr(d, "vbUsdcPriceFeed"), "vbUSDC price source");
        bytes32[] memory subs41 = vault.getMarketSubstrates(MARKET_LEND);
        require(subs41.length == 1 && subs41[0] == LEND_MARKET, "lending not in market 41 (run L1 / L9 first)");
        require(vault.totalAssets() == totalBefore, "market 7 fuse swap changed totalAssets");

        for (uint256 i; i < fuseKeys.length; ++i) require(vault.isFuseSupported(_addr(d, fuseKeys[i])), fuseKeys[i]);
        require(vault.isBalanceFuseSupported(MARKET_ERC20, _addr(d, "erc20BalanceFuse")), "balance 7");
        console2.log("vault configured: fuses added", n);
    }

    /// @dev Market 54 (substrate-only): the ve contracts (plain, as the live vKAT list) and the typed entries of the
    /// generic fuses (CurveYieldSubstrateTypes): 1 reader, 2 loop component, 3 recipient, 4 holder, 5 hook, 6 planner,
    /// 8 transfer token.
    function _substrates54(string memory d_) private {
        address split = _addr(d_, "splitter");
        address exec = _addr(d_, "executor");
        address lpc = _addr(d_, "lpController");
        bytes32[] memory add = new bytes32[](20);
        (add[0], add[1], add[2]) = (_plain(AVKAT), _plain(GAUGE_VOTER), _plain(DELEGATION));
        (add[3], add[4], add[5]) = (_plain(VKAT_NFT), _plain(VKAT_ESCROW), _plain(VOTE_GAUGE));
        (add[6], add[7]) = (_typed(2, COLLATERAL_FUSE), _typed(2, BORROW_FUSE));
        (add[8], add[9]) = (_typed(2, FLASH_FUSE), _typed(2, _addr(d_, "swapFuseV2")));
        (add[10], add[11]) = (_typed(3, IProfitLegs(split).growthCustody()), _typed(3, IProfitLegs(split).contributorsRecipient()));
        (add[12], add[13]) = (_typed(3, RCM), _typed(3, exec));
        (add[14], add[15], add[16]) = (_typed(8, AVKAT), _typed(4, _addr(d_, "lpHolder")), _typed(5, lpc));
        (add[17], add[18]) = (_typed(6, _addr(d_, "vkatController")), _typed(6, lpc));
        // withdrawal request fuse planners: lending and loop controllers too (vKAT and LP are granted above; POL in P5)
        bytes32[] memory planners = new bytes32[](2);
        (planners[0], planners[1]) = (_typed(6, _addr(d_, "lendController")), _typed(6, _addr(d_, "loopController")));
        _appendSubstrates(MARKET_SUBSTRATES, planners);
        add[19] = _typed(1, _addr(d_, "lpHolderReader"));
        _appendSubstrates(MARKET_SUBSTRATES, add);
        bytes32[] memory reader = new bytes32[](1);
        reader[0] = _typed(1, _addr(d_, "vkatExitReader"));
        _appendSubstrates(MARKET_SUBSTRATES, reader);
    }

    function _plain(address a_) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a_)));
    }

    function _addBalance(IVaultConfig vault_, uint256 market_, address fuse_) private {
        if (!vault_.isBalanceFuseSupported(market_, fuse_)) vault_.addBalanceFuse(market_, fuse_);
    }
}

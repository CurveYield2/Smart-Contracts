// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @notice ABI-compatible subset of Morpho Blue used by cyvbETH.
/// @dev The structs and accounting formulas are copied from Morpho Blue's official IMorpho,
///      MathLib, SharesMathLib and MorphoBalancesLib at commit
///      8e26ca6a8dbc5089edcd67fb576248810fd2870a.
struct MorphoMarketParamsCyvbEthV1 {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MorphoMarketCyvbEthV1 {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IMorphoCyvbEthV1 {
    function idToMarketParams(bytes32 id) external view returns (MorphoMarketParamsCyvbEthV1 memory);
    function market(bytes32 id) external view returns (MorphoMarketCyvbEthV1 memory);
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function accrueInterest(MorphoMarketParamsCyvbEthV1 memory marketParams) external;
    function supply(
        MorphoMarketParamsCyvbEthV1 memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);
    function withdraw(
        MorphoMarketParamsCyvbEthV1 memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);
}

interface IMorphoIrmCyvbEthV1 {
    function borrowRateView(MorphoMarketParamsCyvbEthV1 memory marketParams, MorphoMarketCyvbEthV1 memory market)
        external
        view
        returns (uint256);
}

/// @title MorphoVbEthAccounting_v1
/// @notice Minimal official-Morpho-compatible supply accounting used by cyvbETH.
/// @dev Only the lender side is exposed: cyvbETH never posts yvvbUSDC collateral and never borrows from Morpho.
library MorphoVbEthAccounting_v1 {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function expectedSupplyAssets(IMorphoCyvbEthV1 morpho_, bytes32 marketId_, address user_)
        internal
        view
        returns (uint256)
    {
        (uint256 supplyShares,,) = morpho_.position(marketId_, user_);
        if (supplyShares == 0) return 0;

        MorphoMarketParamsCyvbEthV1 memory params = morpho_.idToMarketParams(marketId_);
        MorphoMarketCyvbEthV1 memory market = morpho_.market(marketId_);

        uint256 totalSupplyAssets = market.totalSupplyAssets;
        uint256 totalSupplyShares = market.totalSupplyShares;
        uint256 totalBorrowAssets = market.totalBorrowAssets;

        uint256 elapsed = block.timestamp - uint256(market.lastUpdate);
        if (elapsed != 0 && totalBorrowAssets != 0 && params.irm != address(0)) {
            uint256 borrowRate = IMorphoIrmCyvbEthV1(params.irm).borrowRateView(params, market);
            uint256 interest = _wMulDown(totalBorrowAssets, _wTaylorCompounded(borrowRate, elapsed));
            totalBorrowAssets += interest;
            totalSupplyAssets += interest;

            if (market.fee != 0) {
                uint256 feeAmount = _wMulDown(interest, market.fee);
                uint256 feeShares =
                    _toSharesDown(feeAmount, totalSupplyAssets - feeAmount, totalSupplyShares);
                totalSupplyShares += feeShares;
            }
        }

        return _toAssetsDown(supplyShares, totalSupplyAssets, totalSupplyShares);
    }

    function currentSupplyAssets(IMorphoCyvbEthV1 morpho_, bytes32 marketId_, address user_)
        internal
        view
        returns (uint256)
    {
        (uint256 supplyShares,,) = morpho_.position(marketId_, user_);
        if (supplyShares == 0) return 0;
        MorphoMarketCyvbEthV1 memory market = morpho_.market(marketId_);
        return _toAssetsDown(supplyShares, market.totalSupplyAssets, market.totalSupplyShares);
    }

    function _toSharesDown(uint256 assets_, uint256 totalAssets_, uint256 totalShares_)
        private
        pure
        returns (uint256)
    {
        return (assets_ * (totalShares_ + VIRTUAL_SHARES)) / (totalAssets_ + VIRTUAL_ASSETS);
    }

    function _toAssetsDown(uint256 shares_, uint256 totalAssets_, uint256 totalShares_)
        private
        pure
        returns (uint256)
    {
        return (shares_ * (totalAssets_ + VIRTUAL_ASSETS)) / (totalShares_ + VIRTUAL_SHARES);
    }

    function _wMulDown(uint256 x_, uint256 y_) private pure returns (uint256) {
        return (x_ * y_) / WAD;
    }

    /// @dev Morpho MathLib.wTaylorCompounded: first three non-zero terms of e^(nx)-1.
    function _wTaylorCompounded(uint256 x_, uint256 n_) private pure returns (uint256) {
        uint256 firstTerm = x_ * n_;
        uint256 secondTerm = (firstTerm * firstTerm) / (2 * WAD);
        uint256 thirdTerm = (secondTerm * firstTerm) / (3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }
}

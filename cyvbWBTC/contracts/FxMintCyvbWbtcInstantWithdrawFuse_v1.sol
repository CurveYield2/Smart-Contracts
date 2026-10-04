// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20FxMintInstantV1 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC4626FxMintInstantV1 {
    function balanceOf(address account) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

interface ICyvbWbtcInstantConfigV1 {
    function vault() external view returns (address);
    function positionId() external view returns (uint256);
    function INSTANT_WITHDRAW_MAX_LTV_BPS() external view returns (uint16);
}

interface IFxPoolManagerInstantV1 {
    function operate(
        address pool,
        uint256 positionId,
        int256 newColl,
        int256 newDebt
    ) external returns (uint256 positionId);

    function getTokenScalingFactor(address token) external view returns (uint256);
}

interface IFxLongPoolInstantV1 {
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function getPositionDebtRatio(uint256 tokenId) external view returns (uint256 debtRatio);
    function priceOracle() external view returns (address);
    function configuration() external view returns (address);
}

interface IFxPriceOracleInstantV1 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

interface IFxPoolConfigurationInstantV1 {
    function getPoolFeeRatio(
        address pool,
        address recipient
    ) external view returns (
        uint256 supplyFeeRatio,
        uint256 withdrawFeeRatio,
        uint256 borrowFeeRatio,
        uint256 repayFeeRatio
    );
}

interface IFxBaseInstantV1 {
    function getStableTokenPriceWithScale() external view returns (uint256);
}

interface ICurveYieldRouterInstantV1 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 netAmountOut);
}

interface IPlasmaVaultSubstratesInstantV1 {
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory);
}

/// @title FxMintCyvbWbtcInstantWithdrawFuse_v1
/// @notice Cross-asset instant-withdraw adapter for cyvbWBTC's f(x) + nested cyvbUSDC position.
/// @dev This is intentionally separate from normal strategy execution. Normal operations use IPOR's
///      canonical primitive fuses. A custom instant adapter is required because PlasmaVault supplies
///      params[0] in vbWBTC units, while the nested ERC4626 vault's asset is vbUSDC.
///
///      Behavior is deliberately conservative:
///      1. If the requested vbWBTC can be released from f(x) collateral while leaving LTV <=55%,
///         withdraw only that collateral.
///      2. Otherwise fully unwind: redeem nested cyvbUSDC, obtain enough fxUSD to repay all debt,
///         close f(x) collateral, and convert residual stable value back to vbWBTC.
///
///      This shape follows IPOR's cross-asset instant-withdraw fuses (for example YieldBasis/Midas):
///      translate the PlasmaVault-underlying request into the external position's units, perform the
///      exit, and leave the requested underlying in the PlasmaVault.
contract FxMintCyvbWbtcInstantWithdrawFuse_v1 {
    uint256 public constant MARKET_ID = 7001;
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant FEE_PRECISION = 1e9;
    uint256 private constant STABLE_INPUT_BUFFER_BPS = 100; // 1%

    address public immutable VERSION;
    address public immutable CONFIG;
    address public immutable POOL_MANAGER;
    address public immutable FX_POOL;
    address public immutable FXBASE;
    address public immutable FXUSD;
    address public immutable VBWBTC;
    address public immutable VBUSDC;
    address public immutable CYVBUSDC;
    address public immutable ROUTER;

    error InvalidAddress();
    error WrongVaultContext();
    error UnsupportedPool(address pool);
    error MissingSwapRoute(address tokenIn, address tokenOut);
    error InvalidPrice();
    error InsufficientFxUsdForRepay(uint256 required, uint256 available);
    error AmountTooLargeForInt256();
    error TokenOperationFailed(address token);
    error SwapOutputMismatch();

    event FxMintCyvbWbtcInstantWithdraw(
        address indexed version,
        uint256 indexed positionId,
        uint256 requestedVbWbtc,
        uint256 producedVbWbtc,
        bool fullUnwind
    );

    constructor(
        address config_,
        address poolManager_,
        address fxPool_,
        address fxBase_,
        address fxUsd_,
        address vbWbtc_,
        address vbUsdc_,
        address cyvbUsdc_,
        address router_
    ) {
        if (
            config_ == address(0) ||
            poolManager_ == address(0) ||
            fxPool_ == address(0) ||
            fxBase_ == address(0) ||
            fxUsd_ == address(0) ||
            vbWbtc_ == address(0) ||
            vbUsdc_ == address(0) ||
            cyvbUsdc_ == address(0) ||
            router_ == address(0)
        ) revert InvalidAddress();

        CONFIG = config_;
        POOL_MANAGER = poolManager_;
        FX_POOL = fxPool_;
        FXBASE = fxBase_;
        FXUSD = fxUsd_;
        VBWBTC = vbWbtc_;
        VBUSDC = vbUsdc_;
        CYVBUSDC = cyvbUsdc_;
        ROUTER = router_;
        VERSION = address(this);
    }

    /// @notice IPOR instant-withdraw entry point. params_[0] is overwritten by PlasmaVault with
    ///         the remaining vbWBTC amount required for the user's withdrawal.
    function instantWithdraw(bytes32[] calldata params_) external {
        _requireVaultContext();
        _requirePoolGranted();

        uint256 requested = params_.length == 0 ? 0 : uint256(params_[0]);
        if (requested == 0) return;

        uint256 positionId = ICyvbWbtcInstantConfigV1(CONFIG).positionId();
        if (positionId == 0) return;

        uint256 balanceBefore = IERC20FxMintInstantV1(VBWBTC).balanceOf(address(this));
        bool fullUnwind;

        uint256 safeNet = _safeCollateralOnlyNetWithdrawal(positionId);
        if (requested <= safeNet) {
            _withdrawCollateral(positionId, _grossCollateralForNet(requested));
        } else {
            _fullUnwind(positionId);
            fullUnwind = true;
        }

        uint256 produced = IERC20FxMintInstantV1(VBWBTC).balanceOf(address(this)) - balanceBefore;

        emit FxMintCyvbWbtcInstantWithdraw(
            VERSION,
            positionId,
            requested,
            produced,
            fullUnwind
        );
    }

    function _fullUnwind(uint256 positionId_) private {
        uint256 nestedShares = IERC4626FxMintInstantV1(CYVBUSDC).balanceOf(address(this));
        if (nestedShares != 0) {
            IERC4626FxMintInstantV1(CYVBUSDC).redeem(
                nestedShares,
                address(this),
                address(this)
            );
        }

        (, uint256 rawDebts) = IFxLongPoolInstantV1(FX_POOL).getPosition(positionId_);
        if (rawDebts != 0) {
            _obtainFxUsdForRepay(rawDebts);

            IFxPoolManagerInstantV1(POOL_MANAGER).operate(
                FX_POOL,
                positionId_,
                0,
                -_toInt(rawDebts)
            );
        }

        (uint256 remainingRawColls,) = IFxLongPoolInstantV1(FX_POOL).getPosition(positionId_);
        if (remainingRawColls != 0) {
            IFxPoolManagerInstantV1(POOL_MANAGER).operate(
                FX_POOL,
                positionId_,
                type(int256).min,
                0
            );
        }

        uint256 residualFxUsd = IERC20FxMintInstantV1(FXUSD).balanceOf(address(this));
        if (residualFxUsd != 0) {
            _swap(FXUSD, VBUSDC, residualFxUsd);
        }

        uint256 residualVbUsdc = IERC20FxMintInstantV1(VBUSDC).balanceOf(address(this));
        if (residualVbUsdc != 0) {
            _swap(VBUSDC, VBWBTC, residualVbUsdc);
        }
    }

    function _obtainFxUsdForRepay(uint256 debtReduction_) private {
        (,,, uint256 repayFeeRatio) = IFxPoolConfigurationInstantV1(
            IFxLongPoolInstantV1(FX_POOL).configuration()
        ).getPoolFeeRatio(FX_POOL, address(this));

        uint256 fxUsdNeeded =
            debtReduction_ + ((debtReduction_ * repayFeeRatio) / FEE_PRECISION);

        uint256 fxUsdBalance = IERC20FxMintInstantV1(FXUSD).balanceOf(address(this));
        if (fxUsdBalance >= fxUsdNeeded) return;

        uint256 stablePrice = IFxBaseInstantV1(FXBASE).getStableTokenPriceWithScale();
        if (stablePrice == 0) revert InvalidPrice();

        uint256 missingFxUsd = fxUsdNeeded - fxUsdBalance;
        uint256 stableInput = _ceilDiv(missingFxUsd * WAD, stablePrice);
        stableInput = _ceilDiv(stableInput * (BPS + STABLE_INPUT_BUFFER_BPS), BPS);

        uint256 stableBalance = IERC20FxMintInstantV1(VBUSDC).balanceOf(address(this));
        if (stableInput > stableBalance) stableInput = stableBalance;

        if (stableInput != 0) {
            _swap(VBUSDC, FXUSD, stableInput);
        }

        fxUsdBalance = IERC20FxMintInstantV1(FXUSD).balanceOf(address(this));
        if (fxUsdBalance < fxUsdNeeded) {
            revert InsufficientFxUsdForRepay(fxUsdNeeded, fxUsdBalance);
        }
    }

    function _safeCollateralOnlyNetWithdrawal(uint256 positionId_) private view returns (uint256) {
        (uint256 rawColls, uint256 rawDebts) =
            IFxLongPoolInstantV1(FX_POOL).getPosition(positionId_);
        if (rawColls == 0) return 0;

        if (rawDebts == 0) {
            return _maxNetCollateralWithdrawal(rawColls);
        }

        (uint256 anchorPrice,,) =
            IFxPriceOracleInstantV1(IFxLongPoolInstantV1(FX_POOL).priceOracle()).getPrice();
        if (anchorPrice == 0) revert InvalidPrice();

        uint16 maxLtvBps = ICyvbWbtcInstantConfigV1(CONFIG).INSTANT_WITHDRAW_MAX_LTV_BPS();

        uint256 minimumRawCollateral = _ceilDiv(
            rawDebts * WAD * BPS,
            anchorPrice * uint256(maxLtvBps)
        );

        if (minimumRawCollateral >= rawColls) return 0;

        return _maxNetCollateralWithdrawal(rawColls - minimumRawCollateral);
    }

    function _maxNetCollateralWithdrawal(uint256 rawColls_) private view returns (uint256) {
        uint256 grossToken = _rawToToken(rawColls_);
        (, uint256 withdrawFee,,) = IFxPoolConfigurationInstantV1(
            IFxLongPoolInstantV1(FX_POOL).configuration()
        ).getPoolFeeRatio(FX_POOL, address(this));

        if (withdrawFee >= FEE_PRECISION) return 0;
        return (grossToken * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    }

    function _grossCollateralForNet(uint256 netAmount_) private view returns (uint256) {
        (, uint256 withdrawFee,,) = IFxPoolConfigurationInstantV1(
            IFxLongPoolInstantV1(FX_POOL).configuration()
        ).getPoolFeeRatio(FX_POOL, address(this));

        if (withdrawFee >= FEE_PRECISION) return type(uint256).max;
        return _ceilDiv(netAmount_ * FEE_PRECISION, FEE_PRECISION - withdrawFee);
    }

    function _withdrawCollateral(uint256 positionId_, uint256 grossAmount_) private {
        IFxPoolManagerInstantV1(POOL_MANAGER).operate(
            FX_POOL,
            positionId_,
            -_toInt(grossAmount_),
            0
        );
    }

    function _swap(address tokenIn_, address tokenOut_, uint256 amountIn_) private returns (uint256 amountOut) {
        if (amountIn_ == 0) return 0;
        if (ICurveYieldRouterInstantV1(ROUTER).routeFor(tokenIn_, tokenOut_).length == 0) {
            revert MissingSwapRoute(tokenIn_, tokenOut_);
        }

        uint256 balanceBefore = IERC20FxMintInstantV1(tokenOut_).balanceOf(address(this));

        _forceApprove(tokenIn_, ROUTER, amountIn_);
        amountOut = ICurveYieldRouterInstantV1(ROUTER).swapExactInput(
            tokenIn_,
            tokenOut_,
            amountIn_,
            0,
            address(this),
            block.timestamp
        );
        _forceApprove(tokenIn_, ROUTER, 0);

        uint256 received = IERC20FxMintInstantV1(tokenOut_).balanceOf(address(this)) - balanceBefore;
        if (received != amountOut) revert SwapOutputMismatch();
    }

    function _rawToToken(uint256 rawAmount_) private view returns (uint256) {
        uint256 scale = IFxPoolManagerInstantV1(POOL_MANAGER).getTokenScalingFactor(VBWBTC);
        return (rawAmount_ * WAD) / scale;
    }

    function _requireVaultContext() private view {
        if (ICyvbWbtcInstantConfigV1(CONFIG).vault() != address(this)) {
            revert WrongVaultContext();
        }
    }

    function _requirePoolGranted() private view {
        bytes32 expected = bytes32(uint256(uint160(FX_POOL)));
        bytes32[] memory substrates =
            IPlasmaVaultSubstratesInstantV1(address(this)).getMarketSubstrates(MARKET_ID);

        uint256 length = substrates.length;
        for (uint256 i; i < length; ++i) {
            if (substrates[i] == expected) return;
        }
        revert UnsupportedPool(FX_POOL);
    }

    function _toInt(uint256 value_) private pure returns (int256) {
        if (value_ > uint256(type(int256).max)) revert AmountTooLargeForInt256();
        return int256(value_);
    }

    function _ceilDiv(uint256 a_, uint256 b_) private pure returns (uint256) {
        if (a_ == 0) return 0;
        return ((a_ - 1) / b_) + 1;
    }

    function _forceApprove(address token_, address spender_, uint256 amount_) private {
        bytes memory approveData =
            abi.encodeWithSelector(IERC20FxMintInstantV1.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, approveData)) {
            _callOptionalReturn(
                token_,
                abi.encodeWithSelector(IERC20FxMintInstantV1.approve.selector, spender_, 0)
            );
            _callOptionalReturn(token_, approveData);
        }
    }

    function _callOptionalReturn(address token_, bytes memory data_) private {
        (bool success, bytes memory returndata) = token_.call(data_);
        if (!success || (returndata.length != 0 && !abi.decode(returndata, (bool)))) {
            revert TokenOperationFailed(token_);
        }
    }

    function _callOptionalReturnBool(address token_, bytes memory data_) private returns (bool) {
        (bool success, bytes memory returndata) = token_.call(data_);
        return success &&
            (returndata.length == 0 || (returndata.length >= 32 && abi.decode(returndata, (bool))));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Data structure for increasing an f(x) long position.
/// @dev Mirrors IPOR's primitive fuse pattern: the ALPHA/strategy layer decides amounts,
///      while the fuse only performs the protocol operation.
struct FxMintCyvbWbtcPositionFuseEnterData {
    uint256 collateralAmount;
    uint256 debtAmount;
}

/// @notice Data structure for decreasing an f(x) long position.
/// @dev collateralAmount == type(uint256).max withdraws all collateral using f(x)'s sentinel.
///      debtAmount is capped to the current raw debt, matching IPOR borrow-fuse repay patterns.
struct FxMintCyvbWbtcPositionFuseExitData {
    uint256 collateralAmount;
    uint256 debtAmount;
}

interface IERC20FxMintCyvbWbtcPositionV3 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFxPoolManagerCyvbWbtcPositionV3 {
    function operate(
        address pool,
        uint256 positionId,
        int256 newColl,
        int256 newDebt
    ) external returns (uint256 resultingPositionId);

    function getTokenScalingFactor(address token) external view returns (uint256);
}

interface IFxLongPoolCyvbWbtcPositionV3 {
    function collateralToken() external view returns (address);
    function fxUSD() external view returns (address);
    function poolManager() external view returns (address);
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
}

interface ICyvbWbtcPositionRegistryV1 {
    function vault() external view returns (address);
    function positionId() external view returns (uint256);
    function recordPositionId(uint256 positionId_) external;
}

interface IPlasmaVaultSubstratesFxMintV1 {
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory);
}

/// @title FxMintCyvbWbtcPositionFuse_v3
/// @notice Minimal IPOR-style primitive fuse for the live Katana f(x) vbWBTC long pool.
/// @dev Uses the official IPOR ERC20_VAULT_BALANCE market id (7) as the fallback market namespace
///      because IPOR has no f(x)-specific market id. No custom market id is introduced.
/// @dev The structure intentionally follows the official IPOR primitive-fuse model exemplified by
///      EbisuAdjustTroveFuse / CompoundV3BorrowFuse: validate the granted market substrate,
///      cap amounts to available/current balances where appropriate, call the external protocol,
///      reset approvals, and leave strategy sequencing to PlasmaVault.execute(FuseAction[]).
///
///      This fuse does NOT swap tokens, deposit into cyvbUSDC, choose LTV targets, or rebalance.
///      Those operations belong to IPOR's canonical fuses and the ALPHA strategy layer.
contract FxMintCyvbWbtcPositionFuse_v3 {
    uint256 public constant MARKET_ID = 7; // IporFusionMarkets.ERC20_VAULT_BALANCE
    uint256 private constant WAD = 1e18;

    address public immutable VERSION;
    address public immutable CONFIG;
    address public immutable POOL_MANAGER;
    address public immutable FX_POOL;
    address public immutable VBWBTC;
    address public immutable FXUSD;

    error InvalidAddress();
    error WrongVaultContext();
    error UnsupportedPool(address pool);
    error ProtocolTopologyMismatch();
    error AmountTooLargeForInt256();
    error TokenOperationFailed(address token);

    event FxMintCyvbWbtcPositionFuseEnter(
        address indexed version,
        uint256 indexed positionId,
        uint256 collateralAmount,
        uint256 debtAmount
    );

    event FxMintCyvbWbtcPositionFuseExit(
        address indexed version,
        uint256 indexed positionId,
        uint256 collateralAmount,
        uint256 debtAmount,
        bool allCollateral
    );

    constructor(
        address config_,
        address poolManager_,
        address fxPool_,
        address vbWbtc_,
        address fxUsd_
    ) {
        if (
            config_ == address(0) ||
            poolManager_ == address(0) ||
            fxPool_ == address(0) ||
            vbWbtc_ == address(0) ||
            fxUsd_ == address(0)
        ) revert InvalidAddress();

        if (
            config_.code.length == 0 ||
            poolManager_.code.length == 0 ||
            fxPool_.code.length == 0 ||
            vbWbtc_.code.length == 0 ||
            fxUsd_.code.length == 0
        ) revert InvalidAddress();

        IFxLongPoolCyvbWbtcPositionV3 pool = IFxLongPoolCyvbWbtcPositionV3(fxPool_);
        if (
            pool.collateralToken() != vbWbtc_ ||
            pool.fxUSD() != fxUsd_ ||
            pool.poolManager() != poolManager_
        ) revert ProtocolTopologyMismatch();

        VERSION = address(this);
        CONFIG = config_;
        POOL_MANAGER = poolManager_;
        FX_POOL = fxPool_;
        VBWBTC = vbWbtc_;
        FXUSD = fxUsd_;
    }

    /// @notice Increase collateral and/or debt on the tracked f(x) position.
    /// @dev f(x) itself enforces its debt-ratio bounds. For a brand-new position, callers must
    ///      provide a valid collateral+debt combination in the same operation.
    function enter(
        FxMintCyvbWbtcPositionFuseEnterData memory data_
    ) external returns (uint256 positionId, uint256 collateralSupplied, uint256 debtBorrowed) {
        _requireVaultContext();
        _requirePoolGranted();

        collateralSupplied = _min(
            data_.collateralAmount,
            IERC20FxMintCyvbWbtcPositionV3(VBWBTC).balanceOf(address(this))
        );
        debtBorrowed = data_.debtAmount;

        if (collateralSupplied == 0 && debtBorrowed == 0) {
            return (ICyvbWbtcPositionRegistryV1(CONFIG).positionId(), 0, 0);
        }

        uint256 existing = ICyvbWbtcPositionRegistryV1(CONFIG).positionId();

        if (collateralSupplied != 0) {
            _forceApprove(VBWBTC, POOL_MANAGER, collateralSupplied);
        }

        positionId = IFxPoolManagerCyvbWbtcPositionV3(POOL_MANAGER).operate(
            FX_POOL,
            existing,
            _toInt(collateralSupplied),
            _toInt(debtBorrowed)
        );

        if (collateralSupplied != 0) {
            _forceApprove(VBWBTC, POOL_MANAGER, 0);
        }

        if (existing == 0) {
            ICyvbWbtcPositionRegistryV1(CONFIG).recordPositionId(positionId);
        } else if (positionId != existing) {
            revert ProtocolTopologyMismatch();
        }

        emit FxMintCyvbWbtcPositionFuseEnter(
            VERSION,
            positionId,
            collateralSupplied,
            debtBorrowed
        );
    }

    /// @notice Decrease collateral and/or repay fxUSD debt on the tracked f(x) position.
    /// @dev The PlasmaVault must already hold enough fxUSD for the requested repayment.
    function exit(
        FxMintCyvbWbtcPositionFuseExitData memory data_
    ) external returns (uint256 positionId, uint256 collateralRequested, uint256 debtRepaid) {
        _requireVaultContext();
        _requirePoolGranted();

        positionId = ICyvbWbtcPositionRegistryV1(CONFIG).positionId();
        if (positionId == 0) {
            return (0, 0, 0);
        }

        (uint256 rawColls, uint256 rawDebts) =
            IFxLongPoolCyvbWbtcPositionV3(FX_POOL).getPosition(positionId);

        debtRepaid = _min(data_.debtAmount, rawDebts);

        int256 collateralDelta;
        bool allCollateral = data_.collateralAmount == type(uint256).max;
        if (allCollateral) {
            if (rawColls != 0) collateralDelta = type(int256).min;
        } else if (data_.collateralAmount != 0 && rawColls != 0) {
            uint256 maxCollateral = _rawToToken(rawColls);
            collateralRequested = _min(data_.collateralAmount, maxCollateral);
            if (collateralRequested != 0) {
                collateralDelta = -_toInt(collateralRequested);
            }
        }

        if (collateralDelta == 0 && debtRepaid == 0) {
            return (positionId, 0, 0);
        }

        IFxPoolManagerCyvbWbtcPositionV3(POOL_MANAGER).operate(
            FX_POOL,
            positionId,
            collateralDelta,
            -_toInt(debtRepaid)
        );

        emit FxMintCyvbWbtcPositionFuseExit(
            VERSION,
            positionId,
            collateralRequested,
            debtRepaid,
            allCollateral
        );
    }

    function _requireVaultContext() private view {
        if (ICyvbWbtcPositionRegistryV1(CONFIG).vault() != address(this)) {
            revert WrongVaultContext();
        }
    }

    function _requirePoolGranted() private view {
        bytes32 expected = bytes32(uint256(uint160(FX_POOL)));
        bytes32[] memory substrates =
            IPlasmaVaultSubstratesFxMintV1(address(this)).getMarketSubstrates(MARKET_ID);

        uint256 length = substrates.length;
        for (uint256 i; i < length; ++i) {
            if (substrates[i] == expected) return;
        }
        revert UnsupportedPool(FX_POOL);
    }

    function _rawToToken(uint256 rawAmount_) private view returns (uint256) {
        uint256 scale = IFxPoolManagerCyvbWbtcPositionV3(POOL_MANAGER).getTokenScalingFactor(VBWBTC);
        return (rawAmount_ * WAD) / scale;
    }

    function _min(uint256 a_, uint256 b_) private pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

    function _toInt(uint256 value_) private pure returns (int256) {
        if (value_ > uint256(type(int256).max)) revert AmountTooLargeForInt256();
        return int256(value_);
    }

    function _forceApprove(address token_, address spender_, uint256 amount_) private {
        bytes memory approveData =
            abi.encodeWithSelector(IERC20FxMintCyvbWbtcPositionV3.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, approveData)) {
            _callOptionalReturn(
                token_,
                abi.encodeWithSelector(IERC20FxMintCyvbWbtcPositionV3.approve.selector, spender_, 0)
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

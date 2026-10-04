// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20FxMintCyvbWBTCV9 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC4626FxMintCyvbWBTCV9 {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256);
}

/// @dev The f(x) position id lives in IPOR's official fxMINT storage slot (FxMintStorageLib), in the vault.
library CyvbWbtcFxPositionStorage {
    bytes32 internal constant FX_MINT_POSITION_IDS = 0xd6497e578ce2e2ee4effa1fadef2326ebdc8f2b065aece8657da626f367fe500;

    struct FxMintPositionIds {
        mapping(address pool => uint256 positionId) positionIds;
    }

    function ids() internal pure returns (FxMintPositionIds storage s_) {
        bytes32 slot = FX_MINT_POSITION_IDS;
        assembly {
            s_.slot := slot
        }
    }
}

struct CyvbWbtcLtvPolicy {
    uint16 targetLtvBps;
    uint16 highTriggerBps;
    uint16 highResetBps;
    uint16 lowTriggerBps;
    uint16 lowResetBps;
}

interface IFxPoolManagerCyvbWBTCV9 {
    function operate(
        address pool,
        uint256 positionId,
        int256 newColl,
        int256 newDebt
    ) external returns (uint256);

    function getTokenScalingFactor(address token) external view returns (uint256);
}

interface IFxLongPoolCyvbWBTCV9 {
    function collateralToken() external view returns (address);
    function fxUSD() external view returns (address);
    function poolManager() external view returns (address);
    function priceOracle() external view returns (address);
    function configuration() external view returns (address);
    function getDebtRatioRange() external view returns (uint256 minDebtRatio, uint256 maxDebtRatio);
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function getPositionDebtRatio(uint256 tokenId) external view returns (uint256 debtRatio);
}

interface IFxPriceOracleCyvbWBTCV9 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

interface IFxPoolConfigurationCyvbWBTCV9 {
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

interface IFxBaseCyvbWBTCV9 {
    function stableToken() external view returns (address);
    function getStableTokenPriceWithScale() external view returns (uint256);
}

interface ICurveYieldRouterCyvbWBTCV9 {
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

/// @title FxMintCyvbWbtcFuse_v11
/// @notice cyvbWBTC strategy fuse:
///         vbWBTC -> f(x) collateral -> fxUSD debt -> vbUSDC -> nested cyvbUSDC.
/// @dev Runs by delegatecall from IPOR PlasmaVault. Position ownership, token balances and approvals
///      therefore all belong to the PlasmaVault.
///
///      LTV behavior:
///      - fresh capital borrows to configurable target (default 50%),
///      - >= high trigger (default 60%) deleverages to high reset (default 58%),
///      - <= low trigger (default 45%) borrows to low reset (default 50%),
///      - instant withdrawals never leave the f(x) position above 55%.
///
///      v11: the Katana f(x) PoolManager locks after ONE operate() per transaction (transient lock), so every path
///      does at most one operate(): repay + collateral withdrawal are a single operate(pos, -coll, -debt). A full exit
///      whose nested stable leg cannot cover debt + repay fee reverts InsufficientNestedStable (the f(x) borrow fee
///      and entry swap leave the stable leg slightly below the debt): that tail goes through a scheduled withdrawal.
contract FxMintCyvbWbtcFuse_v11 {
    /// @notice Vault-local fxMINT market (balance: FxMintCyvbWbtcBalanceFuse_v4); depends on 100_001 (cyvbUSDC) and 7.
    uint256 public immutable MARKET_ID;
    /// @notice Instant withdrawals never leave the f(x) position above this LTV.
    uint16 public constant INSTANT_WITHDRAW_MAX_LTV_BPS = 5_500;
    // LTV policy bounds: +/-10% relative to each baseline (folded from CyvbWbtcLtvConfig_v3)
    uint16 public constant MIN_TARGET_LTV_BPS = 4_500;
    uint16 public constant MAX_TARGET_LTV_BPS = 5_500;
    uint16 public constant MIN_HIGH_TRIGGER_BPS = 5_400;
    uint16 public constant MAX_HIGH_TRIGGER_BPS = 6_600;
    uint16 public constant MIN_HIGH_RESET_BPS = 5_220;
    uint16 public constant MAX_HIGH_RESET_BPS = 6_380;
    uint16 public constant MIN_LOW_TRIGGER_BPS = 4_050;
    uint16 public constant MAX_LOW_TRIGGER_BPS = 4_950;
    uint16 public constant MIN_LOW_RESET_BPS = 4_500;
    uint16 public constant MAX_LOW_RESET_BPS = 5_500;
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_PRECISION = 1e9;
    uint256 public constant DELEVERAGE_STABLE_BUFFER_BPS = 100; // 1% input buffer; surplus is recycled.

    address public immutable VERSION;
    /// @notice The cyvbWBTC PlasmaVault this fuse runs in (delegatecall context check).
    address public immutable VAULT;
    // LTV policy (immutable: a policy change = a new fuse version installed by the fuse manager)
    uint16 public immutable TARGET_LTV_BPS;
    uint16 public immutable HIGH_TRIGGER_BPS;
    uint16 public immutable HIGH_RESET_BPS;
    uint16 public immutable LOW_TRIGGER_BPS;
    uint16 public immutable LOW_RESET_BPS;
    address public immutable POOL_MANAGER;
    address public immutable FX_POOL;
    address public immutable FXBASE;
    address public immutable FXUSD;
    address public immutable VBWBTC;
    address public immutable VB_USDC;
    address public immutable CYVBUSDC;
    address public immutable ROUTER;

    error InvalidAddress();
    error ValueOutOfRange();
    error InvalidOrdering();
    error WrongVaultContext();
    error ProtocolTopologyMismatch();
    error InvalidDeadline();
    error NoPosition();
    error NoCapital();
    error NoRebalanceNeeded(uint256 currentLtv);
    error InvalidTargetLtv();
    error MissingSwapRoute(address tokenIn, address tokenOut);
    error InsufficientNestedStable(uint256 required, uint256 available);
    error InsufficientFxUsdForRepay(uint256 required, uint256 available);
    error InstantWithdrawLtvTooHigh(uint256 ltv);
    error InsufficientVbWbtcProduced(uint256 required, uint256 produced);
    error AmountTooLargeForInt256();
    error TokenOperationFailed(address token);
    error SwapOutputMismatch();

    event CapitalDeployed(
        address indexed version,
        uint256 indexed positionId,
        uint256 vbWbtcSupplied,
        uint256 fxUsdBorrowed,
        uint256 vbUsdcDeposited,
        uint256 resultingLtv
    );

    event LtvRebalanced(
        address indexed version,
        uint256 indexed positionId,
        uint256 oldLtv,
        uint256 newLtv,
        bool deleveraged
    );

    event InstantWithdrawalPrepared(
        address indexed version,
        uint256 indexed positionId,
        uint256 requestedVbWbtc,
        uint256 resultingLtv,
        bool deleveraged,
        bool fullUnwind
    );

    constructor(
        uint256 marketId_,
        address vault_,
        CyvbWbtcLtvPolicy memory policy_,
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
            vault_ == address(0) ||
            poolManager_ == address(0) ||
            fxPool_ == address(0) ||
            fxBase_ == address(0) ||
            fxUsd_ == address(0) ||
            vbWbtc_ == address(0) ||
            vbUsdc_ == address(0) ||
            cyvbUsdc_ == address(0) ||
            router_ == address(0)
        ) revert InvalidAddress();

        if (
            vault_.code.length == 0 ||
            poolManager_.code.length == 0 ||
            fxPool_.code.length == 0 ||
            fxBase_.code.length == 0 ||
            fxUsd_.code.length == 0 ||
            vbWbtc_.code.length == 0 ||
            vbUsdc_.code.length == 0 ||
            cyvbUsdc_.code.length == 0 ||
            router_.code.length == 0
        ) revert InvalidAddress();

        if (
            IFxLongPoolCyvbWBTCV9(fxPool_).collateralToken() != vbWbtc_ ||
            IFxLongPoolCyvbWBTCV9(fxPool_).fxUSD() != fxUsd_ ||
            IFxLongPoolCyvbWBTCV9(fxPool_).poolManager() != poolManager_ ||
            IFxBaseCyvbWBTCV9(fxBase_).stableToken() != vbUsdc_ ||
            IERC4626FxMintCyvbWBTCV9(cyvbUsdc_).asset() != vbUsdc_
        ) revert ProtocolTopologyMismatch();

        VERSION = address(this);
        VAULT = vault_;
        MARKET_ID = marketId_;
        _validatePolicy(policy_);
        TARGET_LTV_BPS = policy_.targetLtvBps;
        HIGH_TRIGGER_BPS = policy_.highTriggerBps;
        HIGH_RESET_BPS = policy_.highResetBps;
        LOW_TRIGGER_BPS = policy_.lowTriggerBps;
        LOW_RESET_BPS = policy_.lowResetBps;
        POOL_MANAGER = poolManager_;
        FX_POOL = fxPool_;
        FXBASE = fxBase_;
        FXUSD = fxUsd_;
        VBWBTC = vbWbtc_;
        VB_USDC = vbUsdc_;
        CYVBUSDC = cyvbUsdc_;
        ROUTER = router_;
    }

    /// @notice Deploy all currently idle vbWBTC into f(x), then borrow to configurable target LTV.
    function deployFreshCapital(
        uint256 minVbUsdcOut_,
        uint256 minCyvbUsdcShares_,
        uint256 deadline_
    ) external {
        _requireVaultContext();
        _checkDeadline(deadline_);
        _requireRoute(FXUSD, VB_USDC);

        uint256 idle = IERC20FxMintCyvbWBTCV9(VBWBTC).balanceOf(address(this));
        if (idle == 0) revert NoCapital();

        uint256 fxUsdBefore = IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this));

        CyvbWbtcLtvPolicy memory policy = getLtvPolicy();

        // f(x) enforces its debt-ratio range at the end of every operate() call.
        // A fresh position therefore cannot be created collateral-only and borrowed
        // against in a later transaction. Add collateral and the required target debt
        // atomically, accounting for f(x)'s live opening fee.
        uint256 position = _supplyCollateralAtTarget(idle, policy.targetLtvBps);

        uint256 fxUsdMinted =
            IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this)) - fxUsdBefore;
        uint256 vbUsdcDeposited;
        if (fxUsdMinted != 0) {
            vbUsdcDeposited = _swap(FXUSD, VB_USDC, fxUsdMinted, minVbUsdcOut_, deadline_);
            _depositStable(vbUsdcDeposited, minCyvbUsdcShares_);
        }

        emit CapitalDeployed(
            VERSION,
            position,
            idle,
            fxUsdMinted,
            vbUsdcDeposited,
            IFxLongPoolCyvbWBTCV9(FX_POOL).getPositionDebtRatio(position)
        );
    }

    /// @notice Permissionless-to-ALPHA via PlasmaVault.execute LTV maintenance.
    /// @dev PlasmaVault's ALPHA role gates execution of this fuse.
    function rebalanceLtv(
        uint256 minSwapOut_,
        uint256 minCyvbUsdcShares_,
        uint256 deadline_
    ) external {
        _requireVaultContext();
        _checkDeadline(deadline_);

        uint256 position = _positionId();
        if (position == 0) revert NoPosition();

        uint256 oldLtv = IFxLongPoolCyvbWBTCV9(FX_POOL).getPositionDebtRatio(position);
        CyvbWbtcLtvPolicy memory policy = getLtvPolicy();

        bool deleveraged;
        if (oldLtv >= _bpsToWad(policy.highTriggerBps)) {
            _requireRoute(VB_USDC, FXUSD);
            _requireRoute(FXUSD, VB_USDC);
            _decreaseDebtTo(position, policy.highResetBps, minSwapOut_, deadline_);
            deleveraged = true;
        } else if (oldLtv <= _bpsToWad(policy.lowTriggerBps)) {
            _requireRoute(FXUSD, VB_USDC);
            uint256 beforeFxUsd = IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this));
            _increaseDebtTo(position, policy.lowResetBps);
            uint256 minted = IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this)) - beforeFxUsd;
            if (minted != 0) {
                uint256 stableOut = _swap(FXUSD, VB_USDC, minted, minSwapOut_, deadline_);
                _depositStable(stableOut, minCyvbUsdcShares_);
            }
        } else {
            revert NoRebalanceNeeded(oldLtv);
        }

        uint256 newLtv = IFxLongPoolCyvbWBTCV9(FX_POOL).getPositionDebtRatio(position);
        emit LtvRebalanced(VERSION, position, oldLtv, newLtv, deleveraged);
    }

    /// @notice IPOR instant-withdraw entry point.
    /// @dev params_[0] is replaced by PlasmaVault with the remaining vbWBTC assets required.
    function instantWithdraw(bytes32[] calldata params_) external {
        _requireVaultContext();

        uint256 requested = params_.length == 0 ? 0 : uint256(params_[0]);
        if (requested == 0) return;
        // 1% + 100 wei over-delivery: an unwind that repays fxUSD below peg lifts PPS, so PlasmaVault would ask for a
        // little more in a second pass - and a second operate() in the same transaction reverts (f(x) lock). Fork-tested
        // up to an 80% redeem (needed ~0.19%). The surplus stays idle in the vault (value-neutral).
        requested = requested + requested / 100 + 100;

        uint256 position = _positionId();
        if (position == 0) return;

        uint256 vaultBalanceBefore = IERC20FxMintCyvbWBTCV9(VBWBTC).balanceOf(address(this));
        uint256 remaining = requested;
        bool deleveraged;
        bool fullUnwind;

        // Stage 1: while the position is below 55% LTV, satisfy as much as possible
        // with collateral only. The safe amount is capped so this stage itself cannot
        // push the position above 55%.
        uint256 currentLtv = IFxLongPoolCyvbWBTCV9(FX_POOL).getPositionDebtRatio(position);
        uint256 maxLtv = _bpsToWad(INSTANT_WITHDRAW_MAX_LTV_BPS);

        if (currentLtv < maxLtv) {
            uint256 safeNet = _safeCollateralOnlyNetWithdrawal(position);
            // collateral-only only when it covers the whole request (one operate() per transaction)
            if (safeNet != 0 && requested <= safeNet) {
                uint256 netToTake = remaining;
                _withdrawCollateral(position, _grossCollateralForNet(netToTake));

                uint256 producedNow =
                    IERC20FxMintCyvbWBTCV9(VBWBTC).balanceOf(address(this)) - vaultBalanceBefore;
                if (producedNow >= requested) {
                    remaining = 0;
                } else {
                    remaining = requested - producedNow;
                }
            }
        }

        if (remaining != 0) {
            (deleveraged, fullUnwind) = _prepareRemainingWithdrawal(position, remaining);
        }

        uint256 produced =
            IERC20FxMintCyvbWBTCV9(VBWBTC).balanceOf(address(this)) - vaultBalanceBefore;
        if (produced < requested) revert InsufficientVbWbtcProduced(requested, produced);

        (uint256 finalColl, uint256 finalDebt) = IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(position);
        uint256 resultingLtv;
        if (finalColl != 0 || finalDebt != 0) {
            resultingLtv = IFxLongPoolCyvbWBTCV9(FX_POOL).getPositionDebtRatio(position);
            if (resultingLtv > maxLtv) revert InstantWithdrawLtvTooHigh(resultingLtv);
        }

        emit InstantWithdrawalPrepared(
            VERSION,
            position,
            requested,
            resultingLtv,
            deleveraged,
            fullUnwind
        );
    }

    function _prepareRemainingWithdrawal(
        uint256 position_,
        uint256 remaining_
    ) private returns (bool deleveraged, bool fullUnwind) {
        (uint256 rawColls, uint256 rawDebts) =
            IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(position_);

        if (remaining_ > _maxNetCollateralWithdrawal(rawColls)) {
            // The withdrawal consumes value held in both the f(x) collateral and
            // nested cyvbUSDC leg. Fully unwind and convert residual stable value
            // back to vbWBTC.
            _requireRoute(VB_USDC, FXUSD);
            _requireRoute(FXUSD, VB_USDC);
            _requireRoute(VB_USDC, VBWBTC);
            _fullUnwind(position_);
            return (rawDebts != 0, true);
        }

        // Repay enough debt first so the requested collateral withdrawal leaves
        // the f(x) position at or below the configured instant-withdraw ceiling.
        uint256 grossColl = _grossCollateralForNet(remaining_);
        uint256 scale = IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).getTokenScalingFactor(VBWBTC);
        uint256 rawGross = (grossColl * scale) / WAD;
        if (rawGross > rawColls) rawGross = rawColls;

        uint256 postRawColl = rawColls - rawGross;
        uint16 maxLtvBps = INSTANT_WITHDRAW_MAX_LTV_BPS;
        uint256 maxPostDebt = _desiredDebt(postRawColl, maxLtvBps);

        if (rawDebts > maxPostDebt) {
            _requireRoute(VB_USDC, FXUSD);
            _requireRoute(FXUSD, VB_USDC);
            _repayAndWithdraw(position_, rawDebts - maxPostDebt, -_toInt(grossColl), 0, block.timestamp);
            deleveraged = true;
        } else {
            _withdrawCollateral(position_, grossColl);
        }
    }

    function _supplyCollateralAtTarget(
        uint256 amount_,
        uint16 targetBps_
    ) private returns (uint256 position) {
        _validateBorrowTarget(targetBps_);

        uint256 existing = _positionId();
        uint256 debtIncrease = _debtIncreaseForSupply(amount_, targetBps_, existing);

        _forceApprove(VBWBTC, POOL_MANAGER, amount_);
        position = IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(
            FX_POOL,
            existing,
            _toInt(amount_),
            _toInt(debtIncrease)
        );
        _forceApprove(VBWBTC, POOL_MANAGER, 0);

        if (existing == 0) {
            CyvbWbtcFxPositionStorage.ids().positionIds[FX_POOL] = position;
        } else if (position != existing) {
            revert ProtocolTopologyMismatch();
        }
    }

    function _debtIncreaseForSupply(
        uint256 amount_,
        uint16 targetBps_,
        uint256 existing_
    ) private view returns (uint256 debtIncrease) {
        uint256 rawColls;
        uint256 rawDebts;
        if (existing_ != 0) {
            (rawColls, rawDebts) = IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(existing_);
        }

        uint256 netRawAdded = _netRawCollateralForSupply(amount_);
        uint256 desiredDebt = _desiredDebtCeil(rawColls + netRawAdded, targetBps_);

        if (desiredDebt > rawDebts) {
            debtIncrease = desiredDebt - rawDebts;
        }
    }

    function _netRawCollateralForSupply(uint256 amount_) private view returns (uint256) {
        uint256 scale = IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).getTokenScalingFactor(VBWBTC);
        uint256 grossRawAdded = (amount_ * scale) / WAD;

        // The live Katana pool implementation does not expose getOpenFeeRatio().
        // Its configured supply fee is available through the official pool
        // configuration contract and matches the fee actually deducted by operate().
        (uint256 supplyFeeRatio,,,) = _feeRatios();
        if (supplyFeeRatio > FEE_PRECISION) supplyFeeRatio = FEE_PRECISION;

        uint256 protocolFeeRaw = (grossRawAdded * supplyFeeRatio) / FEE_PRECISION;
        return grossRawAdded - protocolFeeRaw;
    }


    function _increaseDebtTo(uint256 position_, uint16 targetBps_) private {
        _validateBorrowTarget(targetBps_);
        (uint256 rawColls, uint256 rawDebts) = IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(position_);
        uint256 desired = _desiredDebtCeil(rawColls, targetBps_);
        if (desired <= rawDebts) return;

        IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(
            FX_POOL,
            position_,
            0,
            _toInt(desired - rawDebts)
        );
    }

    function _decreaseDebtTo(
        uint256 position_,
        uint16 targetBps_,
        uint256 minFxUsdOut_,
        uint256 deadline_
    ) private {
        (uint256 rawColls, uint256 rawDebts) = IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(position_);
        uint256 desired = _desiredDebt(rawColls, targetBps_);
        if (rawDebts <= desired) return;

        _repayExact(position_, rawDebts - desired, minFxUsdOut_, deadline_);
    }

    function _repayExact(
        uint256 position_,
        uint256 debtReduction_,
        uint256 minFxUsdOut_,
        uint256 deadline_
    ) private {
        _repayAndWithdraw(position_, debtReduction_, 0, minFxUsdOut_, deadline_);
    }

    /// @dev Repays debtReduction_ and moves collDelta_ collateral (<= 0; type(int256).min = all) in ONE operate().
    function _repayAndWithdraw(
        uint256 position_,
        uint256 debtReduction_,
        int256 collDelta_,
        uint256 minFxUsdOut_,
        uint256 deadline_
    ) private {
        if (debtReduction_ == 0) {
            if (collDelta_ != 0) IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(FX_POOL, position_, collDelta_, 0);
            return;
        }

        (,,, uint256 repayFeeRatio) = _feeRatios();
        uint256 repayFee = (debtReduction_ * repayFeeRatio) / FEE_PRECISION;
        uint256 fxUsdNeeded = debtReduction_ + repayFee;

        uint256 fxUsdBalance = IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this));
        if (fxUsdBalance < fxUsdNeeded) {
            uint256 stablePrice = IFxBaseCyvbWBTCV9(FXBASE).getStableTokenPriceWithScale();
            uint256 missingFxUsd = fxUsdNeeded - fxUsdBalance;
            uint256 stableInput = _ceilDiv(missingFxUsd * WAD, stablePrice);
            stableInput = _ceilDiv(stableInput * (BPS + DELEVERAGE_STABLE_BUFFER_BPS), BPS);

            uint256 stableBalance = IERC20FxMintCyvbWBTCV9(VB_USDC).balanceOf(address(this));
            if (stableBalance < stableInput) {
                uint256 needFromNested = stableInput - stableBalance;
                uint256 maxNested = IERC4626FxMintCyvbWBTCV9(CYVBUSDC).maxWithdraw(address(this));
                if (needFromNested > maxNested) {
                    revert InsufficientNestedStable(needFromNested, maxNested);
                }
                IERC4626FxMintCyvbWBTCV9(CYVBUSDC).withdraw(
                    needFromNested,
                    address(this),
                    address(this)
                );
            }

            _swap(VB_USDC, FXUSD, stableInput, minFxUsdOut_, deadline_);
            fxUsdBalance = IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this));
        }

        if (fxUsdBalance < fxUsdNeeded) revert InsufficientFxUsdForRepay(fxUsdNeeded, fxUsdBalance);

        IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(
            FX_POOL,
            position_,
            collDelta_,
            -_toInt(debtReduction_)
        );

        _recycleResidualFxUsd(deadline_);
    }

    function _recycleResidualFxUsd(uint256 deadline_) private {
        uint256 residualFxUsd = IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this));
        if (residualFxUsd != 0) {
            uint256 stableOut = _swap(FXUSD, VB_USDC, residualFxUsd, 0, deadline_);
            _depositStable(stableOut, 0);
        } else {
            uint256 stable = IERC20FxMintCyvbWBTCV9(VB_USDC).balanceOf(address(this));
            if (stable != 0) _depositStable(stable, 0);
        }
    }

    function _fullUnwind(uint256 position_) private {
        (, uint256 rawDebts) = IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(position_);
        // type(int256).min is f(x)'s explicit "all collateral" sentinel; repay + withdraw-all in one operate()
        _repayAndWithdraw(position_, rawDebts, type(int256).min, 0, block.timestamp);

        uint256 nestedShares = IERC4626FxMintCyvbWBTCV9(CYVBUSDC).balanceOf(address(this));
        if (nestedShares != 0) {
            IERC4626FxMintCyvbWBTCV9(CYVBUSDC).redeem(
                nestedShares,
                address(this),
                address(this)
            );
        }

        uint256 residualFxUsd = IERC20FxMintCyvbWBTCV9(FXUSD).balanceOf(address(this));
        if (residualFxUsd != 0) {
            _swap(FXUSD, VB_USDC, residualFxUsd, 0, block.timestamp);
        }

        uint256 residualStable = IERC20FxMintCyvbWBTCV9(VB_USDC).balanceOf(address(this));
        if (residualStable != 0) {
            _swap(VB_USDC, VBWBTC, residualStable, 0, block.timestamp);
        }
    }

    function _withdrawCollateral(uint256 position_, uint256 grossAmount_) private {
        IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(
            FX_POOL,
            position_,
            -_toInt(grossAmount_),
            0
        );
    }

    function _safeCollateralOnlyNetWithdrawal(uint256 position_) private view returns (uint256) {
        (uint256 rawColls, uint256 rawDebts) = IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(position_);
        if (rawColls == 0 || rawDebts == 0) return _maxNetCollateralWithdrawal(rawColls);

        (uint256 anchorPrice,,) =
            IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();

        uint16 maxLtvBps = INSTANT_WITHDRAW_MAX_LTV_BPS;

        // Minimum raw collateral that must remain so existing debt is <= maxLtv.
        // ceil(rawDebt * 1e18 * BPS / (anchorPrice * maxLtvBps)).
        uint256 numerator = rawDebts * WAD * BPS;
        uint256 denominator = anchorPrice * uint256(maxLtvBps);
        uint256 minimumRawCollateral = _ceilDiv(numerator, denominator);

        if (minimumRawCollateral >= rawColls) return 0;

        uint256 safeRawRemoval = rawColls - minimumRawCollateral;
        uint256 scale = IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).getTokenScalingFactor(VBWBTC);
        uint256 safeGrossToken = (safeRawRemoval * WAD) / scale;

        (, uint256 withdrawFee,,) = _feeRatios();
        if (withdrawFee >= FEE_PRECISION) return 0;
        return (safeGrossToken * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    }

    function _maxNetCollateralWithdrawal(uint256 rawColls_) private view returns (uint256) {
        uint256 scale = IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).getTokenScalingFactor(VBWBTC);
        uint256 tokenAmount = (rawColls_ * WAD) / scale;
        (, uint256 withdrawFee,,) = _feeRatios();
        if (withdrawFee >= FEE_PRECISION) return 0;
        return (tokenAmount * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    }

    function _grossCollateralForNet(uint256 netAmount_) private view returns (uint256) {
        (, uint256 withdrawFee,,) = _feeRatios();
        if (withdrawFee >= FEE_PRECISION) revert ProtocolTopologyMismatch();
        return _ceilDiv(netAmount_ * FEE_PRECISION, FEE_PRECISION - withdrawFee);
    }

    function _desiredDebt(uint256 rawColls_, uint16 targetBps_) private view returns (uint256) {
        if (targetBps_ > BPS) revert InvalidTargetLtv();
        (uint256 anchorPrice,,) =
            IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();
        uint256 collateralUsd = (rawColls_ * anchorPrice) / WAD;
        return (collateralUsd * targetBps_) / BPS;
    }

    function _desiredDebtCeil(uint256 rawColls_, uint16 targetBps_) private view returns (uint256) {
        if (targetBps_ > BPS) revert InvalidTargetLtv();
        (uint256 anchorPrice,,) =
            IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();

        // Round upward because the live f(x) pool enforces a 50% minimum debt ratio
        // and the default cyvbWBTC target is exactly that boundary.
        uint256 collateralUsd = _ceilDiv(rawColls_ * anchorPrice, WAD);
        return _ceilDiv(collateralUsd * targetBps_, BPS);
    }

    function _validateBorrowTarget(uint16 targetBps_) private view {
        uint256 targetWad = _bpsToWad(targetBps_);
        (uint256 minDebtRatio, uint256 maxDebtRatio) =
            IFxLongPoolCyvbWBTCV9(FX_POOL).getDebtRatioRange();

        if (targetWad < minDebtRatio || targetWad > maxDebtRatio) {
            revert InvalidTargetLtv();
        }
    }

    function _depositStable(uint256 amount_, uint256 minShares_) private returns (uint256 shares) {
        if (amount_ == 0) return 0;
        _forceApprove(VB_USDC, CYVBUSDC, amount_);
        shares = IERC4626FxMintCyvbWBTCV9(CYVBUSDC).deposit(amount_, address(this));
        _forceApprove(VB_USDC, CYVBUSDC, 0);
        if (shares < minShares_) revert SwapOutputMismatch();
    }

    function _swap(
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn_,
        uint256 minOut_,
        uint256 deadline_
    ) private returns (uint256 amountOut) {
        if (amountIn_ == 0) return 0;
        _requireRoute(tokenIn_, tokenOut_);

        uint256 beforeOut = IERC20FxMintCyvbWBTCV9(tokenOut_).balanceOf(address(this));

        _forceApprove(tokenIn_, ROUTER, amountIn_);
        amountOut = ICurveYieldRouterCyvbWBTCV9(ROUTER).swapExactInput(
            tokenIn_,
            tokenOut_,
            amountIn_,
            minOut_,
            address(this),
            deadline_
        );
        _forceApprove(tokenIn_, ROUTER, 0);

        uint256 delta = IERC20FxMintCyvbWBTCV9(tokenOut_).balanceOf(address(this)) - beforeOut;
        if (delta != amountOut) revert SwapOutputMismatch();
    }

    function _feeRatios()
        private
        view
        returns (uint256 supplyFee, uint256 withdrawFee, uint256 borrowFee, uint256 repayFee)
    {
        return IFxPoolConfigurationCyvbWBTCV9(
            IFxLongPoolCyvbWBTCV9(FX_POOL).configuration()
        ).getPoolFeeRatio(FX_POOL, address(this));
    }

    /// @notice The active LTV policy (this fuse version's immutables).
    function getLtvPolicy() public view returns (CyvbWbtcLtvPolicy memory) {
        return CyvbWbtcLtvPolicy(TARGET_LTV_BPS, HIGH_TRIGGER_BPS, HIGH_RESET_BPS, LOW_TRIGGER_BPS, LOW_RESET_BPS);
    }

    /// @notice The vault's f(x) position (official FxMintStorageLib slot; 0 = none). Only meaningful in vault context.
    function _positionId() private view returns (uint256) {
        return CyvbWbtcFxPositionStorage.ids().positionIds[FX_POOL];
    }

    function _validatePolicy(CyvbWbtcLtvPolicy memory p_) private pure {
        if (
            p_.targetLtvBps < MIN_TARGET_LTV_BPS || p_.targetLtvBps > MAX_TARGET_LTV_BPS ||
            p_.highTriggerBps < MIN_HIGH_TRIGGER_BPS || p_.highTriggerBps > MAX_HIGH_TRIGGER_BPS ||
            p_.highResetBps < MIN_HIGH_RESET_BPS || p_.highResetBps > MAX_HIGH_RESET_BPS ||
            p_.lowTriggerBps < MIN_LOW_TRIGGER_BPS || p_.lowTriggerBps > MAX_LOW_TRIGGER_BPS ||
            p_.lowResetBps < MIN_LOW_RESET_BPS || p_.lowResetBps > MAX_LOW_RESET_BPS
        ) revert ValueOutOfRange();
        // low trigger < low reset <= target <= high reset < high trigger
        if (
            p_.lowTriggerBps >= p_.lowResetBps || p_.lowResetBps > p_.targetLtvBps ||
            p_.targetLtvBps > p_.highResetBps || p_.highResetBps >= p_.highTriggerBps
        ) revert InvalidOrdering();
    }

    function _requireVaultContext() private view {
        if (address(this) != VAULT) revert WrongVaultContext();
    }

    function _requireRoute(address tokenIn_, address tokenOut_) private view {
        if (ICurveYieldRouterCyvbWBTCV9(ROUTER).routeFor(tokenIn_, tokenOut_).length == 0) {
            revert MissingSwapRoute(tokenIn_, tokenOut_);
        }
    }

    function _checkDeadline(uint256 deadline_) private view {
        if (deadline_ < block.timestamp) revert InvalidDeadline();
    }

    function _bpsToWad(uint16 bps_) private pure returns (uint256) {
        return uint256(bps_) * 1e14;
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
            abi.encodeWithSelector(IERC20FxMintCyvbWBTCV9.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, approveData)) {
            _callOptionalReturn(
                token_,
                abi.encodeWithSelector(IERC20FxMintCyvbWBTCV9.approve.selector, spender_, 0)
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
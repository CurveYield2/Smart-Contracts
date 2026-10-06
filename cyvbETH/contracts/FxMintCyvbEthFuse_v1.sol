// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;\n\nimport "./MorphoVbEthAccounting_v1.sol";\n
interface IERC20FxMintCyvbETHV9 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC4626FxMintCyvbETHV9 {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @dev The f(x) position id lives in IPOR's official fxMINT storage slot (FxMintStorageLib), in the vault.
library CyvbEthFxPositionStorage {
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

struct CyvbEthLtvPolicy {
    uint16 targetLtvBps;
    uint16 highTriggerBps;
    uint16 highResetBps;
    uint16 lowTriggerBps;
    uint16 lowResetBps;
    /// @dev share of newly borrowed fxUSD deposited into the fxBASE earn pool (rest -> vbUSDC -> cyvbUSDC)
    uint16 earnBps;
}

/// @dev External addresses the strategy fuse is bound to (one struct: constructor stack depth).
struct CyvbEthFuseAddresses {
    address poolManager;
    address fxPool;
    address fxBase;
    address earnGauge;
    address fxUsd;
    address vbEth;
    address weEth;
    address morpho;
    address vbEthUsdFeed;
    address vbUsdc;
    address cyvbUsdc;
    address router;
    address collateralIndicator; // CyvbEthIndicatorToken_v1 (FX_COLLATERAL): told the position id when opened; 0 = none
    address debtIndicator; // CyvbEthIndicatorToken_v1 (FXUSD_DEBT): told the position id when it is opened; 0 = none
}

/// @dev f(x) fxUSD stability pool (fxBASE): fxUSD / vbUSDC in, shares out; 1 h cooldown for a fee-free redeem.
interface IFxBasePoolCyvbETHV12 {
    function yieldToken() external view returns (address);
    function deposit(address receiver, address tokenIn, uint256 amount, uint256 minSharesOut) external returns (uint256);
    function requestRedeem(uint256 shares) external;
    function redeem(address receiver, uint256 shares) external returns (uint256 yieldOut, uint256 stableOut);
    function redeemRequests(address account) external view returns (uint128 amount, uint128 unlockAt);
    function previewRedeem(uint256 shares) external view returns (uint256 yieldOut, uint256 stableOut);
    function balanceOf(address account) external view returns (uint256);
}

interface ICyvbDebtIndicatorV13 {
    function registerPosition(uint256 positionId) external;
}

interface IPlasmaVaultBaseGetterCyvbETHV12 {
    function PLASMA_VAULT_BASE() external view returns (address);
}

interface IWithdrawManagerCyvbETHV12 {
    function getSharesToRelease() external view returns (uint256);
    function getWithdrawFee() external view returns (uint256);
    function neededVbEth() external view returns (uint256);
}

/// @dev fxBASE gauge (SharedLiquidityGauge): stake fxBASE shares, earn the reward token (weETH).
interface IFxBaseGaugeCyvbETHV12 {
    function stakingToken() external view returns (address);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IFxPoolManagerCyvbETHV9 {
    function operate(
        address pool,
        uint256 positionId,
        int256 newColl,
        int256 newDebt
    ) external returns (uint256);

    function getTokenScalingFactor(address token) external view returns (uint256);
}

interface IFxLongPoolCyvbETHV9 {
    function collateralToken() external view returns (address);
    function fxUSD() external view returns (address);
    function poolManager() external view returns (address);
    function priceOracle() external view returns (address);
    function configuration() external view returns (address);
    function getDebtRatioRange() external view returns (uint256 minDebtRatio, uint256 maxDebtRatio);
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function getPositionDebtRatio(uint256 tokenId) external view returns (uint256 debtRatio);
}

interface IFxPriceOracleCyvbETHV9 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

interface IFxPoolConfigurationCyvbETHV9 {
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

interface IFxBaseCyvbETHV9 {
    function stableToken() external view returns (address);
    function getStableTokenPriceWithScale() external view returns (uint256);
}

interface IChainlinkCyvbETHV1 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ICurveYieldRouterCyvbETHV9 {
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

/// @title FxMintCyvbEthFuse_v1
/// @notice cyvbETH strategy fuse:
///         keeper-selected vbETH -> weETH -> f(x) collateral -> fxUSD debt -> vbUSDC -> nested cyvbUSDC,
///         while any other keeper-selected vbETH may be lent natively in the specified Morpho market.
/// @dev Runs by delegatecall from IPOR PlasmaVault. Position ownership, token balances and approvals
///      therefore all belong to the PlasmaVault.
///
///      LTV behavior:
///      - fresh capital borrows to configurable target (default 50%),
///      - >= high trigger (default 60%) deleverages to high reset (default 58%),
///      - <= low trigger (default 45%) borrows to low reset (default 50%),
///      - instant withdrawals never leave the f(x) position above 55%.
///
///      v1: cyvbWBTC behavior cloned for vbETH. Because Katana f(x) has no vbETH collateral pool, only the f(x)
///      allocation is swapped through the guarded vbETH/weETH route; Morpho remains native vbETH. NAV includes
///      idle vbETH + accrued Morpho vbETH + live weETH f(x) collateral.
///      v12 (EARN_POOL_SPEC_v1): borrowed fxUSD is split EARN_BPS -> fxBASE earn pool (staked in its gauge, no swap)
///      and the rest -> vbUSDC -> cyvbUSDC. The earn pool is never an instant source (1% instant-redeem fee): the
///      custom withdraw manager calls requestEarnRedeem (on a scheduled request) and completeScheduledWithdrawal
///      (after the fxBASE 1 h cooldown). Residual fxUSD after a repay goes back to the earn pool, not through a swap.
///      v11: the Katana f(x) PoolManager locks after ONE operate() per transaction (transient lock), so every path
///      does at most one operate(): repay + collateral withdrawal are a single operate(pos, -coll, -debt). A full exit
///      whose nested stable leg cannot cover debt + repay fee reverts InsufficientNestedStable (the f(x) borrow fee
///      and entry swap leave the stable leg slightly below the debt): that tail goes through a scheduled withdrawal.
contract FxMintCyvbEthFuse_v1 {
    /// @notice Vault-local fxMINT market (balance: FxMintCyvbEthBalanceFuse_v4); depends on 100_001 (cyvbUSDC) and 7.
    uint256 public immutable MARKET_ID;
    /// @notice Instant withdrawals never leave the f(x) position above this LTV.
    uint16 public constant INSTANT_WITHDRAW_MAX_LTV_BPS = 5_500;
    // LTV policy bounds: +/-10% relative to each baseline (folded from CyvbEthLtvConfig_v3)
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
    /// @notice The cyvbETH PlasmaVault this fuse runs in (delegatecall context check).
    address public immutable VAULT;
    // LTV policy (immutable: a policy change = a new fuse version installed by the fuse manager)
    uint16 public immutable TARGET_LTV_BPS;
    uint16 public immutable HIGH_TRIGGER_BPS;
    uint16 public immutable HIGH_RESET_BPS;
    uint16 public immutable LOW_TRIGGER_BPS;
    uint16 public immutable LOW_RESET_BPS;
    /// @notice Share of newly borrowed fxUSD sent to the fxBASE earn pool (bps); default 6,000.
    uint16 public immutable EARN_BPS;
    /// @notice fxBASE gauge the earn-pool shares are staked in.
    address public immutable EARN_GAUGE;
    /// @notice Extra earn-pool shares requested above the proportional need (covers repay fee / rounding).
    uint256 public constant EARN_REDEEM_BUFFER_BPS = 300;
    /// @dev PPS guard rounding allowance (USD WAD; 1e-9 USD).
    uint256 private constant PPS_ROUNDING_USD = 1e9;
    /// @dev PlasmaVaultStorageLib.WITHDRAW_MANAGER (corrected, IL-6952)
    bytes32 private constant WITHDRAW_MANAGER_SLOT = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;
    address public immutable POOL_MANAGER;
    address public immutable FX_POOL;
    address public immutable FXBASE;
    address public immutable FXUSD;
    address public immutable VBETH;
    address public immutable WEETH;
    IMorphoCyvbEthV1 public immutable MORPHO;
    address public immutable VBETH_USD_FEED;
    bytes32 public constant MORPHO_MARKET_ID =
        0x2c4f26c76b4de51d3c9260c15a796cd2a35efab17786d0aa78ca2e638b0f8ba8;
    address public immutable VB_USDC;
    address public immutable CYVBUSDC;
    address public immutable ROUTER;
    address public immutable DEBT_INDICATOR;
    address public immutable COLLATERAL_INDICATOR;

    error InvalidAddress();
    error PpsWouldDrop(uint256 ppsBefore, uint256 ppsAfter);
    error FeeBurnFailed(bytes reason);
    error UnwindCostAboveFee(uint256 valueFloor, uint256 valueAfter);
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
    error InsufficientVbEthProduced(uint256 required, uint256 produced);
    error AmountTooLargeForInt256();
    error TokenOperationFailed(address token);
    error SwapOutputMismatch();
    error InvalidPrice();
    error MorphoWithdrawFailed();

    event CapitalDeployed(
        address indexed version,
        uint256 indexed positionId,
        uint256 vbEthSupplied,
        uint256 fxUsdBorrowed,
        uint256 vbUsdcDeposited,
        uint256 resultingLtv
    );

    event MorphoSupplied(address indexed version, uint256 vbEthAmount);
    event MorphoWithdrawn(address indexed version, uint256 vbEthAmount);

    event LtvRebalanced(
        address indexed version,
        uint256 indexed positionId,
        uint256 oldLtv,
        uint256 newLtv,
        bool deleveraged
    );

    event EarnRedeemRequested(address indexed version, uint256 neededVbEth, uint256 shares);
    event ScheduledWithdrawalCompleted(address indexed version, uint256 neededVbEth, uint256 redeemedShares);
    event InstantWithdrawalPrepared(
        address indexed version,
        uint256 indexed positionId,
        uint256 requestedVbEth,
        uint256 resultingLtv,
        bool deleveraged,
        bool fullUnwind
    );

    constructor(
        uint256 marketId_,
        address vault_,
        CyvbEthLtvPolicy memory policy_,
        CyvbEthFuseAddresses memory a_
    ) {
        if (
            vault_.code.length == 0 || a_.poolManager.code.length == 0 || a_.fxPool.code.length == 0 ||
            a_.fxBase.code.length == 0 || a_.earnGauge.code.length == 0 || a_.fxUsd.code.length == 0 ||
            a_.vbEth.code.length == 0 || a_.weEth.code.length == 0 || a_.morpho.code.length == 0 ||
            a_.vbEthUsdFeed.code.length == 0 || a_.vbUsdc.code.length == 0 || a_.cyvbUsdc.code.length == 0 ||
            a_.router.code.length == 0
        ) revert InvalidAddress();

        if (
            IFxLongPoolCyvbETHV9(a_.fxPool).collateralToken() != a_.weEth ||
            IFxLongPoolCyvbETHV9(a_.fxPool).fxUSD() != a_.fxUsd ||
            IFxLongPoolCyvbETHV9(a_.fxPool).poolManager() != a_.poolManager ||
            IFxBaseCyvbETHV9(a_.fxBase).stableToken() != a_.vbUsdc ||
            IFxBasePoolCyvbETHV12(a_.fxBase).yieldToken() != a_.fxUsd ||
            IFxBaseGaugeCyvbETHV12(a_.earnGauge).stakingToken() != a_.fxBase ||
            IERC4626FxMintCyvbETHV9(a_.cyvbUsdc).asset() != a_.vbUsdc
        ) revert ProtocolTopologyMismatch();

        MorphoMarketParamsCyvbEthV1 memory morphoParams =
            IMorphoCyvbEthV1(a_.morpho).idToMarketParams(MORPHO_MARKET_ID);
        if (morphoParams.loanToken != a_.vbEth) revert ProtocolTopologyMismatch();

        VERSION = address(this);
        VAULT = vault_;
        MARKET_ID = marketId_;
        _validatePolicy(policy_);
        TARGET_LTV_BPS = policy_.targetLtvBps;
        HIGH_TRIGGER_BPS = policy_.highTriggerBps;
        HIGH_RESET_BPS = policy_.highResetBps;
        LOW_TRIGGER_BPS = policy_.lowTriggerBps;
        LOW_RESET_BPS = policy_.lowResetBps;
        EARN_BPS = policy_.earnBps;
        EARN_GAUGE = a_.earnGauge;
        POOL_MANAGER = a_.poolManager;
        FX_POOL = a_.fxPool;
        FXBASE = a_.fxBase;
        FXUSD = a_.fxUsd;
        VBETH = a_.vbEth;
        WEETH = a_.weEth;
        MORPHO = IMorphoCyvbEthV1(a_.morpho);
        VBETH_USD_FEED = a_.vbEthUsdFeed;
        VB_USDC = a_.vbUsdc;
        CYVBUSDC = a_.cyvbUsdc;
        ROUTER = a_.router;
        DEBT_INDICATOR = a_.debtIndicator;
        COLLATERAL_INDICATOR = a_.collateralIndicator;
    }

    /// @notice Deploy all currently idle vbETH into f(x), then borrow to configurable target LTV.
    function deployFreshCapital(
        uint256 amount_,
        uint256 minWeEthOut_,
        uint256 minVbUsdcOut_,
        uint256 minCyvbUsdcShares_,
        uint256 deadline_
    ) external {
        _requireVaultContext();
        _checkDeadline(deadline_);
        _requireRoute(FXUSD, VB_USDC);
        _requireRoute(VBETH, WEETH);

        // PPS guard: snapshot, burn the fee shares the withdraw manager holds (the onboarding fee is what pays for the
        // deploy), deploy, and revert if PPS would end lower.
        // Chunked: amount_ (0 = all) of the deployable idle; the chunk burns its pro-rata part of the fee shares, so
        // each chunk's onboarding fee offsets its own cost (fxUSD/vbUSDC slippage grows with size).
        (uint256 valueBefore, uint256 supplyBefore) = _ppsSnapshot();

        // never deploy vbETH already released to scheduled withdrawals (reserved for their owners)
        uint256 deployable = _deployableIdle();
        if (deployable == 0) revert NoCapital();
        uint256 idle = amount_ == 0 || amount_ > deployable ? deployable : amount_;
        _burnManagerFeeShares(idle, deployable);

        uint256 weEthAmount = _swap(VBETH, WEETH, idle, minWeEthOut_, deadline_);
        uint256 fxUsdBefore = IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this));

        CyvbEthLtvPolicy memory policy = getLtvPolicy();

        // f(x) enforces its debt-ratio range at the end of every operate() call.
        // A fresh position therefore cannot be created collateral-only and borrowed
        // against in a later transaction. Add collateral and the required target debt
        // atomically, accounting for f(x)'s live opening fee.
        uint256 position = _supplyCollateralAtTarget(weEthAmount, policy.targetLtvBps);

        uint256 fxUsdMinted =
            IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this)) - fxUsdBefore;
        // minVbUsdcOut_ applies to the cyvbUSDC part only ((1 - EARN_BPS) of the minted fxUSD)
        (, uint256 vbUsdcDeposited) = _deployBorrowed(fxUsdMinted, minVbUsdcOut_, minCyvbUsdcShares_, deadline_);

        emit CapitalDeployed(
            VERSION,
            position,
            idle,
            fxUsdMinted,
            vbUsdcDeposited,
            IFxLongPoolCyvbETHV9(FX_POOL).getPositionDebtRatio(position)
        );
        _requirePpsNotLower(valueBefore, supplyBefore);
    }

    /// @notice Keeper-controlled native-vbETH lending lane. amount_ == 0 supplies all deployable idle vbETH.
    function deployToMorpho(uint256 amount_) external {
        _requireVaultContext();
        (uint256 valueBefore, uint256 supplyBefore) = _ppsSnapshot();

        uint256 deployable = _deployableIdle();
        if (deployable == 0) revert NoCapital();
        uint256 amount = amount_ == 0 || amount_ > deployable ? deployable : amount_;
        _burnManagerFeeShares(amount, deployable);

        MorphoMarketParamsCyvbEthV1 memory params = MORPHO.idToMarketParams(MORPHO_MARKET_ID);
        _forceApprove(VBETH, address(MORPHO), amount);
        (uint256 supplied,) = MORPHO.supply(params, amount, 0, address(this), bytes(""));
        _forceApprove(VBETH, address(MORPHO), 0);

        emit MorphoSupplied(VERSION, supplied);
        _requirePpsNotLower(valueBefore, supplyBefore);
    }

    /// @notice Keeper-controlled return of Morpho-supplied vbETH to idle. amount_ == 0 requests the full position.
    function withdrawFromMorpho(uint256 amount_) external returns (uint256 withdrawn) {
        _requireVaultContext();
        (uint256 valueBefore, uint256 supplyBefore) = _ppsSnapshot();
        withdrawn = _withdrawMorpho(amount_, false);
        _requirePpsNotLower(valueBefore, supplyBefore);
    }

    function morphoSupplyAssets() public view returns (uint256) {
        return MorphoVbEthAccounting_v1.expectedSupplyAssets(MORPHO, MORPHO_MARKET_ID, address(this));
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

        uint256 oldLtv = IFxLongPoolCyvbETHV9(FX_POOL).getPositionDebtRatio(position);
        CyvbEthLtvPolicy memory policy = getLtvPolicy();

        bool deleveraged;
        if (oldLtv >= _bpsToWad(policy.highTriggerBps)) {
            _requireRoute(VB_USDC, FXUSD);
            _requireRoute(FXUSD, VB_USDC);
            _decreaseDebtTo(position, policy.highResetBps, minSwapOut_, deadline_);
            deleveraged = true;
        } else if (oldLtv <= _bpsToWad(policy.lowTriggerBps)) {
            _requireRoute(FXUSD, VB_USDC);
            uint256 beforeFxUsd = IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this));
            _increaseDebtTo(position, policy.lowResetBps);
            uint256 minted = IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this)) - beforeFxUsd;
            _deployBorrowed(minted, minSwapOut_, minCyvbUsdcShares_, deadline_);
        } else {
            revert NoRebalanceNeeded(oldLtv);
        }

        uint256 newLtv = IFxLongPoolCyvbETHV9(FX_POOL).getPositionDebtRatio(position);
        emit LtvRebalanced(VERSION, position, oldLtv, newLtv, deleveraged);
    }

    /// @notice IPOR instant-withdraw entry point.
    /// @dev params_[0] is replaced by PlasmaVault with the remaining vbETH assets required.
    function instantWithdraw(bytes32[] calldata params_) external {
        _requireVaultContext();

        uint256 requested = params_.length == 0 ? 0 : uint256(params_[0]);
        if (requested == 0) return;
        uint256 valueFloor = _instantValueFloor(requested);
        requested = requested + requested / 100 + 100;

        uint256 vaultBalanceBefore = IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this));
        uint256 remaining = requested;

        uint256 morphoAvailable = morphoSupplyAssets();
        if (morphoAvailable != 0) {
            uint256 ask = remaining < morphoAvailable ? remaining : morphoAvailable;
            _withdrawMorpho(ask, true);
            uint256 fromMorpho = IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this)) - vaultBalanceBefore;
            remaining = fromMorpho >= requested ? 0 : requested - fromMorpho;
        }

        uint256 position = _positionId();
        bool deleveraged;
        bool fullUnwind;

        if (remaining != 0 && position != 0) {
            _requireRoute(WEETH, VBETH);
            uint256 currentLtv = IFxLongPoolCyvbETHV9(FX_POOL).getPositionDebtRatio(position);
            uint256 maxLtv = _bpsToWad(INSTANT_WITHDRAW_MAX_LTV_BPS);

            if (currentLtv < maxLtv) {
                uint256 safeNetWeEth = _safeCollateralOnlyNetWithdrawal(position);
                uint256 safeNetVbEth = _weEthToVbEth(safeNetWeEth);
                if (safeNetVbEth != 0 && remaining <= safeNetVbEth) {
                    uint256 netWeEthNeeded = _weEthForVbEthValue(remaining);
                    _withdrawCollateral(position, _grossCollateralForNet(netWeEthNeeded));

                    uint256 producedNow =
                        IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this)) - vaultBalanceBefore;
                    remaining = producedNow >= requested ? 0 : requested - producedNow;
                }
            }

            if (remaining != 0) {
                (deleveraged, fullUnwind) =
                    _prepareRemainingWithdrawal(position, remaining, INSTANT_WITHDRAW_MAX_LTV_BPS);
            }
        }

        uint256 produced =
            IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this)) - vaultBalanceBefore;
        if (produced < requested) revert InsufficientVbEthProduced(requested, produced);

        uint256 resultingLtv;
        if (position != 0) {
            (uint256 finalColl, uint256 finalDebt) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position);
            if (finalColl != 0 || finalDebt != 0) {
                resultingLtv = IFxLongPoolCyvbETHV9(FX_POOL).getPositionDebtRatio(position);
                if (resultingLtv > _bpsToWad(INSTANT_WITHDRAW_MAX_LTV_BPS)) {
                    revert InstantWithdrawLtvTooHigh(resultingLtv);
                }
            }
        }

        _requireValueAtLeast(valueFloor);
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
        uint256 remaining_,
        uint16 maxLtvBps_
    ) private returns (bool deleveraged, bool fullUnwind) {
        (uint256 rawColls, uint256 rawDebts) =
            IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position_);

        uint256 maxNetWeEth = _maxNetCollateralWithdrawal(rawColls);
        if (remaining_ > _weEthToVbEth(maxNetWeEth)) {
            _requireRoute(VB_USDC, FXUSD);
            _requireRoute(FXUSD, VB_USDC);
            _requireRoute(VB_USDC, VBETH);
            _requireRoute(WEETH, VBETH);
            _fullUnwind(position_);
            return (rawDebts != 0, true);
        }

        uint256 netWeEthNeeded = _weEthForVbEthValue(remaining_);
        uint256 grossColl = _grossCollateralForNet(netWeEthNeeded);
        uint256 scale = IFxPoolManagerCyvbETHV9(POOL_MANAGER).getTokenScalingFactor(WEETH);
        uint256 rawGross = (grossColl * scale) / WAD;
        if (rawGross > rawColls) rawGross = rawColls;

        uint256 postRawColl = rawColls - rawGross;
        uint256 maxPostDebt = _desiredDebt(postRawColl, maxLtvBps_);

        if (rawDebts > maxPostDebt) {
            _requireRoute(VB_USDC, FXUSD);
            _requireRoute(FXUSD, VB_USDC);
            _requireRoute(WEETH, VBETH);
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

        _forceApprove(WEETH, POOL_MANAGER, amount_);
        position = IFxPoolManagerCyvbETHV9(POOL_MANAGER).operate(
            FX_POOL,
            existing,
            _toInt(amount_),
            _toInt(debtIncrease)
        );
        _forceApprove(WEETH, POOL_MANAGER, 0);

        if (existing == 0) {
            CyvbEthFxPositionStorage.ids().positionIds[FX_POOL] = position;
            if (DEBT_INDICATOR != address(0)) ICyvbDebtIndicatorV13(DEBT_INDICATOR).registerPosition(position);
            if (COLLATERAL_INDICATOR != address(0)) ICyvbDebtIndicatorV13(COLLATERAL_INDICATOR).registerPosition(position);
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
            (rawColls, rawDebts) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(existing_);
        }

        uint256 netRawAdded = _netRawCollateralForSupply(amount_);
        uint256 desiredDebt = _desiredDebtCeil(rawColls + netRawAdded, targetBps_);

        if (desiredDebt > rawDebts) {
            debtIncrease = desiredDebt - rawDebts;
        }
    }

    function _netRawCollateralForSupply(uint256 amount_) private view returns (uint256) {
        uint256 scale = IFxPoolManagerCyvbETHV9(POOL_MANAGER).getTokenScalingFactor(WEETH);
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
        (uint256 rawColls, uint256 rawDebts) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position_);
        uint256 desired = _desiredDebtCeil(rawColls, targetBps_);
        if (desired <= rawDebts) return;

        IFxPoolManagerCyvbETHV9(POOL_MANAGER).operate(
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
        (uint256 rawColls, uint256 rawDebts) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position_);
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
            if (collDelta_ != 0) IFxPoolManagerCyvbETHV9(POOL_MANAGER).operate(FX_POOL, position_, collDelta_, 0);
            return;
        }

        (,,, uint256 repayFeeRatio) = _feeRatios();
        uint256 repayFee = (debtReduction_ * repayFeeRatio) / FEE_PRECISION;
        uint256 fxUsdNeeded = debtReduction_ + repayFee;

        uint256 fxUsdBalance = IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this));
        if (fxUsdBalance < fxUsdNeeded) {
            uint256 stablePrice = IFxBaseCyvbETHV9(FXBASE).getStableTokenPriceWithScale();
            uint256 missingFxUsd = fxUsdNeeded - fxUsdBalance;
            uint256 stableInput = _ceilDiv(missingFxUsd * WAD, stablePrice);
            stableInput = _ceilDiv(stableInput * (BPS + DELEVERAGE_STABLE_BUFFER_BPS), BPS);

            uint256 stableBalance = IERC20FxMintCyvbETHV9(VB_USDC).balanceOf(address(this));
            if (stableBalance < stableInput) {
                uint256 needFromNested = stableInput - stableBalance;
                uint256 maxNested = IERC4626FxMintCyvbETHV9(CYVBUSDC).maxWithdraw(address(this));
                if (needFromNested > maxNested) {
                    revert InsufficientNestedStable(needFromNested, maxNested);
                }
                IERC4626FxMintCyvbETHV9(CYVBUSDC).withdraw(
                    needFromNested,
                    address(this),
                    address(this)
                );
            }

            _swap(VB_USDC, FXUSD, stableInput, minFxUsdOut_, deadline_);
            fxUsdBalance = IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this));
        }

        if (fxUsdBalance < fxUsdNeeded) revert InsufficientFxUsdForRepay(fxUsdNeeded, fxUsdBalance);

        IFxPoolManagerCyvbETHV9(POOL_MANAGER).operate(
            FX_POOL,
            position_,
            collDelta_,
            -_toInt(debtReduction_)
        );

        uint256 weEthOut = IERC20FxMintCyvbETHV9(WEETH).balanceOf(address(this));
        if (weEthOut != 0) _swap(WEETH, VBETH, weEthOut, 0, deadline_);

        _recycleResidualFxUsd(deadline_);
    }

    function _recycleResidualFxUsd(uint256 deadline_) private {
        uint256 residualFxUsd = IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this));
        if (residualFxUsd != 0) {
            if (EARN_BPS != 0) _depositEarn(residualFxUsd);
            else _swap(FXUSD, VB_USDC, residualFxUsd, 0, deadline_);
        }
        uint256 stable = IERC20FxMintCyvbETHV9(VB_USDC).balanceOf(address(this));
        if (stable != 0) _depositStable(stable, 0);
    }

    // ---------------------------------------------------------------- earn pool (fxBASE + gauge)

    /// @dev Splits newly borrowed fxUSD: EARN_BPS into the earn pool, the rest swapped to vbUSDC into cyvbUSDC.
    function _deployBorrowed(
        uint256 fxUsd_,
        uint256 minVbUsdcOut_,
        uint256 minCyvbUsdcShares_,
        uint256 deadline_
    ) private returns (uint256 toEarn, uint256 vbUsdcDeposited) {
        if (fxUsd_ == 0) return (0, 0);
        toEarn = (fxUsd_ * EARN_BPS) / BPS;
        if (toEarn != 0) _depositEarn(toEarn);
        uint256 rest = fxUsd_ - toEarn;
        if (rest != 0) {
            vbUsdcDeposited = _swap(FXUSD, VB_USDC, rest, minVbUsdcOut_, deadline_);
            _depositStable(vbUsdcDeposited, minCyvbUsdcShares_);
        }
    }

    function _depositEarn(uint256 fxUsd_) private {
        _forceApprove(FXUSD, FXBASE, fxUsd_);
        uint256 shares = IFxBasePoolCyvbETHV12(FXBASE).deposit(address(this), FXUSD, fxUsd_, 0);
        _forceApprove(FXUSD, FXBASE, 0);
        _forceApprove(FXBASE, EARN_GAUGE, shares);
        IFxBaseGaugeCyvbETHV12(EARN_GAUGE).deposit(shares);
        _forceApprove(FXBASE, EARN_GAUGE, 0);
    }

    /// @notice Scheduled withdrawal, step 1 (called by the withdraw manager through vault.execute): unstakes and
    ///         requests the fee-free fxBASE redeem for the earn shares that `neededVbEth_` of strategy value needs.
    function requestEarnRedeem(uint256 neededVbEth_) external {
        _requireVaultContext();
        uint256 staked = IFxBaseGaugeCyvbETHV12(EARN_GAUGE).balanceOf(address(this));
        if (staked == 0 || neededVbEth_ == 0) return;
        uint256 netUsd = _strategyNetUsd();
        uint256 neededUsd = _vbEthToUsd(neededVbEth_);
        uint256 shares = netUsd == 0 || neededUsd >= netUsd
            ? staked
            : (staked * neededUsd * (BPS + EARN_REDEEM_BUFFER_BPS)) / (netUsd * BPS);
        if (shares > staked) shares = staked;
        if (shares == 0) return;
        IFxBaseGaugeCyvbETHV12(EARN_GAUGE).withdraw(shares);
        IFxBasePoolCyvbETHV12(FXBASE).requestRedeem(shares);
        emit EarnRedeemRequested(VERSION, neededVbEth_, shares);
    }

    /// @notice Scheduled withdrawal, step 2 (withdraw manager, after the fxBASE cooldown): redeems the requested earn
    ///         shares and frees `neededVbEth_` of vbETH with one operate() at or below the target LTV. Reverts while
    ///         the fxBASE redeem is still locked.
    function completeScheduledWithdrawal(uint256 neededVbEth_, uint256 deadline_) external {
        _requireVaultContext();
        _checkDeadline(deadline_);
        (uint256 valueBefore, uint256 supplyBefore) = _ppsSnapshot();
        _burnManagerFeeShares(1, 1);
        {
            address wm = _withdrawManager();
            if (wm != address(0)) {
                uint256 owed = IWithdrawManagerCyvbETHV12(wm).neededVbEth();
                if (owed > neededVbEth_) neededVbEth_ = owed;
            }
            if (neededVbEth_ != 0) neededVbEth_ += neededVbEth_ / 300 + 100;
        }

        (uint128 requested,) = IFxBasePoolCyvbETHV12(FXBASE).redeemRequests(address(this));
        if (requested != 0) IFxBasePoolCyvbETHV12(FXBASE).redeem(address(this), requested);

        if (neededVbEth_ != 0) {
            uint256 beforeMorpho = IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this));
            uint256 morphoAvailable = morphoSupplyAssets();
            if (morphoAvailable != 0) {
                uint256 ask = neededVbEth_ < morphoAvailable ? neededVbEth_ : morphoAvailable;
                _withdrawMorpho(ask, true);
                uint256 got = IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this)) - beforeMorpho;
                neededVbEth_ = got >= neededVbEth_ ? 0 : neededVbEth_ - got;
            }
        }

        uint256 position = _positionId();
        if (position != 0 && neededVbEth_ != 0) {
            _requireRoute(VB_USDC, FXUSD);
            _requireRoute(WEETH, VBETH);
            _prepareRemainingWithdrawal(position, neededVbEth_, TARGET_LTV_BPS);
        }
        _recycleResidualFxUsd(deadline_);
        _requirePpsNotLower(valueBefore, supplyBefore);
        emit ScheduledWithdrawalCompleted(VERSION, neededVbEth_, requested);
    }

    /// @dev Net USD (WAD) of the strategy: f(x) exit value - debt + cyvbUSDC + earn pool (staked + held) + residuals.
    function _strategyNetUsd() private view returns (uint256 net_) {
        uint256 position = _positionId();
        uint256 debt;
        if (position != 0) {
            (uint256 rawColls, uint256 rawDebts) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position);
            (uint256 anchorPrice,,) =
                IFxPriceOracleCyvbETHV9(IFxLongPoolCyvbETHV9(FX_POOL).priceOracle()).getPrice();
            net_ = (rawColls * anchorPrice) / WAD;
            debt = rawDebts;
        }

        uint256 morphoAssets = morphoSupplyAssets();
        if (morphoAssets != 0) net_ += _vbEthToUsd(morphoAssets);

        uint256 nested = IERC4626FxMintCyvbETHV9(CYVBUSDC).balanceOf(address(this));
        if (nested != 0) net_ += IERC4626FxMintCyvbETHV9(CYVBUSDC).convertToAssets(nested) * 1e12;
        uint256 earnShares = IFxBaseGaugeCyvbETHV12(EARN_GAUGE).balanceOf(address(this))
            + IFxBasePoolCyvbETHV12(FXBASE).balanceOf(address(this));
        if (earnShares != 0) {
            (uint256 yieldOut, uint256 stableOut) = IFxBasePoolCyvbETHV12(FXBASE).previewRedeem(earnShares);
            net_ += yieldOut + stableOut * 1e12;
        }
        net_ = net_ > debt ? net_ - debt : 0;
    }

    // ---------------------------------------------------------------- PPS guard (deployFreshCapital)

    /// @dev Vault value on the NAV basis (accounting v2: idle vbETH + f(x) collateral, USD WAD; the stable side and the
    ///      debt are outside share value) and share supply, for a before/after PPS check.
    function _ppsSnapshot() private view returns (uint256 value_, uint256 supply_) {
        value_ = _vbEthToUsd(
            IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this)) + morphoSupplyAssets()
        ) + _collateralUsd();
        supply_ = IERC20FxMintCyvbETHV9(address(this)).totalSupply();
    }

    /// @dev PPS after >= PPS before (cross-multiplied), with a 1e9-wei-USD rounding allowance.
    function _requirePpsNotLower(uint256 valueBefore_, uint256 supplyBefore_) private view {
        (uint256 valueAfter, uint256 supplyAfter) = _ppsSnapshot();
        if (supplyBefore_ == 0 || supplyAfter == 0) return;
        if ((valueAfter + PPS_ROUNDING_USD) * supplyBefore_ < valueBefore_ * supplyAfter) {
            revert PpsWouldDrop(valueBefore_ * WAD / supplyBefore_, valueAfter * WAD / supplyAfter);
        }
    }

    /// @dev Instant path: vault value (USD) after the unwind must stay >= before - (requested x instant fee), the value
    ///      the vault burns right after this fuse returns. So the redeem as a whole never lowers PPS.
    function _instantValueFloor(uint256 requested_) private view returns (uint256) {
        (uint256 value,) = _ppsSnapshot();
        address wm = _withdrawManager();
        uint256 fee = wm == address(0) ? 0 : IWithdrawManagerCyvbETHV12(wm).getWithdrawFee();
        uint256 cap = (_vbEthToUsd(requested_) * fee) / WAD;
        return value > cap ? value - cap : 0;
    }

    function _requireValueAtLeast(uint256 floor_) private view {
        (uint256 value,) = _ppsSnapshot();
        if (value + PPS_ROUNDING_USD < floor_) revert UnwindCostAboveFee(floor_, value);
    }

    /// @dev Burns the vault shares held by the withdraw manager (onboarding + request fee shares) - IPOR's
    ///      BurnRequestFeeFuse mechanism (PlasmaVaultBase.updateInternal to address(0)).
    /// @dev Burns num_/den_ of the fee shares the manager holds (deploy chunk: chunk / deployable idle; 1/1 = all).
    function _burnManagerFeeShares(uint256 num_, uint256 den_) private {
        address wm = _withdrawManager();
        if (wm == address(0)) return;
        uint256 shares = (IERC20FxMintCyvbETHV9(address(this)).balanceOf(wm) * num_) / den_;
        if (shares == 0) return;
        address base = IPlasmaVaultBaseGetterCyvbETHV12(address(this)).PLASMA_VAULT_BASE();
        (bool ok, bytes memory reason) = base.delegatecall(
            abi.encodeWithSignature("updateInternal(address,address,uint256)", wm, address(0), shares)
        );
        if (!ok) revert FeeBurnFailed(reason);
    }

    /// @dev Idle vbETH minus what is reserved for released (unclaimed) scheduled withdrawals.
    function _deployableIdle() private view returns (uint256) {
        uint256 idle = IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(this));
        address wm = _withdrawManager();
        if (wm == address(0)) return idle;
        uint256 reserved = IERC4626FxMintCyvbETHV9(address(this)).convertToAssets(
            IWithdrawManagerCyvbETHV12(wm).getSharesToRelease()
        );
        return idle > reserved ? idle - reserved : 0;
    }

    /// @dev PlasmaVaultStorageLib.WITHDRAW_MANAGER (corrected IL-6952 slot).
    function _withdrawManager() private view returns (address wm_) {
        bytes32 slot = WITHDRAW_MANAGER_SLOT;
        assembly {
            wm_ := sload(slot)
        }
    }

    /// @dev f(x) collateral in USD WAD (raw collateral is 18-decimal scaled).
    function _collateralUsd() private view returns (uint256) {
        uint256 position = _positionId();
        if (position == 0) return 0;
        (uint256 rawColls,) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position);
        (uint256 anchorPrice,,) =
            IFxPriceOracleCyvbETHV9(IFxLongPoolCyvbETHV9(FX_POOL).priceOracle()).getPrice();
        return (rawColls * anchorPrice) / WAD;
    }

    function _vbEthToUsd(uint256 amount_) private view returns (uint256) {
        return (amount_ * _vbEthPriceWad()) / WAD;
    }

    function _vbEthPriceWad() private view returns (uint256) {
        (, int256 answer,,,) = IChainlinkCyvbETHV1(VBETH_USD_FEED).latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        uint8 decimals_ = IChainlinkCyvbETHV1(VBETH_USD_FEED).decimals();
        uint256 p = uint256(answer);
        if (decimals_ == 18) return p;
        if (decimals_ < 18) return p * (10 ** (18 - decimals_));
        return p / (10 ** (decimals_ - 18));
    }

    function _weEthPriceWad() private view returns (uint256) {
        (uint256 anchorPrice,,) =
            IFxPriceOracleCyvbETHV9(IFxLongPoolCyvbETHV9(FX_POOL).priceOracle()).getPrice();
        if (anchorPrice == 0) revert InvalidPrice();
        return anchorPrice;
    }

    function _weEthToVbEth(uint256 weEthAmount_) private view returns (uint256) {
        if (weEthAmount_ == 0) return 0;
        return (weEthAmount_ * _weEthPriceWad()) / _vbEthPriceWad();
    }

    function _weEthForVbEthValue(uint256 vbEthAmount_) private view returns (uint256) {
        if (vbEthAmount_ == 0) return 0;
        uint256 numerator = vbEthAmount_ * _vbEthPriceWad();
        return _ceilDiv(numerator, _weEthPriceWad());
    }

    function _withdrawMorpho(uint256 amount_, bool catchExceptions_) private returns (uint256 withdrawn) {
        MorphoMarketParamsCyvbEthV1 memory params = MORPHO.idToMarketParams(MORPHO_MARKET_ID);

        if (catchExceptions_) {
            try MORPHO.accrueInterest(params) {} catch {
                return 0;
            }
        } else {
            MORPHO.accrueInterest(params);
        }

        (uint256 shares,,) = MORPHO.position(MORPHO_MARKET_ID, address(this));
        if (shares == 0) return 0;

        uint256 assetsMax =
            MorphoVbEthAccounting_v1.currentSupplyAssets(MORPHO, MORPHO_MARKET_ID, address(this));
        if (assetsMax == 0) return 0;

        uint256 assets;
        uint256 sharesToBurn;
        if (amount_ == 0 || amount_ >= assetsMax) {
            sharesToBurn = shares;
        } else {
            assets = amount_;
            if (catchExceptions_) {
                uint256 liquid = IERC20FxMintCyvbETHV9(VBETH).balanceOf(address(MORPHO));
                if (assets > liquid) assets = liquid;
                if (assets == 0) return 0;
            }
        }

        if (catchExceptions_) {
            try MORPHO.withdraw(params, assets, sharesToBurn, address(this), address(this)) returns (
                uint256 assetsWithdrawn,
                uint256
            ) {
                withdrawn = assetsWithdrawn;
            } catch {
                return 0;
            }
        } else {
            (withdrawn,) = MORPHO.withdraw(params, assets, sharesToBurn, address(this), address(this));
        }

        if (withdrawn != 0) emit MorphoWithdrawn(VERSION, withdrawn);
    }

    function _fullUnwind(uint256 position_) private {
        (, uint256 rawDebts) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position_);
        // type(int256).min is f(x)'s explicit "all collateral" sentinel; repay + withdraw-all in one operate()
        _repayAndWithdraw(position_, rawDebts, type(int256).min, 0, block.timestamp);

        uint256 residualWeEth = IERC20FxMintCyvbETHV9(WEETH).balanceOf(address(this));
        if (residualWeEth != 0) _swap(WEETH, VBETH, residualWeEth, 0, block.timestamp);

        uint256 nestedShares = IERC4626FxMintCyvbETHV9(CYVBUSDC).balanceOf(address(this));
        if (nestedShares != 0) {
            IERC4626FxMintCyvbETHV9(CYVBUSDC).redeem(
                nestedShares,
                address(this),
                address(this)
            );
        }

        uint256 residualFxUsd = IERC20FxMintCyvbETHV9(FXUSD).balanceOf(address(this));
        if (residualFxUsd != 0) {
            _swap(FXUSD, VB_USDC, residualFxUsd, 0, block.timestamp);
        }

        uint256 residualStable = IERC20FxMintCyvbETHV9(VB_USDC).balanceOf(address(this));
        if (residualStable != 0) {
            _swap(VB_USDC, VBETH, residualStable, 0, block.timestamp);
        }
    }

    function _withdrawCollateral(uint256 position_, uint256 grossAmount_) private {
        uint256 beforeWeEth = IERC20FxMintCyvbETHV9(WEETH).balanceOf(address(this));
        IFxPoolManagerCyvbETHV9(POOL_MANAGER).operate(
            FX_POOL,
            position_,
            -_toInt(grossAmount_),
            0
        );
        uint256 received = IERC20FxMintCyvbETHV9(WEETH).balanceOf(address(this)) - beforeWeEth;
        if (received != 0) _swap(WEETH, VBETH, received, 0, block.timestamp);
    }

    function _safeCollateralOnlyNetWithdrawal(uint256 position_) private view returns (uint256) {
        (uint256 rawColls, uint256 rawDebts) = IFxLongPoolCyvbETHV9(FX_POOL).getPosition(position_);
        if (rawColls == 0 || rawDebts == 0) return _maxNetCollateralWithdrawal(rawColls);

        (uint256 anchorPrice,,) =
            IFxPriceOracleCyvbETHV9(IFxLongPoolCyvbETHV9(FX_POOL).priceOracle()).getPrice();

        uint16 maxLtvBps = INSTANT_WITHDRAW_MAX_LTV_BPS;

        // Minimum raw collateral that must remain so existing debt is <= maxLtv.
        // ceil(rawDebt * 1e18 * BPS / (anchorPrice * maxLtvBps)).
        uint256 numerator = rawDebts * WAD * BPS;
        uint256 denominator = anchorPrice * uint256(maxLtvBps);
        uint256 minimumRawCollateral = _ceilDiv(numerator, denominator);

        if (minimumRawCollateral >= rawColls) return 0;

        uint256 safeRawRemoval = rawColls - minimumRawCollateral;
        uint256 scale = IFxPoolManagerCyvbETHV9(POOL_MANAGER).getTokenScalingFactor(WEETH);
        uint256 safeGrossToken = (safeRawRemoval * WAD) / scale;

        (, uint256 withdrawFee,,) = _feeRatios();
        if (withdrawFee >= FEE_PRECISION) return 0;
        return (safeGrossToken * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    }

    function _maxNetCollateralWithdrawal(uint256 rawColls_) private view returns (uint256) {
        uint256 scale = IFxPoolManagerCyvbETHV9(POOL_MANAGER).getTokenScalingFactor(WEETH);
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
            IFxPriceOracleCyvbETHV9(IFxLongPoolCyvbETHV9(FX_POOL).priceOracle()).getPrice();
        uint256 collateralUsd = (rawColls_ * anchorPrice) / WAD;
        return (collateralUsd * targetBps_) / BPS;
    }

    function _desiredDebtCeil(uint256 rawColls_, uint16 targetBps_) private view returns (uint256) {
        if (targetBps_ > BPS) revert InvalidTargetLtv();
        (uint256 anchorPrice,,) =
            IFxPriceOracleCyvbETHV9(IFxLongPoolCyvbETHV9(FX_POOL).priceOracle()).getPrice();

        // Round upward because the live f(x) pool enforces a 50% minimum debt ratio
        // and the default cyvbETH target is exactly that boundary.
        uint256 collateralUsd = _ceilDiv(rawColls_ * anchorPrice, WAD);
        return _ceilDiv(collateralUsd * targetBps_, BPS);
    }

    function _validateBorrowTarget(uint16 targetBps_) private view {
        uint256 targetWad = _bpsToWad(targetBps_);
        (uint256 minDebtRatio, uint256 maxDebtRatio) =
            IFxLongPoolCyvbETHV9(FX_POOL).getDebtRatioRange();

        if (targetWad < minDebtRatio || targetWad > maxDebtRatio) {
            revert InvalidTargetLtv();
        }
    }

    function _depositStable(uint256 amount_, uint256 minShares_) private returns (uint256 shares) {
        if (amount_ == 0) return 0;
        _forceApprove(VB_USDC, CYVBUSDC, amount_);
        shares = IERC4626FxMintCyvbETHV9(CYVBUSDC).deposit(amount_, address(this));
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

        uint256 beforeOut = IERC20FxMintCyvbETHV9(tokenOut_).balanceOf(address(this));

        _forceApprove(tokenIn_, ROUTER, amountIn_);
        amountOut = ICurveYieldRouterCyvbETHV9(ROUTER).swapExactInput(
            tokenIn_,
            tokenOut_,
            amountIn_,
            minOut_,
            address(this),
            deadline_
        );
        _forceApprove(tokenIn_, ROUTER, 0);

        uint256 delta = IERC20FxMintCyvbETHV9(tokenOut_).balanceOf(address(this)) - beforeOut;
        if (delta != amountOut) revert SwapOutputMismatch();
    }

    function _feeRatios()
        private
        view
        returns (uint256 supplyFee, uint256 withdrawFee, uint256 borrowFee, uint256 repayFee)
    {
        return IFxPoolConfigurationCyvbETHV9(
            IFxLongPoolCyvbETHV9(FX_POOL).configuration()
        ).getPoolFeeRatio(FX_POOL, address(this));
    }

    /// @notice The active LTV policy (this fuse version's immutables).
    function getLtvPolicy() public view returns (CyvbEthLtvPolicy memory) {
        return CyvbEthLtvPolicy(TARGET_LTV_BPS, HIGH_TRIGGER_BPS, HIGH_RESET_BPS, LOW_TRIGGER_BPS, LOW_RESET_BPS, EARN_BPS);
    }

    /// @notice The vault's f(x) position (official FxMintStorageLib slot; 0 = none). Only meaningful in vault context.
    function _positionId() private view returns (uint256) {
        return CyvbEthFxPositionStorage.ids().positionIds[FX_POOL];
    }

    function _validatePolicy(CyvbEthLtvPolicy memory p_) private pure {
        if (
            p_.targetLtvBps < MIN_TARGET_LTV_BPS || p_.targetLtvBps > MAX_TARGET_LTV_BPS ||
            p_.highTriggerBps < MIN_HIGH_TRIGGER_BPS || p_.highTriggerBps > MAX_HIGH_TRIGGER_BPS ||
            p_.highResetBps < MIN_HIGH_RESET_BPS || p_.highResetBps > MAX_HIGH_RESET_BPS ||
            p_.lowTriggerBps < MIN_LOW_TRIGGER_BPS || p_.lowTriggerBps > MAX_LOW_TRIGGER_BPS ||
            p_.lowResetBps < MIN_LOW_RESET_BPS || p_.lowResetBps > MAX_LOW_RESET_BPS ||
            p_.earnBps > BPS
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
        if (ICurveYieldRouterCyvbETHV9(ROUTER).routeFor(tokenIn_, tokenOut_).length == 0) {
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
            abi.encodeWithSelector(IERC20FxMintCyvbETHV9.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, approveData)) {
            _callOptionalReturn(
                token_,
                abi.encodeWithSelector(IERC20FxMintCyvbETHV9.approve.selector, spender_, 0)
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
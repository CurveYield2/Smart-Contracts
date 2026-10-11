// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

interface ICurveYieldCustodyRouter {
    function twapMinimumOut(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 minimumNetAmountOut);
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 netAmountOut);
}

interface ICurveYieldCustodyRewardsManager {
    function updateBalance() external;
}

interface ICurveYieldCustodyOracle {
    function price() external view returns (uint256);
}

/**
 * @title CurveYield System Component
 * @notice CurveYield is a decentralized NGO building optimized DeFi systems for the good of all.
 *
 * @dev CurveYield integrates specialized AMM infrastructure, tokenized yield strategies, credit
 * markets, and protocol-owned liquidity into a unified, capital-efficient liquidity stack governed
 * by an open, international DAO community.
 *
 * Protocol operations are enhanced by cross-chain bridging and messaging, MEV capture systems,
 * off-chain to on-chain automation, and peer-to-peer data networks.
 *
 * This contract is one component of the CurveYield system.
 *
 * CurveYield uses proven DeFi primitives where possible and adds targeted coordination and
 * capital-efficiency-enhancing contracts where needed. Users and integrators must review
 * CurveYield documentation before use.
 *
 * Learn more:
 * Documentation: https://docs.curveyield.com
 * dApp: https://curveyield.online
 * GitHub: https://github.com/curveyield
 *
 * Decentralized links may have limited or delayed availability during periods of high network activity:
 * https://curveyield.eth.limo
 * https://curveyield.dao
 *
 * Note: curveyield.dao may require a Brave Browser or an Unstoppable Domains browser plugin to use.
 */
contract CurveYieldProfitCustody is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MorphoBalancesLib for IMorpho;

    struct FlashPlan {
        uint8 mode;
        uint256 repayKat;
        uint256 withdrawAvkat;
        uint256 sellAvkat;
        uint256 borrowShares;
    }

    address public constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    address public constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address public constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    bytes32 public constant MORPHO_MARKET_ID =
        0x80e60fe453223b0f84a567724f88190bef708420d24397157067d424429783e9;
    uint16 public constant TARGET_LTV_BPS = 7_500;
    uint16 public constant MAX_REVENUE_SHARE_BPS = 3_500;
    uint16 public constant MIN_REWARD_MANAGER_BPS = 1_000;
    uint16 public constant MAX_REWARD_MANAGER_BPS = 3_000;
    uint16 public constant MIN_FEE_RECIPIENT_BPS = 500;
    uint16 public constant MAX_FEE_RECIPIENT_BPS = 2_000;
    uint256 public constant FULL_UNWIND_DELAY = 15 days;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint8 private constant MAX_LOOP_COUNT = 8;
    uint8 private constant MAX_SEARCH_ITERATIONS = 32;
    uint8 private constant MAX_SEARCH_EXPANSIONS = 8;
    uint256 private constant SEARCH_RELATIVE_DIVISOR = 1e9;
    uint8 private constant FLASH_DECREASE = 1;
    uint8 private constant FLASH_FULL = 2;

    uint16 public revenueShareBps = 3_000;
    uint16 public rewardManagerDistributionBps = 1_600;
    uint16 public feeRecipientDistributionBps = 900;
    address public immutable ROUTER;
    address public immutable REWARDS_CLAIM_MANAGER;
    address public feeRecipient;
    address public queuedRecipient;
    uint64 public queuedExecuteAfter;
    bytes32 private _activeFlashHash;

    mapping(address guardian => bool enabled) public isGuardian;

    error NotOperator(address caller);
    error InvalidAddress(address account);
    error InvalidRevenueShare(uint16 value);
    error InvalidDistribution(uint16 rewardManagerBps, uint16 feeRecipientBps);
    error FullUnwindAlreadyQueued(address recipient, uint256 executeAfter);
    error FullUnwindNotQueued();
    error FullUnwindDelayActive(uint256 executeAfter);
    error InvalidFlashCallback();
    error RequiredOutputUnavailable(uint256 required, uint256 available);
    error InvalidPosition();

    event GuardianUpdated(address indexed guardian, bool enabled);
    event RevenueShareUpdated(uint16 value);
    event WindupDistributionUpdated(uint16 rewardManagerBps, uint16 feeRecipientBps);
    event FeeRecipientUpdated(address indexed recipient);
    event FullUnwindScheduled(address indexed recipient, uint256 executeAfter);
    event FullUnwindCancelled(address indexed caller);
    event FullUnwindExecuted(address indexed recipient, uint256 avkatAmount, uint256 katAmount);
    event LoopExecuted(uint256 borrowedKat, uint256 receivedAvkat, uint256 rewardManagerAmount, uint256 feeAmount);
    event LtvBalanced(uint256 collateralAvkat, uint256 debtKat, uint256 ltvBps);

    modifier onlyOperator() {
        if (msg.sender != owner() && !isGuardian[msg.sender]) revert NotOperator(msg.sender);
        _;
    }

    constructor(
        address initialOwner_,
        address feeRecipient_,
        address router_,
        address rewardsClaimManager_,
        address[] memory initialGuardians_
    ) Ownable(initialOwner_) {
        if (
            initialOwner_ == address(0) || feeRecipient_ == address(0) || router_ == address(0) ||
            rewardsClaimManager_ == address(0)
        ) revert InvalidAddress(address(0));
        feeRecipient = feeRecipient_;
        ROUTER = router_;
        REWARDS_CLAIM_MANAGER = rewardsClaimManager_;
        for (uint256 i; i < initialGuardians_.length; ++i) {
            _setGuardian(initialGuardians_[i], true);
        }
    }

    function setGuardian(address guardian_, bool enabled_) external onlyOwner {
        _setGuardian(guardian_, enabled_);
    }

    function _setGuardian(address guardian_, bool enabled_) private {
        if (guardian_ == address(0)) revert InvalidAddress(guardian_);
        isGuardian[guardian_] = enabled_;
        emit GuardianUpdated(guardian_, enabled_);
    }

    function setRevenueShareBps(uint16 value_) external onlyOwner {
        if (value_ > MAX_REVENUE_SHARE_BPS) revert InvalidRevenueShare(value_);
        revenueShareBps = value_;
        emit RevenueShareUpdated(value_);
    }

    function setWindupDistributionBps(uint16 rewardManagerBps_, uint16 feeRecipientBps_) external onlyOwner {
        if (
            rewardManagerBps_ < MIN_REWARD_MANAGER_BPS || rewardManagerBps_ > MAX_REWARD_MANAGER_BPS ||
            feeRecipientBps_ < MIN_FEE_RECIPIENT_BPS || feeRecipientBps_ > MAX_FEE_RECIPIENT_BPS
        ) revert InvalidDistribution(rewardManagerBps_, feeRecipientBps_);
        rewardManagerDistributionBps = rewardManagerBps_;
        feeRecipientDistributionBps = feeRecipientBps_;
        emit WindupDistributionUpdated(rewardManagerBps_, feeRecipientBps_);
    }

    function setFeeRecipient(address recipient_) external onlyOwner {
        if (recipient_ == address(0) || recipient_ == address(this)) revert InvalidAddress(recipient_);
        feeRecipient = recipient_;
        emit FeeRecipientUpdated(recipient_);
    }

    function deployAll() external onlyOperator nonReentrant {
        _supplyIdleAvkat();
        _windUp();
        _emitBalance();
    }

    function balanceLtv() external onlyOperator nonReentrant {
        _supplyIdleAvkat();
        (uint256 collateral, uint256 debt, uint256 collateralValue, uint256 ltv) = positionSnapshot();
        if (collateral == 0) return;
        if (ltv < TARGET_LTV_BPS) _windUp();
        else if (ltv > TARGET_LTV_BPS && debt != 0) _decreaseToTarget(collateral, debt, collateralValue);
        _emitBalance();
    }

    function scheduleFullUnwind(address recipient_) external onlyOwner {
        if (recipient_ == address(0) || recipient_ == address(this)) revert InvalidAddress(recipient_);
        if (queuedRecipient != address(0)) {
            revert FullUnwindAlreadyQueued(queuedRecipient, queuedExecuteAfter);
        }
        queuedRecipient = recipient_;
        queuedExecuteAfter = uint64(block.timestamp + FULL_UNWIND_DELAY);
        emit FullUnwindScheduled(recipient_, queuedExecuteAfter);
    }

    function cancelFullUnwind() external onlyOperator {
        if (queuedRecipient == address(0)) revert FullUnwindNotQueued();
        delete queuedRecipient;
        delete queuedExecuteAfter;
        emit FullUnwindCancelled(msg.sender);
    }

    function executeFullUnwind() external onlyOwner nonReentrant {
        address recipient = queuedRecipient;
        uint256 executeAfter = queuedExecuteAfter;
        if (recipient == address(0)) revert FullUnwindNotQueued();
        if (block.timestamp < executeAfter) revert FullUnwindDelayActive(executeAfter);
        delete queuedRecipient;
        delete queuedExecuteAfter;
        _fullUnwind();
        uint256 avkatAmount = IERC20(AVKAT).balanceOf(address(this));
        uint256 katAmount = IERC20(KAT).balanceOf(address(this));
        if (avkatAmount != 0) IERC20(AVKAT).safeTransfer(recipient, avkatAmount);
        if (katAmount != 0) IERC20(KAT).safeTransfer(recipient, katAmount);
        emit FullUnwindExecuted(recipient, avkatAmount, katAmount);
    }

    function positionSnapshot()
        public view returns (uint256 collateralAvkat_, uint256 debtKat_, uint256 collateralValueKat_, uint256 ltvBps_)
    {
        IMorpho morpho = IMorpho(MORPHO);
        MarketParams memory params = morpho.idToMarketParams(Id.wrap(MORPHO_MARKET_ID));
        collateralAvkat_ = morpho.position(Id.wrap(MORPHO_MARKET_ID), address(this)).collateral;
        debtKat_ = morpho.expectedBorrowAssets(params, address(this));
        collateralValueKat_ = Math.mulDiv(
            collateralAvkat_, ICurveYieldCustodyOracle(params.oracle).price(), ORACLE_PRICE_SCALE
        );
        ltvBps_ = collateralValueKat_ == 0 ? 0 : debtKat_ * 10_000 / collateralValueKat_;
    }

    function onMorphoFlashLoan(uint256 assets_, bytes calldata data_) external {
        if (msg.sender != MORPHO || _activeFlashHash == bytes32(0) || keccak256(data_) != _activeFlashHash) {
            revert InvalidFlashCallback();
        }
        FlashPlan memory plan = abi.decode(data_, (FlashPlan));
        if (assets_ != plan.repayKat || (plan.mode != FLASH_DECREASE && plan.mode != FLASH_FULL)) {
            revert InvalidFlashCallback();
        }
        IMorpho morpho = IMorpho(MORPHO);
        MarketParams memory params = morpho.idToMarketParams(Id.wrap(MORPHO_MARKET_ID));
        IERC20(KAT).forceApprove(MORPHO, assets_);
        if (plan.mode == FLASH_FULL) {
            (uint256 repaid,) = morpho.repay(params, 0, plan.borrowShares, address(this), bytes(""));
            if (repaid != assets_) revert InvalidPosition();
        } else {
            (uint256 repaid,) = morpho.repay(params, assets_, 0, address(this), bytes(""));
            if (repaid != assets_) revert InvalidPosition();
        }
        IERC20(KAT).forceApprove(MORPHO, 0);
        morpho.withdrawCollateral(params, plan.withdrawAvkat, address(this), address(this));
        if (plan.sellAvkat != 0) _swap(AVKAT, KAT, plan.sellAvkat, assets_);
        if (IERC20(KAT).balanceOf(address(this)) < assets_) revert RequiredOutputUnavailable(
            assets_, IERC20(KAT).balanceOf(address(this))
        );
        IERC20(KAT).forceApprove(MORPHO, assets_);
    }

    function _marketParams() private view returns (MarketParams memory) {
        return IMorpho(MORPHO).idToMarketParams(Id.wrap(MORPHO_MARKET_ID));
    }

    function _supplyIdleAvkat() private {
        uint256 amount = IERC20(AVKAT).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(AVKAT).forceApprove(MORPHO, amount);
        IMorpho(MORPHO).supplyCollateral(_marketParams(), amount, address(this), bytes(""));
        IERC20(AVKAT).forceApprove(MORPHO, 0);
    }

    function _windUp() private {
        IMorpho morpho = IMorpho(MORPHO);
        MarketParams memory params = _marketParams();
        for (uint256 i; i < MAX_LOOP_COUNT; ++i) {
            (, uint256 debt, uint256 collateralValue,) = positionSnapshot();
            uint256 targetDebt = collateralValue * TARGET_LTV_BPS / 10_000;
            if (targetDebt <= debt + 1) break;
            uint256 borrowAmount = targetDebt - debt;
            morpho.borrow(params, borrowAmount, 0, address(this), address(this));
            uint256 received = _swap(KAT, AVKAT, borrowAmount, 0);
            uint256 rewardAmount = received * rewardManagerDistributionBps / 10_000;
            uint256 feeAmount = received * feeRecipientDistributionBps / 10_000;
            if (rewardAmount != 0) {
                IERC20(AVKAT).safeTransfer(REWARDS_CLAIM_MANAGER, rewardAmount);
                ICurveYieldCustodyRewardsManager(REWARDS_CLAIM_MANAGER).updateBalance();
            }
            if (feeAmount != 0) IERC20(AVKAT).safeTransfer(feeRecipient, feeAmount);
            _supplyIdleAvkat();
            emit LoopExecuted(borrowAmount, received, rewardAmount, feeAmount);
        }
    }

    function _decreaseToTarget(uint256 collateral_, uint256 debt_, uint256 collateralValue_) private {
        uint256 sell;
        uint256 repay;
        for (uint256 i; i < MAX_SEARCH_ITERATIONS; ++i) {
            uint256 soldValue = Math.mulDiv(sell, collateralValue_, collateral_);
            uint256 remainingValue = collateralValue_ - soldValue;
            uint256 targetDebt = remainingValue * TARGET_LTV_BPS / 10_000;
            repay = debt_ > targetDebt ? debt_ - targetDebt : 0;
            uint256 nextSell = _requiredInput(repay, collateral_);
            if (nextSell <= sell + 1 && sell <= nextSell + 1) {
                sell = nextSell;
                break;
            }
            sell = nextSell;
        }
        uint256 finalSoldValue = Math.mulDiv(sell, collateralValue_, collateral_);
        uint256 finalTargetDebt = (collateralValue_ - finalSoldValue) * TARGET_LTV_BPS / 10_000;
        repay = debt_ - finalTargetDebt;
        FlashPlan memory plan = FlashPlan(FLASH_DECREASE, repay, sell, sell, 0);
        _flash(plan);
    }

    function _fullUnwind() private {
        IMorpho morpho = IMorpho(MORPHO);
        (uint256 collateral, uint256 debt,,) = positionSnapshot();
        if (collateral == 0) return;
        if (debt == 0) {
            morpho.withdrawCollateral(_marketParams(), collateral, address(this), address(this));
            return;
        }
        uint256 sell = _requiredInput(debt, collateral);
        uint256 borrowShares = morpho.position(Id.wrap(MORPHO_MARKET_ID), address(this)).borrowShares;
        _flash(FlashPlan(FLASH_FULL, debt, collateral, sell, borrowShares));
    }

    function _flash(FlashPlan memory plan_) private {
        if (plan_.repayKat == 0 || _activeFlashHash != bytes32(0)) revert InvalidFlashCallback();
        bytes memory data = abi.encode(plan_);
        _activeFlashHash = keccak256(data);
        IMorpho(MORPHO).flashLoan(KAT, plan_.repayKat, data);
        delete _activeFlashHash;
        IERC20(KAT).forceApprove(MORPHO, 0);
    }

    function _requiredInput(uint256 requiredKat_, uint256 maximumAvkat_) private view returns (uint256 input_) {
        if (requiredKat_ == 0) return 0;
        ICurveYieldCustodyRouter router = ICurveYieldCustodyRouter(ROUTER);
        uint256 available = router.twapMinimumOut(AVKAT, KAT, maximumAvkat_);
        if (available < requiredKat_) revert RequiredOutputUnavailable(requiredKat_, available);
        uint256 low = 1;
        uint256 high = Math.mulDiv(maximumAvkat_, requiredKat_, available, Math.Rounding.Ceil);
        if (high == 0) high = 1;
        if (high > maximumAvkat_) high = maximumAvkat_;
        uint256 highOutput = router.twapMinimumOut(AVKAT, KAT, high);
        for (uint256 i; i < MAX_SEARCH_EXPANSIONS && highOutput < requiredKat_; ++i) {
            low = high + 1;
            uint256 expanded = high + high / 8 + 1;
            high = expanded < maximumAvkat_ ? expanded : maximumAvkat_;
            highOutput = router.twapMinimumOut(AVKAT, KAT, high);
        }
        if (highOutput < requiredKat_) revert RequiredOutputUnavailable(requiredKat_, highOutput);
        for (uint256 i; i < MAX_SEARCH_ITERATIONS && low < high; ++i) {
            uint256 tolerance = high / SEARCH_RELATIVE_DIVISOR;
            if (tolerance == 0) tolerance = 1;
            if (high - low <= tolerance) break;
            uint256 mid = low + (high - low) / 2;
            if (router.twapMinimumOut(AVKAT, KAT, mid) >= requiredKat_) high = mid;
            else low = mid + 1;
        }
        input_ = high;
        uint256 output = router.twapMinimumOut(AVKAT, KAT, input_);
        if (output < requiredKat_) revert RequiredOutputUnavailable(requiredKat_, output);
    }

    function _swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 requiredOut_)
        private returns (uint256 amountOut_)
    {
        ICurveYieldCustodyRouter router = ICurveYieldCustodyRouter(ROUTER);
        uint256 minimum = router.twapMinimumOut(tokenIn_, tokenOut_, amountIn_);
        if (requiredOut_ > minimum) minimum = requiredOut_;
        IERC20(tokenIn_).forceApprove(ROUTER, amountIn_);
        amountOut_ = router.swapExactInput(
            tokenIn_, tokenOut_, amountIn_, minimum, address(this), block.timestamp
        );
        IERC20(tokenIn_).forceApprove(ROUTER, 0);
        if (amountOut_ < minimum) revert RequiredOutputUnavailable(minimum, amountOut_);
    }

    function _emitBalance() private {
        (uint256 collateral, uint256 debt,, uint256 ltv) = positionSnapshot();
        emit LtvBalanced(collateral, debt, ltv);
    }
}

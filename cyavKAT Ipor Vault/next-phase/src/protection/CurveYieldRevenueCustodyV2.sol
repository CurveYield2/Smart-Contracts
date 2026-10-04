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
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";

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

interface ICurveYieldCustodyFarm {
    function totalValueAvkat() external view returns (uint256);
    function hasActivePositions() external view returns (bool);
    function deployProRata(uint256 amountAvkat) external;
    function coverPull(uint256 amountAvkat) external returns (uint256 paid);
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
/// @notice v2 of CurveYieldProfitCustody (0xe7D1…5ADf) plus the PPS backstop (PPS spec B5) and two allocations
/// (CUSTODY_FARM_SPEC): the Morpho loop, kept at `custody.loopTargetBps` of the custody's value, and the farm
/// (CurveYieldCustodyFarm) for everything else. `deployAll` fills the loop up to target and spreads the rest over the
/// farm's active positions pro rata. `cover` pays avKAT to the cyavKAT vault (fixed at construction) in the same
/// transaction: idle avKAT, then the farm, then a proportional unwind of the loop. Only coverers the owner enables (the
/// vault executor) may call it; the whole custody balance is available.
contract CurveYieldRevenueCustodyV2 is Ownable2Step, ReentrancyGuard, CurveYieldGateConfig {
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
    uint256 public constant FULL_UNWIND_DELAY = 15 days;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint8 private constant MAX_LOOP_COUNT = 8;
    uint8 private constant MAX_SEARCH_ITERATIONS = 32;
    uint8 private constant MAX_SEARCH_EXPANSIONS = 8;
    uint256 private constant SEARCH_RELATIVE_DIVISOR = 1e9;
    uint8 private constant FLASH_DECREASE = 1;
    uint8 private constant FLASH_FULL = 2;

    /// @notice Wired in the gate (`CurveYieldAddrKeys.SWAP_ROUTER`, GATE_CONFIG_SPEC §10).

    function ROUTER() public view returns (address) {

        return _addr(CurveYieldAddrKeys.SWAP_ROUTER);

    }
    /// @notice Wired in the gate (`CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER`, GATE_CONFIG_SPEC §10).
    function REWARDS_CLAIM_MANAGER() public view returns (address) {
        return _addr(CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER);
    }
    address public immutable VAULT; // the only destination of cover()
    mapping(address coverer => bool enabled) public isCoverer;
    address public feeRecipient;
    address public queuedRecipient;
    uint64 public queuedExecuteAfter;
    bytes32 private _activeFlashHash;

    mapping(address guardian => bool enabled) public isGuardian;
    address public farm;

    error NotOperator(address caller);
    error InvalidAddress(address account);
    error FullUnwindAlreadyQueued(address recipient, uint256 executeAfter);
    error FullUnwindNotQueued();
    error FullUnwindDelayActive(uint256 executeAfter);
    error InvalidFlashCallback();
    error RequiredOutputUnavailable(uint256 required, uint256 available);
    error InvalidPosition();

    event GuardianUpdated(address indexed guardian, bool enabled);
    event FeeRecipientUpdated(address indexed recipient);
    event FullUnwindScheduled(address indexed recipient, uint256 executeAfter);
    event FullUnwindCancelled(address indexed caller);
    event FullUnwindExecuted(address indexed recipient, uint256 avkatAmount, uint256 katAmount);
    event LoopExecuted(uint256 borrowedKat, uint256 receivedAvkat, uint256 rewardManagerAmount, uint256 feeAmount);
    event LtvBalanced(uint256 collateralAvkat, uint256 debtKat, uint256 ltvBps);
    event CovererUpdated(address indexed coverer, bool enabled);
    event LossCovered(address indexed coverer, uint256 requestedAvkat, uint256 paidAvkat);
    event FarmUpdated(address indexed farm);
    event Allocated(uint256 toLoop, uint256 toFarm, uint256 loopEquityAvkat, uint256 totalValueAvkat);

    modifier onlyOperator() {
        if (msg.sender != owner() && !isGuardian[msg.sender]) revert NotOperator(msg.sender);
        _;
    }

    constructor(
        address initialOwner_,
        address feeRecipient_,
        address vault_,
        address configGate_,
        address[] memory initialGuardians_
    ) Ownable(initialOwner_) CurveYieldGateConfig(configGate_) {
        if (
            initialOwner_ == address(0) || feeRecipient_ == address(0) || vault_ == address(0)
        ) revert InvalidAddress(address(0));
        VAULT = vault_;
        feeRecipient = feeRecipient_;
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

    function setFarm(address farm_) external onlyOwner {
        farm = farm_;
        emit FarmUpdated(farm_);
    }

    /// @notice Idle avKAT to the farm for a manual deployment (operators).
    function sendToFarm(uint256 amountAvkat_) external onlyOperator nonReentrant {
        if (farm == address(0)) revert InvalidAddress(address(0));
        IERC20(AVKAT).safeTransfer(farm, amountAvkat_);
    }

    function setCoverer(address coverer_, bool enabled_) external onlyOwner {
        if (coverer_ == address(0)) revert InvalidAddress(coverer_);
        isCoverer[coverer_] = enabled_;
        emit CovererUpdated(coverer_, enabled_);
    }

    /// @notice PPS backstop: pays up to `lossAvkat_` avKAT to the vault now; returns what was paid (less only when the
    /// whole custody is worth less). Idle avKAT first, then the farm's holdings, then a proportional unwind of the loop.
    function cover(uint256 lossAvkat_) external nonReentrant returns (uint256 paid_) {
        if (!isCoverer[msg.sender]) revert NotOperator(msg.sender);
        if (lossAvkat_ == 0) return 0;
        uint256 idle = IERC20(AVKAT).balanceOf(address(this));
        if (idle < lossAvkat_ && farm != address(0)) {
            try ICurveYieldCustodyFarm(farm).coverPull(lossAvkat_ - idle) {} catch {}
            idle = IERC20(AVKAT).balanceOf(address(this));
        }
        if (idle < lossAvkat_) _freeAvkat(lossAvkat_ - idle);
        idle = IERC20(AVKAT).balanceOf(address(this));
        paid_ = idle < lossAvkat_ ? idle : lossAvkat_;
        if (paid_ != 0) IERC20(AVKAT).safeTransfer(VAULT, paid_);
        emit LossCovered(msg.sender, lossAvkat_, paid_);
    }

    /// @dev Unwinds the fraction f of the position that frees about `needed_` avKAT: repay f·D (flash), withdraw f·C,
    /// sell just enough of it for the flash. With the TWAP floor linear in size, freed(f) = f · (C - sell(D)).
    function _freeAvkat(uint256 needed_) private {
        (uint256 collateral, uint256 debt,,) = positionSnapshot();
        if (collateral == 0) return;
        if (debt == 0) {
            uint256 amount = needed_ < collateral ? needed_ : collateral;
            IMorpho(MORPHO).withdrawCollateral(_marketParams(), amount, address(this), address(this));
            return;
        }
        uint256 sellAll = _requiredInput(debt, collateral);
        if (sellAll >= collateral) return; // underwater at the TWAP floor: nothing freeable
        uint256 equity = collateral - sellAll;
        if (needed_ >= equity) {
            _fullUnwind();
            return;
        }
        // f = needed / equity, rounded up with a 0.1% margin for rounding in the search
        uint256 fWad = Math.mulDiv(needed_, 1.001e18, equity, Math.Rounding.Ceil);
        if (fWad >= 1e18) {
            _fullUnwind();
            return;
        }
        uint256 repay = Math.mulDiv(debt, fWad, 1e18, Math.Rounding.Ceil);
        uint256 withdraw = Math.mulDiv(collateral, fWad, 1e18);
        uint256 sell = _requiredInput(repay, withdraw);
        _flash(FlashPlan(FLASH_DECREASE, repay, withdraw, sell, 0));
        uint256 katLeft = IERC20(KAT).balanceOf(address(this));
        if (katLeft != 0 && _quotable(katLeft)) _swap(KAT, AVKAT, katLeft, 0);
    }

    /// @dev Whether the router quotes a non-zero TWAP floor for selling `katAmount_` KAT (dust is left as KAT).
    function _quotable(uint256 katAmount_) private view returns (bool) {
        try ICurveYieldCustodyRouter(ROUTER()).twapMinimumOut(KAT, AVKAT, katAmount_) returns (uint256 out) {
            return out != 0;
        } catch {
            return false;
        }
    }

    /// @notice Cut of the vault's instant-withdraw fee this custody receives (bps), from the gate (FEE class).
    function revenueShareBps() public view returns (uint16) {
        return uint16(_config1(K.CUSTODY_REVENUE_SHARE_BPS));
    }

    /// @notice Wind-up distribution: rewards-manager and fee-recipient shares of each loop gain (bps), from the gate.
    /// @notice The loop's target share of the custody's total value (bps), from the gate (30-80%).
    function loopTargetBps() public view returns (uint256) {
        return _config1(K.CUSTODY_LOOP_TARGET_BPS);
    }

    /// @notice Loop equity in avKAT: collateral minus the debt at the market oracle price.
    function loopEquityAvkat() public view returns (uint256) {
        (uint256 collateral, uint256 debt,,) = positionSnapshot();
        if (debt == 0) return collateral;
        uint256 debtAvkat = Math.mulDiv(debt, ORACLE_PRICE_SCALE, ICurveYieldCustodyOracle(_marketParams().oracle).price());
        return collateral > debtAvkat ? collateral - debtAvkat : 0;
    }

    function windupDistributionBps() public view returns (uint256 rewardManagerBps_, uint256 feeRecipientBps_) {
        bytes32[] memory k = new bytes32[](2);
        (k[0], k[1]) = (K.CUSTODY_REWARD_MANAGER_BPS, K.CUSTODY_FEE_RECIPIENT_BPS);
        uint256[] memory v = _config(k);
        return (v[0], v[1]);
    }

    function setFeeRecipient(address recipient_) external onlyOwner {
        if (recipient_ == address(0) || recipient_ == address(this)) revert InvalidAddress(recipient_);
        feeRecipient = recipient_;
        emit FeeRecipientUpdated(recipient_);
    }

    /// @notice Idle avKAT: the loop is filled up to its target share of the custody's value; the rest goes to the farm's
    /// active positions pro rata (it stays idle while the farm has none). Then the loop winds up to its target LTV.
    function deployAll() external onlyOperator nonReentrant {
        uint256 idle = IERC20(AVKAT).balanceOf(address(this));
        uint256 toFarm;
        if (idle != 0 && farm != address(0)) {
            ICurveYieldCustodyFarm f = ICurveYieldCustodyFarm(farm);
            uint256 equity = loopEquityAvkat();
            uint256 total = idle + equity + f.totalValueAvkat();
            uint256 target = Math.mulDiv(total, loopTargetBps(), 10_000);
            uint256 toLoop = equity >= target ? 0 : Math.min(idle, target - equity);
            if (idle > toLoop && f.hasActivePositions()) {
                toFarm = idle - toLoop;
                IERC20(AVKAT).safeTransfer(farm, toFarm);
                f.deployProRata(toFarm);
            }
            emit Allocated(toLoop, toFarm, equity, total);
            _supplyAvkat(toLoop);
        } else {
            _supplyAvkat(idle);
        }
        _windUp();
        _emitBalance();
    }

    /// @notice Re-levers or de-levers the loop to its target LTV. Idle avKAT is left for deployAll (allocation target).
    function balanceLtv() external onlyOperator nonReentrant {
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
        _supplyAvkat(IERC20(AVKAT).balanceOf(address(this)));
    }

    function _supplyAvkat(uint256 amount) private {
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
            (uint256 rmBps, uint256 frBps) = windupDistributionBps();
            uint256 rewardAmount = received * rmBps / 10_000;
            uint256 feeAmount = received * frBps / 10_000;
            if (rewardAmount != 0) {
                IERC20(AVKAT).safeTransfer(REWARDS_CLAIM_MANAGER(), rewardAmount);
                ICurveYieldCustodyRewardsManager(REWARDS_CLAIM_MANAGER()).updateBalance();
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
        ICurveYieldCustodyRouter router = ICurveYieldCustodyRouter(ROUTER());
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
        ICurveYieldCustodyRouter router = ICurveYieldCustodyRouter(ROUTER());
        uint256 minimum = router.twapMinimumOut(tokenIn_, tokenOut_, amountIn_);
        if (requiredOut_ > minimum) minimum = requiredOut_;
        IERC20(tokenIn_).forceApprove(ROUTER(), amountIn_);
        amountOut_ = router.swapExactInput(
            tokenIn_, tokenOut_, amountIn_, minimum, address(this), block.timestamp
        );
        IERC20(tokenIn_).forceApprove(ROUTER(), 0);
        if (amountOut_ < minimum) revert RequiredOutputUnavailable(minimum, amountOut_);
    }

    function _emitBalance() private {
        (uint256 collateral, uint256 debt,, uint256 ltv) = positionSnapshot();
        emit LtvBalanced(collateral, debt, ltv);
    }
}

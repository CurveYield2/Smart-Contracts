// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";
import {CurveYieldSwapLib} from "../pol/CurveYieldSwapLib.sol";

interface ICurveYieldCustodyRouter {
    function protectedQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 expectedNet, uint256 minimumNet);
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 netAmountOut);
}

/// @notice Charm AlphaProVault (also the POL position-B vault).
interface ICurveYieldCustodyCharm {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);
    function deposit(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address to)
        external returns (uint256 shares, uint256 amount0, uint256 amount1);
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address to)
        external returns (uint256 amount0, uint256 amount1);
}

interface ICurveYieldCustodyMerkl {
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs)
        external;
}

interface ICurveYieldCustodyRewardsManager {
    function updateBalance() external;
}

/// @notice The live loop custody (CurveYieldProfitCustody 0xe7D1…5ADf); this contract is one of its guardians.
interface ICurveYieldLoopCustody {
    function deployAll() external;
    function positionSnapshot()
        external view returns (uint256 collateralAvkat, uint256 debtKat, uint256 collateralValueKat, uint256 ltvBps);
}

interface ICurveYieldCustodyVault {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function decimals() external view returns (uint8);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

interface ICurveYieldCustodyWithdrawManager {
    function armBurnOnlyFee() external;
}

/// @notice POL position B venues (POL_SPEC): our Charm Alpha Vault on the Sushi V3 cyavKAT/WETH pool, the CurveYield
/// DEX POL pool (the only avKAT <-> cyavKAT venue) and cyavKAT's withdraw manager (burn-only instant redemptions).
struct CyCustodyPolVenues {
    address alphaVault;
    address polPool;
    address balancerRouter;
    address permit2;
    address withdrawManager;
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
/// @notice Revenue custody v2: the layer on top of the live loop custody (CurveYieldProfitCustody 0xe7D1…5ADf, which
/// keeps the avKAT/KAT Morpho loop unchanged) for everything beyond the loop. Revenue lands here; it holds:
///   - the allocation: `deployAll` sends the loop's share (`custody.loopTargetBps` of the combined value) to the loop
///     custody and runs its `deployAll` (this contract is a guardian there), the rest goes to the farm;
///   - the farm: allowlisted Charm vaults, deployed pro rata by `deployAll` and by hand by operators;
///   - POL position B (POL_SPEC): our Charm Alpha Vault on the cyavKAT/WETH pool, funded from its reserved
///     avKAT budget (`reserveAvkatForPolBps`) and excluded from loop / farm / cover accounting;
///   - Merkl rewards of every Charm position, claimed here and split like a loop gain.
/// `cover` pays avKAT to the cyavKAT vault (fixed at construction) in the same transaction: idle avKAT, then the farm.
/// The loop custody has no instant exit (its unwind is owner-scheduled with a 15-day delay), so the loop is not part
/// of the cover. Every swap goes through the swap router v2 (protected minimum), except the avKAT <-> cyavKAT leg of
/// position B, which trades in the POL pool bounded by cyavKAT's deposit rate.
contract CurveYieldRevenueCustodyV2 is Ownable2Step, ReentrancyGuard, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    address public constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address public constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    uint256 public constant FULL_UNWIND_DELAY = 15 days;
    uint256 private constant BPS = 10_000;
    uint256 private constant PULL_MARGIN_BPS = 50; // farm cover: unwind 0.5% more than the shortfall

    address public immutable VAULT; // cyavKAT: the only destination of cover(), and position B's share token
    address public immutable WETH;
    address public immutable MERKL; // Merkl distributor
    address public immutable LOOP_CUSTODY; // the live loop custody (CurveYieldProfitCustody)

    mapping(address operator => bool enabled) public isOperator;
    mapping(address coverer => bool enabled) public isCoverer;
    address public feeRecipient;
    address public queuedRecipient;
    uint64 public queuedExecuteAfter;

    mapping(address vault => bool allowed) public isCharmVaultAllowed;
    mapping(address token => uint256 refs) public tokenRefs; // allowed-token reference count (vaults using it)
    address[] private _tokens;
    address[] private _charmVaults;

    CyCustodyPolVenues public polVenues;
    uint256 public polBudgetAvkat; // idle avKAT reserved for position B (not idle for the loop / farm / cover)

    error NotOperator(address caller);
    error InvalidAddress(address account);
    error FullUnwindAlreadyQueued(address recipient, uint256 executeAfter);
    error FullUnwindNotQueued();
    error FullUnwindDelayActive(uint256 executeAfter);
    error TokenNotAllowed(address token);
    error CharmVaultNotAllowed(address vault);
    error DeployLossTooHigh(uint256 valueAdded, uint256 avkatSpent);
    error InsufficientAvkat(uint256 requested, uint256 available);
    error InsufficientWrapperShares(uint256 requested, uint256 available);
    error WrapperRedeemBelowMinimum(uint256 received, uint256 minimum);
    error InvalidPolReserveBps(uint256 bps);

    event OperatorSet(address indexed operator, bool enabled);
    event CovererUpdated(address indexed coverer, bool enabled);
    event FeeRecipientUpdated(address indexed recipient);
    event FullUnwindScheduled(address indexed recipient, uint256 executeAfter);
    event FullUnwindCancelled(address indexed caller);
    event FullUnwindExecuted(address indexed recipient, uint256 avkatAmount, uint256 katAmount);
    event LossCovered(address indexed coverer, uint256 requestedAvkat, uint256 paidAvkat);
    event Allocated(uint256 toLoop, uint256 toFarm, uint256 loopEquityAvkat, uint256 totalValueAvkat);
    event CharmVaultAllowed(address indexed vault, bool allowed);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event CharmDeposited(address indexed vault, uint256 shares, uint256 amount0, uint256 amount1);
    event CharmWithdrawn(address indexed vault, uint256 shares, uint256 amount0, uint256 amount1);
    event FarmDeployed(uint256 avkatIn, uint256 valueAdded);
    event Harvested(uint256 avkatOut, uint256 toRewardsManager, uint256 toFeeRecipient);
    event StepSkipped(uint8 step, bytes reason);
    event PolVenuesUpdated(CyCustodyPolVenues venues);
    event PolFunded(address indexed from, uint256 avkat);
    event PolDeployed(uint256 avkatIn, uint256 cyavkatBought, uint256 wethBought, uint256 shares);
    event PolExited(uint256 shares, uint256 avkatOut, bool cyavkatSold, address receiver);
    event WrapperRevenueRedeemed(uint256 cyavkatShares, uint256 avkatReceived);
    event PolReserveBpsApplied(uint16 bps, uint256 totalAvkat, uint256 totalPolBudget);

    modifier onlyOperator() {
        if (msg.sender != owner() && !isOperator[msg.sender]) revert NotOperator(msg.sender);
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotOperator(msg.sender);
        _;
    }

    constructor(
        address initialOwner_,
        address feeRecipient_,
        address vault_,
        address weth_,
        address merkl_,
        address loopCustody_,
        address configGate_,
        address[] memory initialOperators_
    ) Ownable(initialOwner_) CurveYieldGateConfig(configGate_) {
        if (
            initialOwner_ == address(0) || feeRecipient_ == address(0) || vault_ == address(0) ||
            weth_ == address(0) || merkl_ == address(0) || loopCustody_ == address(0)
        ) revert InvalidAddress(address(0));
        (VAULT, WETH, MERKL, LOOP_CUSTODY) = (vault_, weth_, merkl_, loopCustody_);
        feeRecipient = feeRecipient_;
        _addTokenRef(AVKAT);
        _addTokenRef(KAT);
        for (uint256 i; i < initialOperators_.length; ++i) _setOperator(initialOperators_[i], true);
    }

    // ---------------------------------------------------------------- wiring and settings

    /// @notice Wired in the gate (`CurveYieldAddrKeys.SWAP_ROUTER`, GATE_CONFIG_SPEC §10).
    function ROUTER() public view returns (address) {
        return _addr(CurveYieldAddrKeys.SWAP_ROUTER);
    }

    /// @notice Wired in the gate (`CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER`, GATE_CONFIG_SPEC §10).
    function REWARDS_CLAIM_MANAGER() public view returns (address) {
        return _addr(CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER);
    }

    /// @notice Cut of the vault's instant-withdraw fee this custody receives (bps), from the gate (FEE class).
    function revenueShareBps() public view returns (uint16) {
        return uint16(_config1(K.CUSTODY_REVENUE_SHARE_BPS));
    }

    /// @notice The loop's target share of the custody's value (bps), from the gate (30-80%).
    function loopTargetBps() public view returns (uint256) {
        return _config1(K.CUSTODY_LOOP_TARGET_BPS);
    }

    /// @notice Wind-up distribution: rewards-manager and fee-recipient shares of each gain (bps), from the gate.
    function windupDistributionBps() public view returns (uint256 rewardManagerBps_, uint256 feeRecipientBps_) {
        bytes32[] memory k = new bytes32[](2);
        (k[0], k[1]) = (K.CUSTODY_REWARD_MANAGER_BPS, K.CUSTODY_FEE_RECIPIENT_BPS);
        uint256[] memory v = _config(k);
        return (v[0], v[1]);
    }

    function setOperator(address operator_, bool enabled_) external onlyOwner {
        _setOperator(operator_, enabled_);
    }

    function setCoverer(address coverer_, bool enabled_) external onlyOwner {
        if (coverer_ == address(0)) revert InvalidAddress(coverer_);
        isCoverer[coverer_] = enabled_;
        emit CovererUpdated(coverer_, enabled_);
    }

    function setFeeRecipient(address recipient_) external onlyOwner {
        if (recipient_ == address(0) || recipient_ == address(this)) revert InvalidAddress(recipient_);
        feeRecipient = recipient_;
        emit FeeRecipientUpdated(recipient_);
    }

    /// @notice Adds / removes a farm Charm vault (its two tokens become / stop being allowed swap tokens). A vault still
    /// holding custody shares cannot leave the list (its shares would drop out of the valuation).
    function setCharmVaultAllowed(address vault_, bool allowed_) external onlyOwner {
        if (vault_ == address(0) || vault_ == polVenues.alphaVault || isCharmVaultAllowed[vault_] == allowed_) {
            revert CharmVaultNotAllowed(vault_);
        }
        if (!allowed_ && IERC20(vault_).balanceOf(address(this)) != 0) revert CharmVaultNotAllowed(vault_);
        isCharmVaultAllowed[vault_] = allowed_;
        (address t0, address t1) = _pair(vault_);
        if (allowed_) {
            _addTokenRef(t0);
            _addTokenRef(t1);
            _charmVaults.push(vault_);
        } else {
            _removeTokenRef(t0);
            _removeTokenRef(t1);
            _removeAddress(_charmVaults, vault_);
        }
        emit CharmVaultAllowed(vault_, allowed_);
    }

    /// @notice Position B venues; the Alpha Vault must be the cyavKAT / WETH vault and never a farm vault.
    function setPolVenues(CyCustodyPolVenues calldata v_) external onlyOwner {
        if (v_.alphaVault == address(0) || v_.polPool == address(0) || v_.balancerRouter == address(0) ||
            v_.permit2 == address(0) || v_.withdrawManager == address(0) || isCharmVaultAllowed[v_.alphaVault]) {
            revert InvalidAddress(v_.alphaVault);
        }
        (address t0, address t1) = _pair(v_.alphaVault);
        if (!((t0 == VAULT && t1 == WETH) || (t0 == WETH && t1 == VAULT))) revert InvalidAddress(v_.alphaVault);
        polVenues = v_;
        emit PolVenuesUpdated(v_);
    }

    // ---------------------------------------------------------------- views

    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    function charmVaults() external view returns (address[] memory) {
        return _charmVaults;
    }

    /// @notice Idle avKAT available to the loop, the farm and cover (position B's budget excluded).
    function idleAvkat() public view returns (uint256) {
        uint256 balance = IERC20(AVKAT).balanceOf(address(this));
        return balance > polBudgetAvkat ? balance - polBudgetAvkat : 0;
    }

    /// @notice The loop custody's value in avKAT: its equity (collateral minus debt at the market oracle price) plus
    /// its idle avKAT.
    function loopEquityAvkat() public view returns (uint256) {
        (uint256 collateral, uint256 debt, uint256 collateralValue,) =
            ICurveYieldLoopCustody(LOOP_CUSTODY).positionSnapshot();
        uint256 equity = collateralValue > debt ? Math.mulDiv(collateral, collateralValue - debt, collateralValue) : 0;
        return equity + IERC20(AVKAT).balanceOf(LOOP_CUSTODY);
    }

    /// @notice The farm's value in avKAT: idle allowed farm tokens and farm Charm positions ONLY.
    /// Directly received cyavKAT wrapper revenue is excluded until redeemed into avKAT;
    /// this custody is an off-vault-PPS revenue recipient, never an IPOR vault balance-fuse target.
    function farmValueAvkat() public view returns (uint256 total_) {
        address[] memory list = _tokens;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] != AVKAT) total_ += _valueAvkat(list[i], IERC20(list[i]).balanceOf(address(this)));
        }
        address[] memory vaults = _charmVaults;
        for (uint256 i; i < vaults.length; ++i) {
            (uint256 v0, uint256 v1) = _charmSides(vaults[i]);
            total_ += v0 + v1;
        }
    }

    /// @notice cyavKAT's deposit rate: avKAT per whole share.
    function polDepositRate() public view returns (uint256) {
        return ICurveYieldCustodyVault(VAULT).convertToAssets(_oneShare());
    }

    /// @notice (cyavKAT, WETH, Alpha shares) held through position B.
    function polPosition() public view returns (uint256 cyavkat_, uint256 weth_, uint256 shares_) {
        address alpha = polVenues.alphaVault;
        if (alpha == address(0)) return (0, 0, 0);
        (uint256 a0, uint256 a1) = _charmAmounts(alpha);
        shares_ = IERC20(alpha).balanceOf(address(this));
        (cyavkat_, weth_) = ICurveYieldCustodyCharm(alpha).token0() == VAULT ? (a0, a1) : (a1, a0);
    }

    /// @notice Redeem directly received wrapper-revenue cyavKAT shares into idle avKAT.
    /// This is a normal vault withdrawal: liquidity and withdrawal-fee checks remain enforced.
    /// The avKAT can then be loop/farm-deployed with deployAll, or assigned to POL with reserveAvkatForPolBps.
    /// No custody assets are reported to the main vault's PPS accounting. An unmet minimum reverts atomically.
    function redeemWrapperRevenue(uint256 shares_, uint256 minimumAvkatOut_)
        external onlyOperator nonReentrant returns (uint256 received_)
    {
        uint256 held = IERC20(VAULT).balanceOf(address(this));
        if (shares_ == 0 || shares_ > held) revert InsufficientWrapperShares(shares_, held);
        uint256 beforeBal = IERC20(AVKAT).balanceOf(address(this));
        ICurveYieldCustodyVault(VAULT).redeem(shares_, address(this), address(this));
        received_ = IERC20(AVKAT).balanceOf(address(this)) - beforeBal;
        if (received_ < minimumAvkatOut_) revert WrapperRedeemBelowMinimum(received_, minimumAvkatOut_);
        emit WrapperRevenueRedeemed(shares_, received_);
    }

    /// @notice Set POL reservation against ALL local avKAT, replacing the prior reservation.
    /// No automatic split or external feeder funding exists; 0 releases the full reservation.
    function reserveAvkatForPolBps(uint16 bps_) external onlyOperator nonReentrant {
        if (bps_ > BPS) revert InvalidPolReserveBps(bps_);
        uint256 balance = IERC20(AVKAT).balanceOf(address(this));
        polBudgetAvkat = Math.mulDiv(balance, bps_, BPS);
        emit PolReserveBpsApplied(bps_, balance, polBudgetAvkat);
    }

    // ---------------------------------------------------------------- allocation

    /// @notice Idle avKAT: the loop custody is filled up to the loop's target share of the combined value (this
    /// custody + the loop custody) and runs its own deployAll; the rest is spread over the farm's active Charm
    /// positions pro rata (it goes to the loop while the farm has none).
    function deployAll() external onlyOperator nonReentrant {
        uint256 idle = idleAvkat();
        uint256 toFarm;
        if (idle != 0 && _charmVaults.length != 0) {
            uint256 equity = loopEquityAvkat();
            uint256 farmValue = farmValueAvkat();
            uint256 total = idle + equity + farmValue;
            uint256 target = Math.mulDiv(total, loopTargetBps(), BPS);
            uint256 toLoop = equity >= target ? 0 : Math.min(idle, target - equity);
            if (idle > toLoop) toFarm = _deployFarm(idle - toLoop, farmValue);
            emit Allocated(idle - toFarm, toFarm, equity, total);
            idle -= toFarm;
        }
        if (idle != 0) IERC20(AVKAT).safeTransfer(LOOP_CUSTODY, idle);
        ICurveYieldLoopCustody(LOOP_CUSTODY).deployAll();
    }

    /// @notice PPS backstop: pays up to `lossAvkat_` avKAT to the vault now; returns what was paid (less only when the
    /// custody is worth less). Idle avKAT first, then the farm. Position B, its budget and the loop custody are never
    /// used.
    function cover(uint256 lossAvkat_) external nonReentrant returns (uint256 paid_) {
        if (!isCoverer[msg.sender]) revert NotOperator(msg.sender);
        if (lossAvkat_ == 0) return 0;
        if (idleAvkat() < lossAvkat_) _pullFarm(lossAvkat_);
        uint256 idle = idleAvkat();
        paid_ = idle < lossAvkat_ ? idle : lossAvkat_;
        if (paid_ != 0) IERC20(AVKAT).safeTransfer(VAULT, paid_);
        emit LossCovered(msg.sender, lossAvkat_, paid_);
    }

    function scheduleFullUnwind(address recipient_) external onlyOwner {
        if (recipient_ == address(0) || recipient_ == address(this)) revert InvalidAddress(recipient_);
        if (queuedRecipient != address(0)) revert FullUnwindAlreadyQueued(queuedRecipient, queuedExecuteAfter);
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

    /// @notice After the delay: moves everything this custody holds to the recipient (a successor custody): avKAT, KAT,
    /// the farm's tokens and Charm shares, and position B's Alpha shares, cyavKAT and WETH. The loop custody is separate.
    function executeFullUnwind() external onlyOwner nonReentrant {
        address recipient = queuedRecipient;
        if (recipient == address(0)) revert FullUnwindNotQueued();
        if (block.timestamp < queuedExecuteAfter) revert FullUnwindDelayActive(queuedExecuteAfter);
        delete queuedRecipient;
        delete queuedExecuteAfter;
        delete polBudgetAvkat;
        uint256 avkatAmount = IERC20(AVKAT).balanceOf(address(this));
        uint256 katAmount = IERC20(KAT).balanceOf(address(this));
        address[] memory list = _tokens; // includes avKAT and KAT
        for (uint256 i; i < list.length; ++i) _sendAll(list[i], recipient);
        list = _charmVaults;
        for (uint256 i; i < list.length; ++i) _sendAll(list[i], recipient);
        _sendAll(VAULT, recipient);
        _sendAll(WETH, recipient);
        if (polVenues.alphaVault != address(0)) _sendAll(polVenues.alphaVault, recipient);
        emit FullUnwindExecuted(recipient, avkatAmount, katAmount);
    }

    // ---------------------------------------------------------------- farm (operators)

    /// @notice Swaps between allowed tokens through the router v2 (max(its protected minimum, `minOut_`)).
    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minOut_)
        external onlyOperator nonReentrant returns (uint256)
    {
        if (tokenRefs[tokenIn_] == 0) revert TokenNotAllowed(tokenIn_);
        if (tokenRefs[tokenOut_] == 0) revert TokenNotAllowed(tokenOut_);
        if (tokenIn_ == AVKAT && amountIn_ > idleAvkat()) revert InsufficientAvkat(amountIn_, idleAvkat());
        return _swap(tokenIn_, tokenOut_, amountIn_, minOut_);
    }

    function charmDeposit(address vault_, uint256 amount0_, uint256 amount1_, uint256 min0_, uint256 min1_)
        external onlyOperator nonReentrant returns (uint256)
    {
        if (!isCharmVaultAllowed[vault_]) revert CharmVaultNotAllowed(vault_);
        return _charmDeposit(vault_, amount0_, amount1_, min0_, min1_);
    }

    function charmWithdraw(address vault_, uint256 shares_, uint256 min0_, uint256 min1_)
        external onlyOperator nonReentrant returns (uint256, uint256)
    {
        if (!isCharmVaultAllowed[vault_]) revert CharmVaultNotAllowed(vault_);
        return _charmWithdraw(vault_, shares_, min0_, min1_);
    }

    /// @notice Merkl claim for every Charm position (farm and position B): each claimed token becomes avKAT through the
    /// router v2 and is split like a loop gain (rewards-manager share, fee-recipient share, the rest stays idle).
    function harvestMerkl(address[] calldata tokens_, uint256[] calldata amounts_, bytes32[][] calldata proofs_)
        external onlyOperator nonReentrant returns (uint256 avkatOut_)
    {
        uint256 n = tokens_.length;
        uint256[] memory before = new uint256[](n);
        address[] memory users = new address[](n);
        for (uint256 i; i < n; ++i) {
            before[i] = IERC20(tokens_[i]).balanceOf(address(this));
            users[i] = address(this);
        }
        ICurveYieldCustodyMerkl(MERKL).claim(users, tokens_, amounts_, proofs_);
        for (uint256 i; i < n; ++i) {
            uint256 got = IERC20(tokens_[i]).balanceOf(address(this)) - before[i];
            avkatOut_ += tokens_[i] == AVKAT ? got : _toAvkat(tokens_[i], got);
        }
        (uint256 toRm, uint256 toFee) = _distributeGain(avkatOut_);
        emit Harvested(avkatOut_, toRm, toFee);
    }

    // ---------------------------------------------------------------- POL position B

    /// @notice Buys cyavKAT (POL pool, never above the deposit rate x (1 + polCustody.maxPremiumBps)) and WETH (router
    /// v2) at the Alpha Vault's current value ratio and deposits. `avkatIn_` 0 = the whole budget. Leftovers stay held.
    function polDeploy(uint256 avkatIn_) external onlyOperator nonReentrant returns (uint256 shares_) {
        uint256 budget = Math.min(polBudgetAvkat, IERC20(AVKAT).balanceOf(address(this)));
        if (avkatIn_ == 0 || avkatIn_ > budget) avkatIn_ = budget;
        if (avkatIn_ == 0) return 0;
        polBudgetAvkat -= avkatIn_;
        CyCustodyPolVenues memory v = polVenues;
        (uint256 cy, uint256 w,) = polPosition();
        uint256 cyVal = cy * polDepositRate() / _oneShare();
        uint256 wVal = _valueAvkat(WETH, w);
        uint256 forCy = cyVal + wVal == 0 ? avkatIn_ / 2 : avkatIn_ * cyVal / (cyVal + wVal);
        uint256 cyBought;
        if (forCy != 0) {
            uint256 maxPriceBps = BPS + _config1(K.POLC_MAX_PREMIUM_BPS);
            uint256 minOut = forCy * _oneShare() * BPS / (polDepositRate() * maxPriceBps);
            cyBought = CurveYieldSwapLib.balancerSwap(v.balancerRouter, v.permit2, v.polPool, AVKAT, VAULT, forCy, minOut);
        }
        uint256 wethBought = avkatIn_ == forCy ? 0 : _swap(AVKAT, WETH, avkatIn_ - forCy, 0);
        // only what was just bought is deposited (WETH may also be a farm token); the vault keeps any unused part
        shares_ = ICurveYieldCustodyCharm(v.alphaVault).token0() == VAULT
            ? _charmDeposit(v.alphaVault, cyBought, wethBought, 0, 0)
            : _charmDeposit(v.alphaVault, wethBought, cyBought, 0, 0);
        emit PolDeployed(avkatIn_, cyBought, wethBought, shares_);
    }

    /// @notice Exits `shares_` of position B to avKAT for `receiver_` (owner only). The cyavKAT leg is sold in the POL
    /// pool only if that returns at least its net value, otherwise redeemed through the burn-only instant withdrawal.
    function polExitToAvkat(uint256 shares_, address receiver_) external onlyOwner nonReentrant returns (uint256 avkatOut_) {
        if (receiver_ == address(0)) revert InvalidAddress(receiver_);
        CyCustodyPolVenues memory v = polVenues;
        uint256 held = IERC20(v.alphaVault).balanceOf(address(this));
        if (shares_ == 0 || shares_ > held) shares_ = held;
        uint256 avkatBefore = IERC20(AVKAT).balanceOf(address(this));
        (uint256 o0, uint256 o1) = _charmWithdraw(v.alphaVault, shares_, 0, 0);
        (uint256 cy, uint256 w) = ICurveYieldCustodyCharm(v.alphaVault).token0() == VAULT ? (o0, o1) : (o1, o0);
        if (w != 0) _swap(WETH, AVKAT, w, 0);
        bool sold;
        if (cy != 0) {
            try this.sellCyavkatSelf(cy, cy * polDepositRate() / _oneShare()) { sold = true; } catch {}
            if (!sold) {
                ICurveYieldCustodyWithdrawManager(v.withdrawManager).armBurnOnlyFee();
                ICurveYieldCustodyVault(VAULT).redeem(cy, address(this), address(this));
            }
        }
        avkatOut_ = IERC20(AVKAT).balanceOf(address(this)) - avkatBefore;
        IERC20(AVKAT).safeTransfer(receiver_, avkatOut_);
        emit PolExited(shares_, avkatOut_, sold, receiver_);
    }

    // ---------------------------------------------------------------- self-calls (try/catch steps)

    /// @dev Position B cyavKAT sale at no less than `minOut_` (its net value).
    function sellCyavkatSelf(uint256 cy_, uint256 minOut_) external onlySelf {
        CyCustodyPolVenues memory v = polVenues;
        CurveYieldSwapLib.balancerSwap(v.balancerRouter, v.permit2, v.polPool, VAULT, AVKAT, cy_, minOut_);
    }

    /// @dev Router swap to avKAT, so one unroutable token does not fail a harvest or a cover.
    function swapToAvkatSelf(address token_, uint256 amount_) external onlySelf returns (uint256) {
        return _swap(token_, AVKAT, amount_, 0);
    }

    /// @dev Farm cover step: a slice of a Charm vault, both tokens converted to avKAT.
    function charmExitSelf(address vault_, uint256 shares_) external onlySelf {
        (uint256 a0, uint256 a1) = _charmWithdraw(vault_, shares_, 0, 0);
        (address t0, address t1) = _pair(vault_);
        _toAvkat(t0, a0);
        _toAvkat(t1, a1);
    }

    // ---------------------------------------------------------------- internals: farm

    /// @dev Spreads `amount_` avKAT over the farm's active Charm vaults in proportion to their value, each in its
    /// current token ratio. The value added must be at least (1 - farm.maxDeployLossBps) of the avKAT spent. Returns
    /// the avKAT used (0 when no vault holds value).
    function _deployFarm(uint256 amount_, uint256 valueBefore_) private returns (uint256) {
        if (valueBefore_ == 0) return 0;
        address[] memory vaults = _charmVaults;
        uint256[2][] memory sides = new uint256[2][](vaults.length);
        uint256 vaultValue;
        for (uint256 i; i < vaults.length; ++i) {
            (sides[i][0], sides[i][1]) = _charmSides(vaults[i]);
            vaultValue += sides[i][0] + sides[i][1];
        }
        if (vaultValue == 0) return 0;
        for (uint256 i; i < vaults.length; ++i) {
            uint256 value = sides[i][0] + sides[i][1];
            if (value == 0) continue;
            uint256 share = Math.mulDiv(amount_, value, vaultValue);
            uint256 for0 = Math.mulDiv(share, sides[i][0], value);
            (address t0, address t1) = _pair(vaults[i]);
            _charmDeposit(vaults[i], _fromAvkat(t0, for0), _fromAvkat(t1, share - for0), 0, 0);
        }
        uint256 added = farmValueAvkat() - valueBefore_;
        if (added * BPS < amount_ * (BPS - _config1(K.FARM_MAX_DEPLOY_LOSS_BPS))) revert DeployLossTooHigh(added, amount_);
        emit FarmDeployed(amount_, added);
        return amount_;
    }

    /// @dev Cover from the farm until the idle avKAT reaches `target_`: idle farm tokens, then Charm slices. A step
    /// that fails is skipped.
    function _pullFarm(uint256 target_) private {
        address[] memory list = _tokens;
        for (uint256 i; i < list.length && idleAvkat() < target_; ++i) {
            if (list[i] != AVKAT) _toAvkat(list[i], IERC20(list[i]).balanceOf(address(this)));
        }
        list = _charmVaults;
        for (uint256 i; i < list.length && idleAvkat() < target_; ++i) {
            (uint256 v0, uint256 v1) = _charmSides(list[i]);
            if (v0 + v1 == 0) continue;
            uint256 fWad = Math.min(
                Math.mulDiv(target_ - idleAvkat(), 1e18 * (BPS + PULL_MARGIN_BPS), (v0 + v1) * BPS), 1e18
            );
            uint256 shares = Math.mulDiv(IERC20(list[i]).balanceOf(address(this)), fWad, 1e18);
            try this.charmExitSelf(list[i], shares) {} catch (bytes memory reason) { emit StepSkipped(2, reason); }
        }
    }

    function _charmDeposit(address vault_, uint256 a0_, uint256 a1_, uint256 min0_, uint256 min1_)
        private returns (uint256 shares_)
    {
        (address t0, address t1) = _pair(vault_);
        IERC20(t0).forceApprove(vault_, a0_);
        IERC20(t1).forceApprove(vault_, a1_);
        uint256 used0;
        uint256 used1;
        (shares_, used0, used1) = ICurveYieldCustodyCharm(vault_).deposit(a0_, a1_, min0_, min1_, address(this));
        IERC20(t0).forceApprove(vault_, 0);
        IERC20(t1).forceApprove(vault_, 0);
        emit CharmDeposited(vault_, shares_, used0, used1);
    }

    function _charmWithdraw(address vault_, uint256 shares_, uint256 min0_, uint256 min1_)
        private returns (uint256 a0_, uint256 a1_)
    {
        (a0_, a1_) = ICurveYieldCustodyCharm(vault_).withdraw(shares_, min0_, min1_, address(this));
        emit CharmWithdrawn(vault_, shares_, a0_, a1_);
    }

    /// @dev Token amounts behind the custody's shares of a Charm vault.
    function _charmAmounts(address vault_) private view returns (uint256 a0_, uint256 a1_) {
        ICurveYieldCustodyCharm vault = ICurveYieldCustodyCharm(vault_);
        uint256 shares = vault.balanceOf(address(this));
        uint256 supply = vault.totalSupply();
        if (shares == 0 || supply == 0) return (0, 0);
        (uint256 total0, uint256 total1) = vault.getTotalAmounts();
        return (Math.mulDiv(total0, shares, supply), Math.mulDiv(total1, shares, supply));
    }

    /// @dev avKAT value of each side of the custody's share of a Charm vault.
    function _charmSides(address vault_) private view returns (uint256 v0_, uint256 v1_) {
        (uint256 a0, uint256 a1) = _charmAmounts(vault_);
        (address t0, address t1) = _pair(vault_);
        return (_valueAvkat(t0, a0), _valueAvkat(t1, a1));
    }

    function _pair(address vault_) private view returns (address, address) {
        return (ICurveYieldCustodyCharm(vault_).token0(), ICurveYieldCustodyCharm(vault_).token1());
    }

    // ---------------------------------------------------------------- internals: shared

    /// @dev Splits a gain like a loop gain: rewards-manager share (then updateBalance), fee-recipient share.
    function _distributeGain(uint256 gain_) private returns (uint256 toRm_, uint256 toFee_) {
        (uint256 rmBps, uint256 frBps) = windupDistributionBps();
        toRm_ = gain_ * rmBps / BPS;
        toFee_ = gain_ * frBps / BPS;
        if (toRm_ != 0) {
            address rm = REWARDS_CLAIM_MANAGER();
            IERC20(AVKAT).safeTransfer(rm, toRm_);
            ICurveYieldCustodyRewardsManager(rm).updateBalance();
        }
        if (toFee_ != 0) IERC20(AVKAT).safeTransfer(feeRecipient, toFee_);
    }

    /// @dev avKAT value of `amount_` of `token_` at the router's time-weighted expected output (0 if unquotable).
    function _valueAvkat(address token_, uint256 amount_) private view returns (uint256) {
        if (amount_ == 0 || token_ == AVKAT) return amount_;
        try ICurveYieldCustodyRouter(ROUTER()).protectedQuote(token_, AVKAT, amount_) returns (uint256 expected, uint256) {
            return expected;
        } catch {
            return 0;
        }
    }

    /// @dev Router v2 enforces max(its protected minimum, `minOut_`).
    function _swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minOut_) private returns (uint256 out_) {
        address router = ROUTER();
        IERC20(tokenIn_).forceApprove(router, amountIn_);
        out_ = ICurveYieldCustodyRouter(router).swapExactInput(
            tokenIn_, tokenOut_, amountIn_, minOut_, address(this), block.timestamp
        );
        IERC20(tokenIn_).forceApprove(router, 0);
        emit Swapped(tokenIn_, tokenOut_, amountIn_, out_);
    }

    /// @dev avKAT -> `token_` (no-op for avKAT or 0).
    function _fromAvkat(address token_, uint256 amount_) private returns (uint256) {
        if (token_ == AVKAT || amount_ == 0) return amount_;
        return _swap(AVKAT, token_, amount_, 0);
    }

    /// @dev `token_` -> avKAT through a self-call: an unroutable token is skipped (StepSkipped), never fatal.
    function _toAvkat(address token_, uint256 amount_) private returns (uint256 out_) {
        if (token_ == AVKAT || amount_ == 0) return amount_;
        try this.swapToAvkatSelf(token_, amount_) returns (uint256 out) {
            out_ = out;
        } catch (bytes memory reason) {
            emit StepSkipped(1, reason);
        }
    }

    function _oneShare() private view returns (uint256) {
        return 10 ** ICurveYieldCustodyVault(VAULT).decimals();
    }

    function _sendAll(address token_, address to_) private {
        uint256 amount = IERC20(token_).balanceOf(address(this));
        if (amount != 0) IERC20(token_).safeTransfer(to_, amount);
    }

    function _setOperator(address operator_, bool enabled_) private {
        if (operator_ == address(0)) revert InvalidAddress(operator_);
        isOperator[operator_] = enabled_;
        emit OperatorSet(operator_, enabled_);
    }

    function _addTokenRef(address token_) private {
        if (tokenRefs[token_]++ == 0) _tokens.push(token_);
    }

    function _removeTokenRef(address token_) private {
        if (tokenRefs[token_] == 0 || --tokenRefs[token_] != 0) return;
        _removeAddress(_tokens, token_);
    }

    function _removeAddress(address[] storage list_, address item_) private {
        uint256 n = list_.length;
        for (uint256 i; i < n; ++i) {
            if (list_[i] == item_) {
                list_[i] = list_[n - 1];
                list_.pop();
                return;
            }
        }
    }
}

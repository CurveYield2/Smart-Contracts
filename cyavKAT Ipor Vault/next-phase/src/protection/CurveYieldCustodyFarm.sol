// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";
import {CurveYieldCustodyFarmPlanner, FarmDeployLeg} from "./CurveYieldCustodyFarmPlanner.sol";

interface IFarmRouter {
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minNetAmountOut, address recipient, uint256 deadline)
        external returns (uint256 netOut);
}

interface IFarmNpm {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function factory() external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address token0, address token1, uint24 fee, int24, int24, uint128 liquidity, uint256, uint256, uint128, uint128);
    function mint(MintParams calldata params)
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external payable;
    function approve(address to, uint256 tokenId) external;
}

interface IFarmV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IFarmStaker {
    function stake(uint256 tokenId) external;
    function unstake(uint256 tokenId) external;
}

interface IFarmCharm {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function deposit(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address to)
        external returns (uint256 shares, uint256 amount0, uint256 amount1);
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address to)
        external returns (uint256 amount0, uint256 amount1);
}

interface IFarmMerkl {
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs)
        external;
}

interface IFarmCustody {
    function REWARDS_CLAIM_MANAGER() external view returns (address);
    function feeRecipient() external view returns (address);
    function windupDistributionBps() external view returns (uint256 rewardManagerBps, uint256 feeRecipientBps);
}

interface IFarmRewardsManager {
    function updateBalance() external;
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
/// @title CurveYieldCustodyFarm (CUSTODY_FARM_SPEC)
/// @notice The revenue custody's "everything else" allocation: allowlisted Sushi V3 positions (optionally staked in the
/// Katana SushiStaker), allowlisted Charm vaults and Merkl rewards. Operators move it by hand; the custody deploys new
/// avKAT pro rata over the active positions and pulls from the farm first when it covers a vault loss.
/// Swaps only between allowed tokens (the tokens of allowlisted pools / vaults, avKAT, KAT), always through the swap
/// router v2 (protected minimum). Merkl rewards are converted to avKAT and split like a loop gain.
contract CurveYieldCustodyFarm is Ownable2Step, ReentrancyGuard, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant PULL_MARGIN_BPS = 50; // unwind 0.5% more than the shortfall (rounding, fees)

    address public immutable AVKAT;
    address public immutable KAT;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.REVENUE_CUSTODY`, GATE_CONFIG_SPEC §10).
    function CUSTODY() public view returns (address) {
        return _addr(CurveYieldAddrKeys.REVENUE_CUSTODY);
    }
    /// @notice Wired in the gate (`CurveYieldAddrKeys.SWAP_ROUTER`, GATE_CONFIG_SPEC §10).
    function ROUTER() public view returns (address) {
        return _addr(CurveYieldAddrKeys.SWAP_ROUTER);
    }
    address public immutable NPM;
    address public immutable STAKER;
    address public immutable MERKL;
    CurveYieldCustodyFarmPlanner public immutable PLANNER;

    mapping(address => bool) public isOperator;
    mapping(address => bool) public isPoolAllowed;
    mapping(address => bool) public isCharmVaultAllowed;
    mapping(address => uint256) public tokenRefs; // allowed-token reference count (pools / vaults using it)
    mapping(uint256 => bool) public isStaked;
    address[] private _tokens;
    address[] private _charmVaults;
    uint256[] private _positionIds;

    event OperatorSet(address indexed operator, bool enabled);
    event PoolAllowed(address indexed pool, bool allowed);
    event CharmVaultAllowed(address indexed vault, bool allowed);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event PositionMinted(uint256 indexed tokenId, address pool, uint128 liquidity);
    event LiquidityChanged(uint256 indexed tokenId, int256 liquidityDelta, uint256 amount0, uint256 amount1);
    event PositionBurned(uint256 indexed tokenId);
    event Staked(uint256 indexed tokenId, bool staked);
    event CharmDeposited(address indexed vault, uint256 shares, uint256 amount0, uint256 amount1);
    event CharmWithdrawn(address indexed vault, uint256 shares, uint256 amount0, uint256 amount1);
    event Harvested(uint256 avkatOut, uint256 toRewardsManager, uint256 toFeeRecipient);
    event Deployed(uint256 avkatIn, uint256 legs, uint256 valueAdded);
    event CoverPulled(uint256 requested, uint256 paid);
    event ReturnedToCustody(uint256 amount);
    event StepSkipped(uint8 step, bytes reason);

    error NotOperator(address caller);
    error NotCustody(address caller);
    error InvalidAddress();
    error TokenNotAllowed(address token);
    error PoolNotAllowed(address pool);
    error CharmVaultNotAllowed(address vault);
    error UnknownPosition(uint256 tokenId);
    error DeployLossTooHigh(uint256 valueAdded, uint256 avkatSpent);

    modifier onlyOperator() {
        if (!isOperator[msg.sender] && msg.sender != owner()) revert NotOperator(msg.sender);
        _;
    }

    modifier onlyCustody() {
        if (msg.sender != CUSTODY()) revert NotCustody(msg.sender);
        _;
    }

    constructor(
        address owner_,
        address avkat_,
        address kat_,
        address npm_,
        address staker_,
        address merkl_,
        address planner_,
        address configGate_,
        address[] memory operators_
    ) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        if (
            avkat_ == address(0) || kat_ == address(0) ||
            npm_ == address(0) || staker_ == address(0) || merkl_ == address(0) || planner_ == address(0)
        ) revert InvalidAddress();
        (AVKAT, KAT, NPM, STAKER, MERKL) = (avkat_, kat_, npm_, staker_, merkl_);
        PLANNER = CurveYieldCustodyFarmPlanner(planner_);
        _addTokenRef(avkat_);
        _addTokenRef(kat_);
        for (uint256 i; i < operators_.length; ++i) _setOperator(operators_[i], true);
    }

    // ---------------------------------------------------------------- administration (owner = the gate)

    function setOperator(address operator_, bool enabled_) external onlyOwner {
        _setOperator(operator_, enabled_);
    }

    function setPoolAllowed(address pool_, bool allowed_) external onlyOwner {
        if (pool_ == address(0) || isPoolAllowed[pool_] == allowed_) return;
        isPoolAllowed[pool_] = allowed_;
        (address t0, address t1) = (IFarmCharm(pool_).token0(), IFarmCharm(pool_).token1());
        if (allowed_) {
            _addTokenRef(t0);
            _addTokenRef(t1);
        } else {
            _removeTokenRef(t0);
            _removeTokenRef(t1);
        }
        emit PoolAllowed(pool_, allowed_);
    }

    function setCharmVaultAllowed(address vault_, bool allowed_) external onlyOwner {
        if (vault_ == address(0) || isCharmVaultAllowed[vault_] == allowed_) return;
        // a vault still holding farm shares cannot leave the list (its shares would drop out of the valuation)
        if (!allowed_ && IERC20(vault_).balanceOf(address(this)) != 0) revert CharmVaultNotAllowed(vault_);
        isCharmVaultAllowed[vault_] = allowed_;
        (address t0, address t1) = (IFarmCharm(vault_).token0(), IFarmCharm(vault_).token1());
        if (allowed_) {
            _addTokenRef(t0);
            _addTokenRef(t1);
            _charmVaults.push(vault_);
        } else {
            _removeTokenRef(t0);
            _removeTokenRef(t1);
            _removeVault(vault_);
        }
        emit CharmVaultAllowed(vault_, allowed_);
    }

    // ---------------------------------------------------------------- views (for the planner and operators)

    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    function positionIds() external view returns (uint256[] memory) {
        return _positionIds;
    }

    function charmVaults() external view returns (address[] memory) {
        return _charmVaults;
    }

    function twapWindow() external view returns (uint32) {
        return uint32(_config1(K.ROUTER_TWAP_WINDOW));
    }

    function totalValueAvkat() external view returns (uint256) {
        return PLANNER.totalValueAvkat(address(this));
    }

    function hasActivePositions() external view returns (bool) {
        return PLANNER.hasActivePositions(address(this));
    }

    // ---------------------------------------------------------------- operator actions

    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minOut_)
        external onlyOperator nonReentrant returns (uint256)
    {
        _requireToken(tokenIn_);
        _requireToken(tokenOut_);
        return _swap(tokenIn_, tokenOut_, amountIn_, minOut_);
    }

    function mint(IFarmNpm.MintParams calldata p_) external onlyOperator nonReentrant returns (uint256 tokenId_) {
        address pool = IFarmV3Factory(IFarmNpm(NPM).factory()).getPool(p_.token0, p_.token1, p_.fee);
        if (!isPoolAllowed[pool]) revert PoolNotAllowed(pool);
        IFarmNpm.MintParams memory p = p_;
        p.recipient = address(this);
        p.deadline = block.timestamp;
        _approve(p.token0, NPM, p.amount0Desired);
        _approve(p.token1, NPM, p.amount1Desired);
        uint128 liquidity;
        (tokenId_, liquidity,,) = IFarmNpm(NPM).mint(p);
        _approve(p.token0, NPM, 0);
        _approve(p.token1, NPM, 0);
        _positionIds.push(tokenId_);
        emit PositionMinted(tokenId_, pool, liquidity);
    }

    function increaseLiquidity(uint256 tokenId_, uint256 amount0_, uint256 amount1_, uint256 min0_, uint256 min1_)
        external onlyOperator nonReentrant
    {
        _increase(tokenId_, amount0_, amount1_, min0_, min1_);
    }

    function decreaseLiquidity(uint256 tokenId_, uint128 liquidity_, uint256 min0_, uint256 min1_)
        external onlyOperator nonReentrant returns (uint256, uint256)
    {
        return _decrease(tokenId_, liquidity_, min0_, min1_);
    }

    function collect(uint256 tokenId_) external onlyOperator nonReentrant returns (uint256 a0_, uint256 a1_) {
        _requirePosition(tokenId_);
        bool wasStaked = isStaked[tokenId_];
        if (wasStaked) _unstake(tokenId_);
        (a0_, a1_) = _collect(tokenId_);
        if (wasStaked) _stake(tokenId_);
    }

    /// @notice Burns an empty position (liquidity 0, fees collected) and forgets it.
    function burn(uint256 tokenId_) external onlyOperator nonReentrant {
        _requirePosition(tokenId_);
        if (isStaked[tokenId_]) _unstake(tokenId_);
        _collect(tokenId_);
        IFarmNpm(NPM).burn(tokenId_);
        _removePosition(tokenId_);
        emit PositionBurned(tokenId_);
    }

    function stake(uint256 tokenId_) external onlyOperator nonReentrant {
        _requirePosition(tokenId_);
        _stake(tokenId_);
    }

    function unstake(uint256 tokenId_) external onlyOperator nonReentrant {
        _requirePosition(tokenId_);
        _unstake(tokenId_);
    }

    function charmDeposit(address vault_, uint256 amount0_, uint256 amount1_, uint256 min0_, uint256 min1_)
        external onlyOperator nonReentrant returns (uint256)
    {
        return _charmDeposit(vault_, amount0_, amount1_, min0_, min1_);
    }

    function charmWithdraw(address vault_, uint256 shares_, uint256 min0_, uint256 min1_)
        external onlyOperator nonReentrant returns (uint256, uint256)
    {
        return _charmWithdraw(vault_, shares_, min0_, min1_);
    }

    /// @notice Merkl claim; every claimed token becomes avKAT (router v2), split like a loop gain: the custody's
    /// rewards-manager share to the rewards claim manager, its fee-recipient share to its fee recipient, the rest stays.
    function harvest(address[] calldata tokens_, uint256[] calldata amounts_, bytes32[][] calldata proofs_)
        external onlyOperator nonReentrant returns (uint256 avkatOut_)
    {
        uint256[] memory before = new uint256[](tokens_.length);
        for (uint256 i; i < tokens_.length; ++i) before[i] = IERC20(tokens_[i]).balanceOf(address(this));
        address[] memory users = new address[](tokens_.length);
        for (uint256 i; i < tokens_.length; ++i) users[i] = address(this);
        IFarmMerkl(MERKL).claim(users, tokens_, amounts_, proofs_);
        for (uint256 i; i < tokens_.length; ++i) {
            uint256 got = IERC20(tokens_[i]).balanceOf(address(this)) - before[i];
            if (got == 0) continue;
            if (tokens_[i] == AVKAT) {
                avkatOut_ += got;
                continue;
            }
            try this.swapForHarvest(tokens_[i], got) returns (uint256 out) {
                avkatOut_ += out;
            } catch (bytes memory reason) {
                emit StepSkipped(1, reason);
            }
        }
        (uint256 rmBps, uint256 frBps) = IFarmCustody(CUSTODY()).windupDistributionBps();
        uint256 toRm = avkatOut_ * rmBps / BPS;
        uint256 toFee = avkatOut_ * frBps / BPS;
        if (toRm != 0) {
            address rm = IFarmCustody(CUSTODY()).REWARDS_CLAIM_MANAGER();
            IERC20(AVKAT).safeTransfer(rm, toRm);
            IFarmRewardsManager(rm).updateBalance();
        }
        if (toFee != 0) IERC20(AVKAT).safeTransfer(IFarmCustody(CUSTODY()).feeRecipient(), toFee);
        emit Harvested(avkatOut_, toRm, toFee);
    }

    /// @dev Self-call so one unroutable reward token does not fail the harvest.
    function swapForHarvest(address token_, uint256 amount_) external returns (uint256) {
        if (msg.sender != address(this)) revert NotOperator(msg.sender);
        return _swap(token_, AVKAT, amount_, 0);
    }

    function returnToCustody(uint256 amountAvkat_) external onlyOperator nonReentrant {
        IERC20(AVKAT).safeTransfer(CUSTODY(), amountAvkat_);
        emit ReturnedToCustody(amountAvkat_);
    }

    // ---------------------------------------------------------------- custody hooks

    /// @notice Spreads `amountAvkat_` (already sent here by the custody) over the active positions in proportion to
    /// their current value, in each position's current token ratio. The value added must be at least
    /// (1 - farm.maxDeployLossBps) of the avKAT spent. Leftovers stay idle here.
    function deployProRata(uint256 amountAvkat_) external onlyCustody nonReentrant {
        FarmDeployLeg[] memory legs = PLANNER.deployPlan(address(this), amountAvkat_);
        if (legs.length == 0) return;
        uint256 valueBefore = PLANNER.totalValueAvkat(address(this)) - amountAvkat_;
        for (uint256 i; i < legs.length; ++i) {
            FarmDeployLeg memory leg = legs[i];
            uint256 a0 = leg.token0 == AVKAT ? leg.avkatFor0 : _swapIf(AVKAT, leg.token0, leg.avkatFor0);
            uint256 a1 = leg.token1 == AVKAT ? leg.avkatFor1 : _swapIf(AVKAT, leg.token1, leg.avkatFor1);
            if (leg.kind == PLANNER.KIND_SUSHI()) _increase(leg.tokenId, a0, a1, 0, 0);
            else _charmDeposit(leg.vault, a0, a1, 0, 0);
        }
        uint256 added = PLANNER.totalValueAvkat(address(this)) - valueBefore;
        uint256 maxLoss = _config1(K.FARM_MAX_DEPLOY_LOSS_BPS);
        if (added * BPS < amountAvkat_ * (BPS - maxLoss)) revert DeployLossTooHigh(added, amountAvkat_);
        emit Deployed(amountAvkat_, legs.length, added);
    }

    /// @notice Pays up to `amountAvkat_` avKAT to the custody for a vault-loss cover: idle avKAT, then other idle
    /// tokens, then Charm withdrawals, then Sushi positions (each a proportional slice, swapped to avKAT). A step that
    /// fails is skipped.
    function coverPull(uint256 amountAvkat_) external onlyCustody nonReentrant returns (uint256 paid_) {
        if (_short(amountAvkat_) != 0) _sellIdleTokens(amountAvkat_);
        address[] memory vaults = _charmVaults;
        for (uint256 i; i < vaults.length && _short(amountAvkat_) != 0; ++i) {
            uint256 value = PLANNER.charmValue(address(this), vaults[i]);
            if (value == 0) continue;
            uint256 shares = Math.mulDiv(IERC20(vaults[i]).balanceOf(address(this)), _fraction(amountAvkat_, value), 1e18);
            try this.charmExitForCover(vaults[i], shares) {} catch (bytes memory reason) { emit StepSkipped(2, reason); }
        }
        uint256[] memory ids = _positionIds;
        for (uint256 i; i < ids.length && _short(amountAvkat_) != 0; ++i) {
            uint256 value = PLANNER.sushiValue(address(this), ids[i]);
            if (value == 0) continue;
            (,,,,,,, uint128 liquidity,,,,) = IFarmNpm(NPM).positions(ids[i]);
            uint128 part = uint128(Math.mulDiv(liquidity, _fraction(amountAvkat_, value), 1e18));
            try this.sushiExitForCover(ids[i], part) {} catch (bytes memory reason) { emit StepSkipped(3, reason); }
        }
        uint256 idle = IERC20(AVKAT).balanceOf(address(this));
        paid_ = idle < amountAvkat_ ? idle : amountAvkat_;
        if (paid_ != 0) IERC20(AVKAT).safeTransfer(CUSTODY(), paid_);
        emit CoverPulled(amountAvkat_, paid_);
    }

    /// @dev Cover steps as self-calls so a failing position is skipped, not fatal.
    function charmExitForCover(address vault_, uint256 shares_) external {
        if (msg.sender != address(this)) revert NotCustody(msg.sender);
        (uint256 a0, uint256 a1) = _charmWithdraw(vault_, shares_, 0, 0);
        _toAvkat(IFarmCharm(vault_).token0(), a0);
        _toAvkat(IFarmCharm(vault_).token1(), a1);
    }

    function sushiExitForCover(uint256 tokenId_, uint128 liquidity_) external {
        if (msg.sender != address(this)) revert NotCustody(msg.sender);
        (,, address t0, address t1,,,,,,,,) = IFarmNpm(NPM).positions(tokenId_);
        (uint256 a0, uint256 a1) = _decrease(tokenId_, liquidity_, 0, 0);
        _toAvkat(t0, a0);
        _toAvkat(t1, a1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ---------------------------------------------------------------- internals

    function _increase(uint256 tokenId_, uint256 a0_, uint256 a1_, uint256 min0_, uint256 min1_) private {
        _requirePosition(tokenId_);
        bool wasStaked = isStaked[tokenId_];
        if (wasStaked) _unstake(tokenId_); // user: withdraw from the staker, add, re-stake
        (,, address t0, address t1,,,,,,,,) = IFarmNpm(NPM).positions(tokenId_);
        _approve(t0, NPM, a0_);
        _approve(t1, NPM, a1_);
        (uint128 liquidity, uint256 used0, uint256 used1) = IFarmNpm(NPM).increaseLiquidity(
            IFarmNpm.IncreaseLiquidityParams(tokenId_, a0_, a1_, min0_, min1_, block.timestamp)
        );
        _approve(t0, NPM, 0);
        _approve(t1, NPM, 0);
        if (wasStaked) _stake(tokenId_);
        emit LiquidityChanged(tokenId_, int256(uint256(liquidity)), used0, used1);
    }

    function _decrease(uint256 tokenId_, uint128 liquidity_, uint256 min0_, uint256 min1_)
        private returns (uint256 a0_, uint256 a1_)
    {
        _requirePosition(tokenId_);
        bool wasStaked = isStaked[tokenId_];
        if (wasStaked) _unstake(tokenId_);
        if (liquidity_ != 0) {
            IFarmNpm(NPM).decreaseLiquidity(
                IFarmNpm.DecreaseLiquidityParams(tokenId_, liquidity_, min0_, min1_, block.timestamp)
            );
        }
        (a0_, a1_) = _collect(tokenId_);
        (,,,,,,, uint128 left,,,,) = IFarmNpm(NPM).positions(tokenId_);
        if (wasStaked && left != 0) _stake(tokenId_);
        emit LiquidityChanged(tokenId_, -int256(uint256(liquidity_)), a0_, a1_);
    }

    function _collect(uint256 tokenId_) private returns (uint256, uint256) {
        return IFarmNpm(NPM).collect(IFarmNpm.CollectParams(tokenId_, address(this), type(uint128).max, type(uint128).max));
    }

    function _stake(uint256 tokenId_) private {
        IFarmNpm(NPM).approve(STAKER, tokenId_);
        IFarmStaker(STAKER).stake(tokenId_);
        isStaked[tokenId_] = true;
        emit Staked(tokenId_, true);
    }

    function _unstake(uint256 tokenId_) private {
        IFarmStaker(STAKER).unstake(tokenId_);
        isStaked[tokenId_] = false;
        emit Staked(tokenId_, false);
    }

    function _charmDeposit(address vault_, uint256 a0_, uint256 a1_, uint256 min0_, uint256 min1_) private returns (uint256 shares_) {
        if (!isCharmVaultAllowed[vault_]) revert CharmVaultNotAllowed(vault_);
        (address t0, address t1) = (IFarmCharm(vault_).token0(), IFarmCharm(vault_).token1());
        _approve(t0, vault_, a0_);
        _approve(t1, vault_, a1_);
        uint256 used0;
        uint256 used1;
        (shares_, used0, used1) = IFarmCharm(vault_).deposit(a0_, a1_, min0_, min1_, address(this));
        _approve(t0, vault_, 0);
        _approve(t1, vault_, 0);
        emit CharmDeposited(vault_, shares_, used0, used1);
    }

    function _charmWithdraw(address vault_, uint256 shares_, uint256 min0_, uint256 min1_) private returns (uint256 a0_, uint256 a1_) {
        if (!isCharmVaultAllowed[vault_]) revert CharmVaultNotAllowed(vault_);
        (a0_, a1_) = IFarmCharm(vault_).withdraw(shares_, min0_, min1_, address(this));
        emit CharmWithdrawn(vault_, shares_, a0_, a1_);
    }

    function _sellIdleTokens(uint256 amountAvkat_) private {
        address[] memory list = _tokens;
        for (uint256 i; i < list.length && _short(amountAvkat_) != 0; ++i) {
            if (list[i] == AVKAT) continue;
            _toAvkat(list[i], IERC20(list[i]).balanceOf(address(this)));
        }
    }

    function _toAvkat(address token_, uint256 amount_) private {
        if (token_ == AVKAT || amount_ == 0) return;
        try this.swapForHarvest(token_, amount_) {} catch (bytes memory reason) { emit StepSkipped(4, reason); }
    }

    function _swapIf(address tokenIn_, address tokenOut_, uint256 amountIn_) private returns (uint256) {
        return amountIn_ == 0 ? 0 : _swap(tokenIn_, tokenOut_, amountIn_, 0);
    }

    /// @dev Router v2 enforces max(its protected minimum, minOut_).
    function _swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minOut_) private returns (uint256 out_) {
        _approve(tokenIn_, ROUTER(), amountIn_);
        out_ = IFarmRouter(ROUTER()).swapExactInput(tokenIn_, tokenOut_, amountIn_, minOut_, address(this), block.timestamp);
        _approve(tokenIn_, ROUTER(), 0);
        emit Swapped(tokenIn_, tokenOut_, amountIn_, out_);
    }

    function _short(uint256 target_) private view returns (uint256) {
        uint256 idle = IERC20(AVKAT).balanceOf(address(this));
        return idle >= target_ ? 0 : target_ - idle;
    }

    /// @dev Fraction (WAD) of a holding worth `value_` to unwind for the current shortfall, with a small margin.
    function _fraction(uint256 target_, uint256 value_) private view returns (uint256) {
        uint256 f = Math.mulDiv(_short(target_), 1e18 * (BPS + PULL_MARGIN_BPS), value_ * BPS);
        return f > 1e18 ? 1e18 : f;
    }

    function _approve(address token_, address spender_, uint256 amount_) private {
        IERC20(token_).forceApprove(spender_, amount_);
    }

    function _requireToken(address token_) private view {
        if (tokenRefs[token_] == 0) revert TokenNotAllowed(token_);
    }

    function _requirePosition(uint256 tokenId_) private view {
        for (uint256 i; i < _positionIds.length; ++i) if (_positionIds[i] == tokenId_) return;
        revert UnknownPosition(tokenId_);
    }

    function _setOperator(address operator_, bool enabled_) private {
        if (operator_ == address(0)) revert InvalidAddress();
        isOperator[operator_] = enabled_;
        emit OperatorSet(operator_, enabled_);
    }

    function _addTokenRef(address token_) private {
        if (tokenRefs[token_]++ == 0) _tokens.push(token_);
    }

    function _removeTokenRef(address token_) private {
        if (tokenRefs[token_] == 0) return;
        if (--tokenRefs[token_] != 0) return;
        for (uint256 i; i < _tokens.length; ++i) {
            if (_tokens[i] == token_) {
                _tokens[i] = _tokens[_tokens.length - 1];
                _tokens.pop();
                return;
            }
        }
    }

    function _removeVault(address vault_) private {
        for (uint256 i; i < _charmVaults.length; ++i) {
            if (_charmVaults[i] == vault_) {
                _charmVaults[i] = _charmVaults[_charmVaults.length - 1];
                _charmVaults.pop();
                return;
            }
        }
    }

    function _removePosition(uint256 tokenId_) private {
        for (uint256 i; i < _positionIds.length; ++i) {
            if (_positionIds[i] == tokenId_) {
                _positionIds[i] = _positionIds[_positionIds.length - 1];
                _positionIds.pop();
                return;
            }
        }
    }
}

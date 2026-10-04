// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldAddrKeys, ICurveYieldConfigGate, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

interface ICySwapRouterV2 {
    function protectedQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 expectedNet, uint256 minimumNet);
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minNetAmountOut, address recipient, uint256 deadline)
        external returns (uint256 netOut);
}

struct RouterSwapV2EnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minNetAmountOut; // the plan's own floor (e.g. POL's NAV floor); the router also enforces its protected minimum
}

/// @notice Harvest sweep (runs in the vault inside RewardsClaimManager.claimRewards, after the Merkl claim left the
/// reward tokens in the vault): every listed reward token -> the vault asset through the router.
struct RouterSweepData {
    address[] tokens;
    address asset; // the vault's underlying (avKAT): skipped, and what everything is swapped into
    uint256 rewardBps; // keeper reward on what the sweep produced (governance gate)
    uint256 rewardCap;
    address rewardRecipient; // the executor (a granted transfer recipient), which forwards it to the caller
}

/// @title CurveYieldRouterSwapFuseV2 (SWAP_ROUTING_SPEC)
/// @notice Every vault swap through the swap router v2 (Sushi V3 and CurveYield DEX routes, 0.1% fee, protected
/// minimum). Stores no economic settings. Keeps the quote surface of the v1 swap fuse (quoteExactInput /
/// requiredInput and their view versions), computed from the router's protected quote, so the loop library and the
/// loop fuses work unchanged.
contract CurveYieldRouterSwapFuseV2 is IFuseCommon {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_SEARCH_ITERATIONS = 48;
    uint256 private constant MAX_SEARCH_EXPANSIONS = 12;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID; // where the reward recipient must be granted (3 << 160 | recipient)
    /// @notice Wired in the gate (`CurveYieldAddrKeys.SWAP_ROUTER`, GATE_CONFIG_SPEC §10).
    function ROUTER() public view returns (address) {
        return ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.SWAP_ROUTER);
    }
    uint256 public constant TYPE_RECIPIENT = 3;
    uint256 private constant BPS = 10_000;
    /// @notice USDC_SUPPLY_LOOP_SPEC: the admin share of every harvest (hard-set) and the vesting floor.
    uint256 public constant ADMIN_BPS = 1_000;
    uint256 public constant MIN_VEST_BPS = 1_000;

    event RouterSwapV2(address version, address tokenIn, address tokenOut, uint256 amountIn, uint256 netOut);
    event RewardsSwept(address version, uint256 assetOut, uint256 reward, uint256 toVesting);
    event RewardsSplit(address version, uint256 toAdmin, uint256 toVesting, uint256 toCustody);
    event RewardSweepSkipped(address version, address token, uint256 amount);

    error InvalidAmount();
    error UnexpectedDelta();
    error RequiredOutputUnavailable(uint256 required, uint256 available);
    error RecipientNotGranted(address recipient);
    error NoRewardsClaimManager();
    error InvalidVestBps(uint256 vestBps);
    error NoAdminReceiver();
    /// @notice The governance gate (wiring anchor, GATE_CONFIG_SPEC §10).
    address public immutable GATE;

    constructor(uint256 marketId_, uint256 substrateMarketId_, address gate_) {
        if (gate_ == address(0)) revert InvalidAmount();
        GATE = gate_;
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    /// @notice Vault context: swaps through the router; the output must reach max(router minimum, the plan's floor).
    function enter(RouterSwapV2EnterData calldata d_) external returns (uint256 netOut_) {
        if (d_.amountIn == 0 || d_.tokenIn == d_.tokenOut) revert InvalidAmount();
        IERC20 input = IERC20(d_.tokenIn);
        IERC20 output = IERC20(d_.tokenOut);
        uint256 inBefore = input.balanceOf(address(this));
        uint256 outBefore = output.balanceOf(address(this));
        input.forceApprove(ROUTER(), d_.amountIn);
        netOut_ = ICySwapRouterV2(ROUTER()).swapExactInput(
            d_.tokenIn, d_.tokenOut, d_.amountIn, d_.minNetAmountOut, address(this), block.timestamp
        );
        input.forceApprove(ROUTER(), 0);
        if (inBefore - input.balanceOf(address(this)) != d_.amountIn ||
            output.balanceOf(address(this)) - outBefore != netOut_) revert UnexpectedDelta();
        emit RouterSwapV2(VERSION, d_.tokenIn, d_.tokenOut, d_.amountIn, netOut_);
    }

    /// @notice Harvest step 2 (after the Merkl claim): swaps each listed reward token into the vault asset (each through
    /// the router, protected minimum; a token without a route, e.g. an LP token, is skipped), pays the keeper reward (at most rewardBps of
    /// the output and rewardCap) and splits the rest: 10% admin, `harvest.vestBps` to the rewards claim manager to vest, the
    /// remainder to the revenue custody (USDC_SUPPLY_LOOP_SPEC; KAT is accepted like any other reward token).
    function sweep(RouterSweepData calldata d_) external returns (uint256 assetOut_, uint256 reward_) {
        address rcm = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rcm == address(0)) revert NoRewardsClaimManager();
        for (uint256 i; i < d_.tokens.length; ++i) {
            address token = d_.tokens[i];
            if (token == d_.asset) continue;
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) continue;
            IERC20(token).forceApprove(ROUTER(), amount);
            try ICySwapRouterV2(ROUTER()).swapExactInput(token, d_.asset, amount, 0, address(this), block.timestamp) returns (uint256 out) {
                assetOut_ += out;
            } catch {
                emit RewardSweepSkipped(VERSION, token, amount);
            }
            IERC20(token).forceApprove(ROUTER(), 0);
        }
        reward_ = assetOut_ * d_.rewardBps / BPS;
        if (reward_ > d_.rewardCap) reward_ = d_.rewardCap;
        if (reward_ != 0) {
            if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(
                SUBSTRATE_MARKET_ID, bytes32((TYPE_RECIPIENT << 160) | uint256(uint160(d_.rewardRecipient)))
            )) revert RecipientNotGranted(d_.rewardRecipient);
            IERC20(d_.asset).safeTransfer(d_.rewardRecipient, reward_);
        }
        // USDC_SUPPLY_LOOP_SPEC: 10% admin (hard-set), vestBps to the rewards claim manager, the rest to the custody
        uint256 net = assetOut_ - reward_;
        if (net == 0) return (assetOut_, reward_);
        bytes32[] memory k = new bytes32[](1);
        k[0] = K.HARVEST_VEST_BPS;
        uint256 vestBps = ICurveYieldConfigGate(GATE).getMany(k)[0];
        if (vestBps < MIN_VEST_BPS || vestBps > BPS - ADMIN_BPS) revert InvalidVestBps(vestBps);
        address admin = ICurveYieldConfigGate(GATE).adminReceiver();
        address custody = ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.REVENUE_CUSTODY);
        if (admin == address(0)) revert NoAdminReceiver();
        uint256 toAdmin = net * ADMIN_BPS / BPS;
        uint256 toVesting = net * vestBps / BPS;
        uint256 toCustody = net - toAdmin - toVesting;
        IERC20(d_.asset).safeTransfer(admin, toAdmin);
        IERC20(d_.asset).safeTransfer(rcm, toVesting);
        IERC20(d_.asset).safeTransfer(custody, toCustody);
        emit RewardsSwept(VERSION, assetOut_, reward_, toVesting);
        emit RewardsSplit(VERSION, toAdmin, toVesting, toCustody);
    }

    // ---------------------------------------------------------------- quotes (called on this contract directly)

    function quoteExactInput(address tokenIn_, address tokenOut_, uint256 amountIn_)
        external view returns (uint256 expectedNet_, uint256 minimumNet_)
    {
        return _quote(tokenIn_, tokenOut_, amountIn_);
    }

    function quoteExactInputView(address tokenIn_, address tokenOut_, uint256 amountIn_)
        external view returns (uint256 expectedNet_, uint256 minimumNet_)
    {
        return _quote(tokenIn_, tokenOut_, amountIn_);
    }

    /// @notice Smallest input whose protected minimum output reaches `requiredNetOut_` (at most `maximumInput_`).
    function requiredInput(address tokenIn_, address tokenOut_, uint256 requiredNetOut_, uint256 maximumInput_)
        external view returns (uint256)
    {
        return _requiredInput(tokenIn_, tokenOut_, requiredNetOut_, maximumInput_);
    }

    function requiredInputView(address tokenIn_, address tokenOut_, uint256 requiredNetOut_, uint256 maximumInput_)
        external view returns (uint256)
    {
        return _requiredInput(tokenIn_, tokenOut_, requiredNetOut_, maximumInput_);
    }

    function _quote(address tokenIn_, address tokenOut_, uint256 amountIn_) private view returns (uint256, uint256) {
        if (amountIn_ == 0) return (0, 0);
        return ICySwapRouterV2(ROUTER()).protectedQuote(tokenIn_, tokenOut_, amountIn_);
    }

    function _requiredInput(address tokenIn_, address tokenOut_, uint256 requiredNetOut_, uint256 maximumInput_)
        private view returns (uint256 input_)
    {
        if (requiredNetOut_ == 0) return 0;
        if (maximumInput_ == 0) revert InvalidAmount();
        (, uint256 maxOut) = _quote(tokenIn_, tokenOut_, maximumInput_);
        if (maxOut < requiredNetOut_) revert RequiredOutputUnavailable(requiredNetOut_, maxOut);
        uint256 low = 1;
        uint256 high = maximumInput_ * requiredNetOut_ / maxOut + 1;
        if (high > maximumInput_) high = maximumInput_;
        (, uint256 highOut) = _quote(tokenIn_, tokenOut_, high);
        for (uint256 i; i < MAX_SEARCH_EXPANSIONS && highOut < requiredNetOut_; ++i) {
            low = high + 1;
            uint256 expanded = high + high / 8 + 1;
            high = expanded < maximumInput_ ? expanded : maximumInput_;
            (, highOut) = _quote(tokenIn_, tokenOut_, high);
        }
        if (highOut < requiredNetOut_) revert RequiredOutputUnavailable(requiredNetOut_, highOut);
        for (uint256 i; i < MAX_SEARCH_ITERATIONS && low < high; ++i) {
            uint256 mid = low + (high - low) / 2;
            (, uint256 out) = _quote(tokenIn_, tokenOut_, mid);
            if (out >= requiredNetOut_) high = mid;
            else low = mid + 1;
        }
        input_ = high;
    }
}

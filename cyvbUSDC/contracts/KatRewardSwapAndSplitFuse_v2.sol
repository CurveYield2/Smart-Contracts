// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20CyvbUSDCV2 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Exact public swap surface of CurveYieldSushiV3FeeRouter on Katana.
interface ICurveYieldSushiV3FeeRouterV2 {
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

interface ICurveYieldRewardsClaimManagerV2 {
    struct VestingData {
        uint32 vestingTime;
        uint32 updateBalanceTimestamp;
        uint128 transferredTokens;
        uint128 lastUpdateBalance;
    }

    function balanceOf() external view returns (uint256);
    function getVestingData() external view returns (VestingData memory);
    function updateBalance() external;
}

interface ICurveYieldPlasmaVaultRewardsConfigV2 {
    function getRewardsClaimManagerAddress() external view returns (address);
}

/// @title KatRewardSwapAndSplitFuse_v2
/// @notice Reward fuse for CurveYield USDC (cyvbUSDC) on Katana.
/// @dev Flow:
///      1. MerklClaimFuse claims KAT to the Plasma Vault while KAT is included in
///         doNotTransferToRewardManager_.
///      2. RewardsClaimManager executes this fuse via PlasmaVault.claimRewards().
///      3. This fuse swaps the complete KAT balance through the existing
///         CurveYieldSushiV3FeeRouter.
///      4. Exactly the router's returned net vbUSDC output is split:
///         70% RewardsClaimManager / 30% CurveYield admin fee receiver.
///      5. RewardsClaimManager.updateBalance() starts/rebases normal IPOR vesting
///         for the 70% user-reward share.
///
///      The fuse executes by delegatecall, so address(this) is the Plasma Vault.
///      It has no mutable storage and cannot split pre-existing vbUSDC principal.
contract KatRewardSwapAndSplitFuse_v2 {
    uint256 public constant BPS = 10_000;
    uint256 public constant REWARDS_MANAGER_BPS = 7_000;
    uint256 public constant ADMIN_BPS = 3_000;
    uint256 public constant EXPECTED_VESTING_TIME = 15 days;

    address public constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address public constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address public constant ADMIN_FEE_RECEIVER = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    bytes32 private constant SKIP_ZERO_BALANCE = keccak256("ZERO_BALANCE");
    bytes32 private constant SKIP_MISSING_ROUTE = keccak256("MISSING_ROUTE");

    address public immutable VERSION;
    address public immutable VAULT;
    address public immutable MANAGER;
    address public immutable ROUTER;

    error InvalidAddress();
    error WrongContext();
    error DeadlineExpired();
    error UnexpectedInputDelta();
    error UnexpectedOutputDelta();
    error WrongVestingPeriod();
    error VestingUpdateInvariant();
    error TokenOperationFailed(address token, bytes4 selector);

    event KatRewardSwappedAndSplit(
        address indexed version,
        uint256 katIn,
        uint256 netVbUsdc,
        uint256 rewardsManagerAmount,
        uint256 adminAmount,
        address indexed rewardsClaimManager,
        address indexed adminFeeReceiver
    );

    event KatRewardSkipped(address indexed version, bytes32 indexed reason);

    constructor(address vault_, address manager_, address router_) {
        if (vault_ == address(0) || manager_ == address(0) || router_ == address(0)) {
            revert InvalidAddress();
        }
        if (vault_.code.length == 0 || manager_.code.length == 0 || router_.code.length == 0) {
            revert InvalidAddress();
        }

        VERSION = address(this);
        VAULT = vault_;
        MANAGER = manager_;
        ROUTER = router_;
    }

    /// @notice Converts all KAT currently held by the Plasma Vault and distributes net vbUSDC.
    /// @param minNetAmountOut_ Caller-provided floor for net vbUSDC after router fees.
    ///        The existing router independently enforces the greater of this floor and its
    ///        TWAP-derived minimum.
    /// @param deadline_ Router deadline.
    function sweepKatRewards(
        uint256 minNetAmountOut_,
        uint256 deadline_
    ) external returns (uint256 netVbUsdc, uint256 rewardsManagerAmount, uint256 adminAmount) {
        _requireRewardContext();
        if (block.timestamp > deadline_) revert DeadlineExpired();

        uint256 amountIn = IERC20CyvbUSDCV2(KAT).balanceOf(VAULT);
        if (amountIn == 0) {
            emit KatRewardSkipped(VERSION, SKIP_ZERO_BALANCE);
            return (0, 0, 0);
        }

        if (ICurveYieldSushiV3FeeRouterV2(ROUTER).routeFor(KAT, VB_USDC).length == 0) {
            emit KatRewardSkipped(VERSION, SKIP_MISSING_ROUTE);
            return (0, 0, 0);
        }

        ICurveYieldRewardsClaimManagerV2 manager = ICurveYieldRewardsClaimManagerV2(MANAGER);
        ICurveYieldRewardsClaimManagerV2.VestingData memory beforeVesting = manager.getVestingData();
        if (beforeVesting.vestingTime != EXPECTED_VESTING_TIME) revert WrongVestingPeriod();

        uint256 vestedBefore = manager.balanceOf();
        uint256 managerBefore = IERC20CyvbUSDCV2(VB_USDC).balanceOf(MANAGER);
        uint256 vaultVbUsdcBefore = IERC20CyvbUSDCV2(VB_USDC).balanceOf(VAULT);

        _forceApprove(KAT, ROUTER, amountIn);

        try ICurveYieldSushiV3FeeRouterV2(ROUTER).swapExactInput(
            KAT,
            VB_USDC,
            amountIn,
            minNetAmountOut_,
            VAULT,
            deadline_
        ) returns (uint256 reportedNetVbUsdc) {
            _forceApprove(KAT, ROUTER, 0);

            if (IERC20CyvbUSDCV2(KAT).balanceOf(VAULT) != 0) revert UnexpectedInputDelta();

            uint256 vaultVbUsdcAfter = IERC20CyvbUSDCV2(VB_USDC).balanceOf(VAULT);
            if (
                reportedNetVbUsdc == 0 ||
                vaultVbUsdcAfter < vaultVbUsdcBefore ||
                vaultVbUsdcAfter - vaultVbUsdcBefore != reportedNetVbUsdc ||
                reportedNetVbUsdc < minNetAmountOut_
            ) revert UnexpectedOutputDelta();

            netVbUsdc = reportedNetVbUsdc;

            // Round integer dust to users, never to admin.
            adminAmount = (netVbUsdc * ADMIN_BPS) / BPS;
            rewardsManagerAmount = netVbUsdc - adminAmount;

            _safeTransfer(VB_USDC, MANAGER, rewardsManagerAmount);
            if (adminAmount != 0) {
                _safeTransfer(VB_USDC, ADMIN_FEE_RECEIVER, adminAmount);
            }

            manager.updateBalance();
            _verifyVestingUpdate(manager, managerBefore, vestedBefore, rewardsManagerAmount);

            emit KatRewardSwappedAndSplit(
                VERSION,
                amountIn,
                netVbUsdc,
                rewardsManagerAmount,
                adminAmount,
                MANAGER,
                ADMIN_FEE_RECEIVER
            );

            return (netVbUsdc, rewardsManagerAmount, adminAmount);
        } catch (bytes memory reason) {
            _forceApprove(KAT, ROUTER, 0);
            emit KatRewardSkipped(VERSION, keccak256(reason));
            return (0, 0, 0);
        }
    }

    function _requireRewardContext() private view {
        if (
            address(this) != VAULT ||
            msg.sender != MANAGER ||
            ICurveYieldPlasmaVaultRewardsConfigV2(VAULT).getRewardsClaimManagerAddress() != MANAGER
        ) revert WrongContext();
    }

    /// @dev Mirrors the invariant checks used by the existing CurveYield reward sweep fuse.
    function _verifyVestingUpdate(
        ICurveYieldRewardsClaimManagerV2 manager_,
        uint256 managerBefore_,
        uint256 vestedBefore_,
        uint256 managerCredit_
    ) private view {
        uint256 beforeTransfer = managerBefore_ + managerCredit_;
        if (vestedBefore_ > beforeTransfer) revert VestingUpdateInvariant();

        uint256 expectedManagerBalance = beforeTransfer - vestedBefore_;
        uint256 managerAfter = IERC20CyvbUSDCV2(VB_USDC).balanceOf(MANAGER);
        ICurveYieldRewardsClaimManagerV2.VestingData memory afterVesting = manager_.getVestingData();

        if (
            afterVesting.vestingTime != EXPECTED_VESTING_TIME ||
            managerAfter != expectedManagerBalance ||
            afterVesting.lastUpdateBalance != managerAfter ||
            afterVesting.transferredTokens != 0 ||
            afterVesting.updateBalanceTimestamp != block.timestamp ||
            manager_.balanceOf() != 0
        ) revert VestingUpdateInvariant();
    }

    function _forceApprove(address token_, address spender_, uint256 amount_) private {
        bytes memory approveData = abi.encodeWithSelector(IERC20CyvbUSDCV2.approve.selector, spender_, amount_);

        if (!_callOptionalReturnBool(token_, approveData)) {
            _callOptionalReturn(
                token_,
                abi.encodeWithSelector(IERC20CyvbUSDCV2.approve.selector, spender_, 0)
            );
            _callOptionalReturn(token_, approveData);
        }
    }

    function _safeTransfer(address token_, address to_, uint256 amount_) private {
        _callOptionalReturn(
            token_,
            abi.encodeWithSelector(IERC20CyvbUSDCV2.transfer.selector, to_, amount_)
        );
    }

    function _callOptionalReturn(address token_, bytes memory data_) private {
        (bool success, bytes memory returndata) = token_.call(data_);
        if (!success || (returndata.length != 0 && !abi.decode(returndata, (bool)))) {
            bytes4 selector;
            assembly {
                selector := mload(add(data_, 0x20))
            }
            revert TokenOperationFailed(token_, selector);
        }
    }

    function _callOptionalReturnBool(address token_, bytes memory data_) private returns (bool) {
        (bool success, bytes memory returndata) = token_.call(data_);
        return success && (returndata.length == 0 || (returndata.length >= 32 && abi.decode(returndata, (bool))));
    }
}

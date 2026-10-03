// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal ERC20 surface required by the CurveYield reward sweep fuse.
interface IERC20CyvbUSDCV1 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Exact router surface used by the existing CurveYield Katana reward sweep system.
interface ICurveYieldRewardFeeRouterCyvbUSDCV1 {
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

interface ICurveYieldRewardsClaimManagerCyvbUSDCV1 {
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

interface ICurveYieldPlasmaVaultRewardsConfigCyvbUSDCV1 {
    function getRewardsClaimManagerAddress() external view returns (address);
}

/// @title KatRewardSwapAndSplitFuse_v1
/// @notice CurveYield Katana reward fuse for cyvbUSDC.
/// @dev This is deliberately based on the verified CurveYieldMerklRewardSweepFuse used by
///      reference vault 0xEd83daf48429cfb2C650Fd721b9241e180fd4548. It uses the same
///      CurveYield reward-fee router interface and is intended to use the same deployed router.
///      Execution is by delegatecall from the Plasma Vault through RewardsClaimManager.claimRewards().
contract KatRewardSwapAndSplitFuse_v1 {
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
    error VestingNotStarted();
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

    /// @param vault_ cyvbUSDC Plasma Vault.
    /// @param manager_ RewardsClaimManager created by the official IPOR Fusion factory.
    /// @param router_ Existing CurveYield reward-fee router. For the reference Katana system this is
    ///        0x346f02528aD59D1B57315b6d67FD6a43559a87Bb.
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

    /// @notice Swaps the complete KAT reward balance currently held by the vault into vbUSDC,
    ///         sends 70% of the net vbUSDC to RewardsClaimManager for normal IPOR vesting,
    ///         and sends 30% directly to the CurveYield admin fee receiver.
    /// @param minNetAmountOut_ Minimum acceptable net vbUSDC output from the existing router.
    /// @param deadline_ Swap deadline passed unchanged to the existing router.
    function sweepKatRewards(
        uint256 minNetAmountOut_,
        uint256 deadline_
    ) external returns (uint256 netVbUsdc, uint256 rewardsManagerAmount, uint256 adminAmount) {
        _requireRewardContext();
        if (block.timestamp > deadline_) revert DeadlineExpired();

        uint256 amountIn = IERC20CyvbUSDCV1(KAT).balanceOf(VAULT);
        if (amountIn == 0) {
            emit KatRewardSkipped(VERSION, SKIP_ZERO_BALANCE);
            return (0, 0, 0);
        }

        if (ICurveYieldRewardFeeRouterCyvbUSDCV1(ROUTER).routeFor(KAT, VB_USDC).length == 0) {
            emit KatRewardSkipped(VERSION, SKIP_MISSING_ROUTE);
            return (0, 0, 0);
        }

        ICurveYieldRewardsClaimManagerCyvbUSDCV1 manager =
            ICurveYieldRewardsClaimManagerCyvbUSDCV1(MANAGER);
        ICurveYieldRewardsClaimManagerCyvbUSDCV1.VestingData memory beforeVesting =
            manager.getVestingData();

        if (beforeVesting.vestingTime != EXPECTED_VESTING_TIME) revert WrongVestingPeriod();

        uint256 vestedBefore = manager.balanceOf();
        uint256 managerBefore = IERC20CyvbUSDCV1(VB_USDC).balanceOf(MANAGER);
        uint256 outputBefore = IERC20CyvbUSDCV1(VB_USDC).balanceOf(VAULT);

        _forceApprove(KAT, ROUTER, amountIn);

        try ICurveYieldRewardFeeRouterCyvbUSDCV1(ROUTER).swapExactInput(
            KAT,
            VB_USDC,
            amountIn,
            minNetAmountOut_,
            VAULT,
            deadline_
        ) returns (uint256 reportedNetVbUsdc) {
            _forceApprove(KAT, ROUTER, 0);

            if (IERC20CyvbUSDCV1(KAT).balanceOf(VAULT) != 0) revert UnexpectedInputDelta();

            uint256 outputAfter = IERC20CyvbUSDCV1(VB_USDC).balanceOf(VAULT);
            if (
                reportedNetVbUsdc == 0 ||
                outputAfter < outputBefore ||
                outputAfter - outputBefore != reportedNetVbUsdc ||
                reportedNetVbUsdc < minNetAmountOut_
            ) revert UnexpectedOutputDelta();

            netVbUsdc = reportedNetVbUsdc;

            // Round any integer dust to the RewardsClaimManager, never to the admin.
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
            ICurveYieldPlasmaVaultRewardsConfigCyvbUSDCV1(VAULT).getRewardsClaimManagerAddress() != MANAGER
        ) revert WrongContext();
    }

    function _verifyVestingUpdate(
        ICurveYieldRewardsClaimManagerCyvbUSDCV1 manager_,
        uint256 managerBefore_,
        uint256 vestedBefore_,
        uint256 managerCredit_
    ) private view {
        uint256 beforeTransfer = managerBefore_ + managerCredit_;
        if (vestedBefore_ > beforeTransfer) revert VestingNotStarted();

        uint256 expectedManagerBalance = beforeTransfer - vestedBefore_;
        uint256 managerAfter = IERC20CyvbUSDCV1(VB_USDC).balanceOf(MANAGER);
        ICurveYieldRewardsClaimManagerCyvbUSDCV1.VestingData memory afterVesting =
            manager_.getVestingData();

        if (
            afterVesting.vestingTime != EXPECTED_VESTING_TIME ||
            managerAfter != expectedManagerBalance ||
            afterVesting.lastUpdateBalance != managerAfter ||
            afterVesting.transferredTokens != 0 ||
            afterVesting.updateBalanceTimestamp != block.timestamp ||
            manager_.balanceOf() != 0
        ) revert VestingNotStarted();
    }

    /// @dev Equivalent operational behavior to SafeERC20.forceApprove without importing external dependencies.
    function _forceApprove(address token_, address spender_, uint256 amount_) private {
        bytes memory callData = abi.encodeWithSelector(IERC20CyvbUSDCV1.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, callData)) {
            _callOptionalReturn(token_, abi.encodeWithSelector(IERC20CyvbUSDCV1.approve.selector, spender_, 0));
            _callOptionalReturn(token_, callData);
        }
    }

    function _safeTransfer(address token_, address to_, uint256 amount_) private {
        _callOptionalReturn(
            token_,
            abi.encodeWithSelector(IERC20CyvbUSDCV1.transfer.selector, to_, amount_)
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

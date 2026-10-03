// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20CyvbUSDCV3 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICurveYieldSushiV3FeeRouterV3 {
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

interface ICurveYieldRewardsClaimManagerV3 {
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

interface ICurveYieldPlasmaVaultRewardsConfigV3 {
    function getRewardsClaimManagerAddress() external view returns (address);
}

contract KatRewardSwapAndSplitFuse_v3 {
    uint256 public constant BPS = 10_000;
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

    struct RewardSnapshot {
        uint256 katIn;
        uint256 vaultVbUsdcBefore;
        uint256 managerVbUsdcBefore;
        uint256 vestedBefore;
    }

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
        if (vault_ == address(0) || manager_ == address(0) || router_ == address(0)) revert InvalidAddress();
        if (vault_.code.length == 0 || manager_.code.length == 0 || router_.code.length == 0) revert InvalidAddress();
        VERSION = address(this);
        VAULT = vault_;
        MANAGER = manager_;
        ROUTER = router_;
    }

    function sweepKatRewards(
        uint256 minNetAmountOut_,
        uint256 deadline_
    ) external returns (uint256 netVbUsdc, uint256 rewardsManagerAmount, uint256 adminAmount) {
        _requireRewardContext();
        if (block.timestamp > deadline_) revert DeadlineExpired();

        RewardSnapshot memory snapshot = _snapshot();
        if (snapshot.katIn == 0) {
            emit KatRewardSkipped(VERSION, SKIP_ZERO_BALANCE);
            return (0, 0, 0);
        }
        if (!_routeExists()) {
            emit KatRewardSkipped(VERSION, SKIP_MISSING_ROUTE);
            return (0, 0, 0);
        }

        netVbUsdc = _swap(snapshot, minNetAmountOut_, deadline_);
        if (netVbUsdc == 0) return (0, 0, 0);

        (rewardsManagerAmount, adminAmount) = _splitAndVest(snapshot, netVbUsdc);

        emit KatRewardSwappedAndSplit(
            VERSION,
            snapshot.katIn,
            netVbUsdc,
            rewardsManagerAmount,
            adminAmount,
            MANAGER,
            ADMIN_FEE_RECEIVER
        );
    }

    function _snapshot() private view returns (RewardSnapshot memory snapshot) {
        ICurveYieldRewardsClaimManagerV3 manager = ICurveYieldRewardsClaimManagerV3(MANAGER);
        ICurveYieldRewardsClaimManagerV3.VestingData memory vesting = manager.getVestingData();
        if (vesting.vestingTime != EXPECTED_VESTING_TIME) revert WrongVestingPeriod();

        snapshot.katIn = IERC20CyvbUSDCV3(KAT).balanceOf(VAULT);
        snapshot.vaultVbUsdcBefore = IERC20CyvbUSDCV3(VB_USDC).balanceOf(VAULT);
        snapshot.managerVbUsdcBefore = IERC20CyvbUSDCV3(VB_USDC).balanceOf(MANAGER);
        snapshot.vestedBefore = manager.balanceOf();
    }

    function _routeExists() private view returns (bool) {
        return ICurveYieldSushiV3FeeRouterV3(ROUTER).routeFor(KAT, VB_USDC).length != 0;
    }

    function _swap(
        RewardSnapshot memory snapshot_,
        uint256 minNetAmountOut_,
        uint256 deadline_
    ) private returns (uint256 netVbUsdc) {
        _forceApprove(KAT, ROUTER, snapshot_.katIn);

        try ICurveYieldSushiV3FeeRouterV3(ROUTER).swapExactInput(
            KAT,
            VB_USDC,
            snapshot_.katIn,
            minNetAmountOut_,
            VAULT,
            deadline_
        ) returns (uint256 reportedNetVbUsdc) {
            _forceApprove(KAT, ROUTER, 0);
            _verifySwapDeltas(snapshot_, reportedNetVbUsdc, minNetAmountOut_);
            return reportedNetVbUsdc;
        } catch (bytes memory reason) {
            _forceApprove(KAT, ROUTER, 0);
            emit KatRewardSkipped(VERSION, keccak256(reason));
            return 0;
        }
    }

    function _verifySwapDeltas(
        RewardSnapshot memory snapshot_,
        uint256 reportedNetVbUsdc_,
        uint256 minNetAmountOut_
    ) private view {
        if (IERC20CyvbUSDCV3(KAT).balanceOf(VAULT) != 0) revert UnexpectedInputDelta();

        uint256 vaultVbUsdcAfter = IERC20CyvbUSDCV3(VB_USDC).balanceOf(VAULT);
        if (
            reportedNetVbUsdc_ == 0 ||
            vaultVbUsdcAfter < snapshot_.vaultVbUsdcBefore ||
            vaultVbUsdcAfter - snapshot_.vaultVbUsdcBefore != reportedNetVbUsdc_ ||
            reportedNetVbUsdc_ < minNetAmountOut_
        ) revert UnexpectedOutputDelta();
    }

    function _splitAndVest(
        RewardSnapshot memory snapshot_,
        uint256 netVbUsdc_
    ) private returns (uint256 rewardsManagerAmount, uint256 adminAmount) {
        adminAmount = (netVbUsdc_ * ADMIN_BPS) / BPS;
        rewardsManagerAmount = netVbUsdc_ - adminAmount;

        _safeTransfer(VB_USDC, MANAGER, rewardsManagerAmount);
        if (adminAmount != 0) _safeTransfer(VB_USDC, ADMIN_FEE_RECEIVER, adminAmount);

        ICurveYieldRewardsClaimManagerV3 manager = ICurveYieldRewardsClaimManagerV3(MANAGER);
        manager.updateBalance();
        _verifyVestingUpdate(manager, snapshot_.managerVbUsdcBefore, snapshot_.vestedBefore, rewardsManagerAmount);
    }

    function _requireRewardContext() private view {
        if (
            address(this) != VAULT ||
            msg.sender != MANAGER ||
            ICurveYieldPlasmaVaultRewardsConfigV3(VAULT).getRewardsClaimManagerAddress() != MANAGER
        ) revert WrongContext();
    }

    function _verifyVestingUpdate(
        ICurveYieldRewardsClaimManagerV3 manager_,
        uint256 managerBefore_,
        uint256 vestedBefore_,
        uint256 managerCredit_
    ) private view {
        uint256 beforeTransfer = managerBefore_ + managerCredit_;
        if (vestedBefore_ > beforeTransfer) revert VestingUpdateInvariant();

        uint256 expectedManagerBalance = beforeTransfer - vestedBefore_;
        uint256 managerAfter = IERC20CyvbUSDCV3(VB_USDC).balanceOf(MANAGER);
        ICurveYieldRewardsClaimManagerV3.VestingData memory afterVesting = manager_.getVestingData();

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
        bytes memory approveData = abi.encodeWithSelector(IERC20CyvbUSDCV3.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, approveData)) {
            _callOptionalReturn(token_, abi.encodeWithSelector(IERC20CyvbUSDCV3.approve.selector, spender_, 0));
            _callOptionalReturn(token_, approveData);
        }
    }

    function _safeTransfer(address token_, address to_, uint256 amount_) private {
        _callOptionalReturn(token_, abi.encodeWithSelector(IERC20CyvbUSDCV3.transfer.selector, to_, amount_));
    }

    function _callOptionalReturn(address token_, bytes memory data_) private {
        (bool success, bytes memory returndata) = token_.call(data_);
        if (!success || (returndata.length != 0 && !abi.decode(returndata, (bool)))) {
            bytes4 selector;
            assembly { selector := mload(add(data_, 0x20)) }
            revert TokenOperationFailed(token_, selector);
        }
    }

    function _callOptionalReturnBool(address token_, bytes memory data_) private returns (bool) {
        (bool success, bytes memory returndata) = token_.call(data_);
        return success && (returndata.length == 0 || (returndata.length >= 32 && abi.decode(returndata, (bool))));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal ERC20 interface used by the reward-processing fuse.
interface IERC20CyvbUSDCV1 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice The Plasma Vault governance getter used while this fuse executes by delegatecall.
/// @dev address(this) is the Plasma Vault during reward-fuse execution.
interface IPlasmaVaultRewardsViewV1 {
    function getRewardsClaimManagerAddress() external view returns (address);
}

/// @notice Same ABI shape as IPOR UniversalTokenSwapperData.
struct UniversalTokenSwapperDataCyvbUSDCV1 {
    address[] targets;
    bytes[] data;
}

/// @notice Same ABI shape as IPOR UniversalTokenSwapperEnterData.
struct UniversalTokenSwapperEnterDataCyvbUSDCV1 {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    UniversalTokenSwapperDataCyvbUSDCV1 data;
}

/// @notice Minimal interface for the existing IPOR UniversalTokenSwapperFuse.
/// @dev The implementation is invoked with delegatecall so all balance changes occur in the Plasma Vault context.
interface IUniversalTokenSwapperFuseCyvbUSDCV1 {
    function enter(
        UniversalTokenSwapperEnterDataCyvbUSDCV1 memory data_
    ) external returns (address tokenIn, address tokenOut, uint256 tokenInDelta, uint256 tokenOutDelta);
}

/// @title KatRewardSwapAndSplitFuse_v1
/// @notice Converts KAT rewards already held by a Katana IPOR Fusion Plasma Vault into vbUSDC
///         through the vault's existing UniversalTokenSwapperFuse, then distributes only the newly
///         created vbUSDC as 70% RewardsClaimManager / 30% CurveYield admin fee receiver.
/// @dev Intended to be installed as a reward fuse and executed through RewardsClaimManager.claimRewards().
///      PlasmaVault.claimRewards() delegatecalls this fuse, therefore address(this) is the Plasma Vault.
///      This contract intentionally contains no mutable storage.
contract KatRewardSwapAndSplitFuse_v1 {
    uint256 public constant BPS = 10_000;
    uint256 public constant REWARDS_MANAGER_BPS = 7_000;
    uint256 public constant ADMIN_BPS = 3_000;

    /// @dev Official Katana KAT.
    address public constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;

    /// @dev Katana USDC / vbUSDC.
    address public constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;

    /// @dev Receives every CurveYield-controlled fee stream, including 30% of converted KAT rewards.
    address public constant ADMIN_FEE_RECEIVER = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    /// @notice Address of this deployed fuse instance.
    address public immutable VERSION;

    /// @notice Existing UniversalTokenSwapperFuse copied from the reference CurveYield Katana vault.
    address public immutable UNIVERSAL_SWAPPER_FUSE;

    error ZeroAddress();
    error InvalidSwapperFuse(address fuse);
    error NoKatRewards();
    error AmountExceedsKatBalance(uint256 requested, uint256 available);
    error SwapDelegateCallFailed(bytes reason);
    error NoVbUsdcReceived();
    error RewardsClaimManagerZeroAddress();
    error TokenTransferFailed(address token, address to, uint256 amount);

    event KatRewardsConvertedAndSplit(
        address indexed version,
        uint256 katIn,
        uint256 vbUsdcOut,
        uint256 rewardsManagerAmount,
        uint256 adminAmount,
        address indexed rewardsClaimManager,
        address indexed adminFeeReceiver
    );

    /// @param universalSwapperFuse_ The same deployed UniversalTokenSwapperFuse used by the reference vault.
    constructor(address universalSwapperFuse_) {
        if (universalSwapperFuse_ == address(0)) revert ZeroAddress();
        if (universalSwapperFuse_.code.length == 0) revert InvalidSwapperFuse(universalSwapperFuse_);

        VERSION = address(this);
        UNIVERSAL_SWAPPER_FUSE = universalSwapperFuse_;
    }

    /// @notice Swap KAT rewards held by the Plasma Vault into vbUSDC and split the swap output 70/30.
    /// @param amountIn_ KAT to swap. Pass 0 to process the vault's entire current KAT balance.
    /// @param minAmountOut_ Minimum vbUSDC output enforced by the existing IPOR swap fuse.
    /// @param swapData_ Existing router/DEX targets and calldata. The delegated IPOR fuse independently
    ///        verifies the tokens, targets and configured slippage against market 12 substrates.
    /// @return vbUsdcOut Amount of newly-created vbUSDC from this call.
    /// @return rewardsManagerAmount Amount transferred to the RewardsClaimManager.
    /// @return adminAmount Amount transferred to ADMIN_FEE_RECEIVER.
    function swapAndSplit(
        uint256 amountIn_,
        uint256 minAmountOut_,
        UniversalTokenSwapperDataCyvbUSDCV1 calldata swapData_
    ) external returns (uint256 vbUsdcOut, uint256 rewardsManagerAmount, uint256 adminAmount) {
        uint256 katBalance = IERC20CyvbUSDCV1(KAT).balanceOf(address(this));
        if (katBalance == 0) revert NoKatRewards();

        uint256 amountIn = amountIn_ == 0 ? katBalance : amountIn_;
        if (amountIn > katBalance) revert AmountExceedsKatBalance(amountIn, katBalance);

        uint256 vbUsdcBefore = IERC20CyvbUSDCV1(VB_USDC).balanceOf(address(this));

        UniversalTokenSwapperEnterDataCyvbUSDCV1 memory swapParams =
            UniversalTokenSwapperEnterDataCyvbUSDCV1({
                tokenIn: KAT,
                tokenOut: VB_USDC,
                amountIn: amountIn,
                minAmountOut: minAmountOut_,
                data: UniversalTokenSwapperDataCyvbUSDCV1({
                    targets: swapData_.targets,
                    data: swapData_.data
                })
            });

        (bool success, bytes memory returnData) = UNIVERSAL_SWAPPER_FUSE.delegatecall(
            abi.encodeWithSelector(IUniversalTokenSwapperFuseCyvbUSDCV1.enter.selector, swapParams)
        );
        if (!success) revert SwapDelegateCallFailed(returnData);

        uint256 vbUsdcAfter = IERC20CyvbUSDCV1(VB_USDC).balanceOf(address(this));
        if (vbUsdcAfter <= vbUsdcBefore) revert NoVbUsdcReceived();

        // Only this call's output delta is split. Existing vbUSDC principal is untouched.
        vbUsdcOut = vbUsdcAfter - vbUsdcBefore;

        // Round any integer dust toward the RewardsClaimManager (vault users), never toward admin.
        adminAmount = (vbUsdcOut * ADMIN_BPS) / BPS;
        rewardsManagerAmount = vbUsdcOut - adminAmount;

        address rewardsClaimManager = IPlasmaVaultRewardsViewV1(address(this)).getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) revert RewardsClaimManagerZeroAddress();

        _safeTransfer(VB_USDC, rewardsClaimManager, rewardsManagerAmount);
        if (adminAmount != 0) {
            _safeTransfer(VB_USDC, ADMIN_FEE_RECEIVER, adminAmount);
        }

        emit KatRewardsConvertedAndSplit(
            VERSION,
            amountIn,
            vbUsdcOut,
            rewardsManagerAmount,
            adminAmount,
            rewardsClaimManager,
            ADMIN_FEE_RECEIVER
        );
    }

    function _safeTransfer(address token_, address to_, uint256 amount_) private {
        (bool success, bytes memory data) =
            token_.call(abi.encodeWithSelector(IERC20CyvbUSDCV1.transfer.selector, to_, amount_));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TokenTransferFailed(token_, to_, amount_);
        }
    }
}

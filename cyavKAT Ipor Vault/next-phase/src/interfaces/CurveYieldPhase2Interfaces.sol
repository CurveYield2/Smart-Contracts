// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice ABI-identical to IPOR FuseAction (contracts/vaults/PlasmaVault.sol) without importing the vault.
struct FuseAction {
    address fuse;
    bytes data;
}

/// @notice PlasmaVault surface used by the Phase 2 strategy layer.
interface ICyPlasmaVault {
    function execute(FuseAction[] calldata calls) external;
    function executeInternal(FuseAction[] calldata calls) external;
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function updateMarketsBalances(uint256[] calldata marketIds) external returns (uint256);
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
}

/// @notice Withdraw-manager surface. `release*` return the request-fee shares burned in the same call (WM v2, #3b).
interface ICyWithdrawManager {
    function pruneExpiredRequests(uint256 maxEntries) external returns (uint256 processed, bool complete);
    function activeUnreleasedShares() external view returns (uint256);
    function getSharesToRelease() external view returns (uint256);
    function reservedSharesOf(address requester) external view returns (uint256);
    function releaseActiveShares(uint256 timestamp, uint256 shares) external returns (uint256 feeSharesBurned);
    function releaseFor(address requester, uint256 timestamp, uint256 shares)
        external returns (uint256 feeSharesBurned);
    function availableSharesOf(address requester) external view returns (uint256);
    function getRequestFee() external view returns (uint256);
    function chargeRequest(address requester, uint256 shares) external;
}

interface ICyLegacyVkatConversion {
    function convertibleVkatAvkat() external view returns (uint256);
}

interface ICyRewardsClaimManager {
    function balanceOf() external view returns (uint256);
    function transferVestedTokensToVault() external;
    function claimRewards(FuseAction[] calldata calls) external;
    function updateBalance() external;
}

interface ICyAvKat {
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
}

interface ICyErc20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ICyMorphoOracle {
    function price() external view returns (uint256);
}

interface ICyVkatEscrow {
    function ownedTokens(address owner) external view returns (uint256[] memory);
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
}

/// @notice CurveYieldRouterSwapFuse (0x1fB8…) quote surface; the live quotes are called on the fuse's own address.
interface ICySwapFuse {
    function quoteExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        external returns (uint256 expectedNet, uint256 minimumNet);
    function requiredInput(address tokenIn, address tokenOut, uint256 requiredNetOut, uint256 maximumInput)
        external returns (uint256 amountIn);
    function quoteExactInputView(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 expectedNet, uint256 minimumNet);
    function requiredInputView(address tokenIn, address tokenOut, uint256 requiredNetOut, uint256 maximumInput)
        external view returns (uint256 amountIn);
}

/// @notice Every strategy set (Morpho loop, lending, LP, vKAT) exposes this planning surface to the executor.
/// Plans are coarse budgeted actions; the fuses do the live math and never exceed the budget.
interface ICyStrategySet {
    /// @notice avKAT-equivalent value the set manages (net of any debt).
    function managedAvkat() external view returns (uint256);
    /// @notice Target share of total managed avKAT in bps.
    function allocationBps() external view returns (uint256);
    /// @notice Actions that deploy at most `budgetAvkat` of idle avKAT; empty when at/over target (#18).
    function planDeploy(uint256 budgetAvkat, uint256 managedTotal)
        external view returns (FuseAction[] memory actions, uint256 consumedAvkat);
    /// @notice Actions that bring an over-target set back toward target when that is allowed; may be empty.
    function planReduce(uint256 managedTotal) external view returns (FuseAction[] memory actions, uint256 releasedAvkat);
    /// @notice Actions that free `neededAvkat` for withdrawals. `scheduled` selects the looser scheduled-loss gate.
    function planWithdraw(uint256 neededAvkat, bool scheduled)
        external view returns (FuseAction[] memory actions, uint256 providedAvkat);
}

interface ICyExecutorView {
    function executor() external view returns (address);
}

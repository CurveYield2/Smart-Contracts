// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

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

struct FuseAction {
    address fuse;
    bytes data;
}

struct VestingData {
    uint32 vestingTime;
    uint32 updateBalanceTimestamp;
    uint128 transferredTokens;
    uint128 lastUpdateBalance;
}

struct MorphoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MorphoPosition {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

struct MorphoMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IERC20Katana {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPlasmaVaultKatana {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalAssetsInMarket(uint256 marketId) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function execute(FuseAction[] calldata calls) external;
    function updateMarketsBalances(uint256[] calldata marketIds) external returns (uint256);
    function transferRequestSharesFee(address from, address to, uint256 amount) external;
}

interface ICurveYieldWithdrawalManager {
    function activeRequestedShares() external view returns (uint256);
    function earnedFeeShares() external view returns (uint256);
    function pruneExpiredRequests(uint256 maxEntries) external returns (uint256 processed, bool complete);
    function hasMoreStaleEntries() external view returns (bool);
    function releaseActiveShares(uint256 timestamp, uint256 shares) external;
}

interface IRewardsClaimManagerKatana {
    function balanceOf() external view returns (uint256);
    function getVestingData() external view returns (VestingData memory);
    function claimRewards(FuseAction[] calldata calls) external;
    function updateBalance() external;
    function transferVestedTokensToVault() external;
}

interface ICurveYieldFeeRouterKatana {
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

interface IQuoterV2Katana {
    function quoteExactInput(
        bytes calldata path,
        uint256 amountIn
    ) external returns (
        uint256 amountOut,
        uint160[] memory sqrtPriceX96AfterList,
        uint32[] memory initializedTicksCrossedList,
        uint256 gasEstimate
    );
}

interface IMerklDistributorKatana {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}

interface IMorphoKatana {
    function idToMarketParams(bytes32 id) external view returns (MorphoMarketParams memory);
    function position(bytes32 id, address user) external view returns (MorphoPosition memory);
    function market(bytes32 id) external view returns (MorphoMarket memory);
    function accrueInterest(MorphoMarketParams calldata marketParams) external;
}

interface IMorphoOracleKatana {
    function price() external view returns (uint256);
}

interface IAvKatKatana is IERC20Katana {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function depositTokenId(uint256 tokenId, address receiver) external returns (uint256 shares);
    function withdrawTokenId(uint256 assets, address receiver, address owner) external returns (uint256 tokenId);
}

interface IVkatNftKatana {
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
}

interface IVkatEscrowKatana {
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
    function minDeposit() external view returns (uint256);
    function split(uint256 tokenId, uint256 amount) external returns (uint256 splitTokenId);
    function ownedTokens(address owner) external view returns (uint256[] memory tokenIds);
}

interface IKatanaEpochClock {
    function epochDuration() external view returns (uint256);
    function epochStartTs() external view returns (uint256);
}

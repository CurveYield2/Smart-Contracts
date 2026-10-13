// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

// Yearn V3 tokenized-strategy BaseStrategy, adapted with Yelay's proven
// direct-Morpho market supply/withdraw pattern (not a MetaMorpho vault).
import {BaseStrategy} from "./YearnBaseStrategyKatana_v1.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenizedStrategyLib as TokenizedStrategy} from "@tokenized-strategy/libraries/TokenizedStrategyLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Id, IMorpho, MarketParams, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

interface IMerklDistributorChildV1 {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}

interface ICurveYieldRewardRouterChildV1 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
    function swapExactInput(
        address tokenIn, address tokenOut, uint256 amountIn,
        uint256 minNetAmountOut, address recipient, uint256 deadline
    ) external returns (uint256 netAmountOut);
}

/// @notice One Yearn tokenized strategy per *direct* Morpho Blue lending market.
/// @dev Fork of the execution pattern in YieldLayer/yelay-lite/MorphoBlueStrategy.sol,
///      using official Yearn BaseStrategy hooks and Yearn Merkl proof claim pattern.
///      The report-boundary (NOT live) asset estimate is intentional: the master
///      observes pre-report vs post-report PPS when profit unlocking is zero.
///      The owner MUST set this child keeper to the master contract.
///      Security review and chain-fork qualification required before deployment.
contract YearnMorphoMarketChild_v2 is BaseStrategy {
    using SafeERC20 for ERC20;

    IMorpho public immutable morpho;
    Id public immutable marketId;
    address public immutable master;
    ERC20 public immutable rewardToken;
    ICurveYieldRewardRouterChildV1 public immutable rewardRouter;
    IMerklDistributorChildV1 public immutable distributor;

    event Compounded(uint256 rewardsSold, uint256 assetReceived);
    event ClaimedAndCompounded(uint256 claimEntries, uint256 rewardBalance);
    error WrongCaller();
    error InvalidConfiguration();
    error BadClaim();
    error BadSwap();
    error Expired();

    constructor(
        address _asset,
        string memory _name,
        address _morpho,
        Id _marketId,
        address _master,
        address _rewardToken,
        address _rewardRouter,
        address _distributor
    ) BaseStrategy(_asset, _name) {
        if (
            _asset == address(0) || _morpho == address(0) ||
            _master == address(0) || _rewardToken == address(0) ||
            _rewardRouter == address(0) || _distributor == address(0)
        ) revert InvalidConfiguration();
        morpho = IMorpho(_morpho);
        marketId = _marketId;
        master = _master;
        rewardToken = ERC20(_rewardToken);
        rewardRouter = ICurveYieldRewardRouterChildV1(_rewardRouter);
        distributor = IMerklDistributorChildV1(_distributor);
        if (morpho.idToMarketParams(_marketId).loanToken != _asset) revert InvalidConfiguration();
        asset.forceApprove(_morpho, type(uint256).max);
    }

    function _market() internal view returns (MarketParams memory) {
        return morpho.idToMarketParams(marketId);
    }

    // Direct supply: adapted from Yelay MorphoBlueStrategy.deposit.
    function _deployFunds(uint256 amount) internal override {
        if (amount != 0) morpho.supply(_market(), amount, 0, address(this), "");
    }

    // Direct withdraw: adapted from Yelay MorphoBlueStrategy.withdraw.
    function _freeFunds(uint256 amount) internal override {
        if (amount != 0) morpho.withdraw(_market(), amount, 0, address(this), address(this));
    }

    // Only reporting crystallizes interest and reward compounding into child PPS.
    // DO NOT override _strategyTotalAssets with a live Morpho view.
    function _harvestAndReport() internal override returns (uint256) {
        if (!TokenizedStrategy.isShutdown()) {
            _deployFunds(asset.balanceOf(address(this)));
        }
        return asset.balanceOf(address(this)) + suppliedAssets();
    }

    function suppliedAssets() public view returns (uint256) {
        return MorphoBalancesLib.expectedSupplyAssets(morpho, _market(), address(this));
    }

    function availableWithdrawLimit(address) public view override returns (uint256) {
        Market memory m = morpho.market(marketId);
        uint256 freeLiquidity =
            m.totalSupplyAssets > m.totalBorrowAssets
                ? uint256(m.totalSupplyAssets) - uint256(m.totalBorrowAssets)
                : 0;
        return asset.balanceOf(address(this)) + Math.min(suppliedAssets(), freeLiquidity);
    }

    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 canFree = availableWithdrawLimit(address(this)) - asset.balanceOf(address(this));
        if (amount > canFree) amount = canFree;
        _freeFunds(amount);
    }

    /// @notice Master supplies authenticated Merkl proofs and conservative swap floor.
    ///         Rewards MUST be attributed to this strategy address; other recipients
    ///         are prohibited. No offchain APY is accepted or stored.
    function claimAndCompound(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        uint256 minNetAmountOut,
        uint256 deadline
    ) external nonReentrantTokenized returns (uint256 gained) {
        if (msg.sender != master) revert WrongCaller();
        uint256 n = users.length;
        if (n != tokens.length || n != amounts.length || n != proofs.length) revert BadClaim();
        for (uint256 i; i < n; ++i) {
            if (users[i] != address(this) || tokens[i] != address(rewardToken)) revert BadClaim();
        }

        if (n != 0) distributor.claim(users, tokens, amounts, proofs);

        uint256 toSell = rewardToken.balanceOf(address(this));
        emit ClaimedAndCompounded(n, toSell);
        if (toSell != 0) {
            if (deadline < block.timestamp) revert Expired();
            if (minNetAmountOut == 0) revert BadSwap();
            if (rewardRouter.routeFor(address(rewardToken), address(asset)).length == 0) revert BadSwap();
            uint256 beforeAssets = asset.balanceOf(address(this));
            rewardToken.forceApprove(address(rewardRouter), toSell);
            uint256 reported = rewardRouter.swapExactInput(
                address(rewardToken), address(asset), toSell,
                minNetAmountOut, address(this), deadline
            );
            rewardToken.forceApprove(address(rewardRouter), 0);
            gained = asset.balanceOf(address(this)) - beforeAssets;
            if (gained == 0 || gained != reported || gained < minNetAmountOut) revert BadSwap();
            emit Compounded(toSell, gained);
        }
        if (!TokenizedStrategy.isShutdown()) {
            _deployFunds(asset.balanceOf(address(this)));
        }
    }
}

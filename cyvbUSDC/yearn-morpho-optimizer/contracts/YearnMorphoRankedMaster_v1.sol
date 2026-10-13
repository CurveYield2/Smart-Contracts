// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

// Surgical expansion of Yearn's Base4626Compounder single-ERC4626
// supply/withdraw/convertToAssets design to up to 10 Yearn tokenized child
// strategies. Uses official Yearn BaseStrategy rather than reimplementing ERC4626.
import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {TokenizedStrategyLib as TokenizedStrategy} from "@tokenized-strategy/libraries/TokenizedStrategyLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IYearnMorphoChildV1 is ITokenizedStrategy {
    function claimAndCompound(
        address[] calldata users, address[] calldata tokens,
        uint256[] calldata amounts, bytes32[][] calldata proofs,
        uint256 minNetAmountOut, uint256 deadline
    ) external returns (uint256);
}

/// @notice Master Yearn V3 strategy: claim/compound/report children first,
///         rank each child's observed PPS change, then rebalance up to 10.
/// @dev Configuration authority is Yearn's own management role.
///      Child strategies must authorize this contract as their keeper, must
///      use report-boundary accounting, and MUST have zero profit unlock time.
///      Keeper never submits an APR or PPS value.
///      Requires security review and live-chain simulation before deployment.
contract YearnMorphoRankedMaster_v1 is BaseStrategy {
    using SafeERC20 for ERC20;

    uint256 public constant MAX_CHILDREN = 10;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;

    struct ClaimBundle {
        address child;
        address[] users;
        address[] tokens;
        uint256[] amounts;
        bytes32[][] proofs;
        uint256 minNetAmountOut;
        uint256 deadline;
    }

    address[] public children;
    address[] public lastRanking;
    mapping(address => bool) public isChild;
    mapping(address => uint256) public lastMasterReport;
    uint16[10] public rankWeights;
    uint8 public weightCount;
    uint16 public probeBps; // 0 => strict 70/30; >0 funds probes for unranked children.
    uint256 public lastOptimize;
    uint256 public minimumInterval = 1 hours;

    event ChildAdded(address indexed child);
    event ChildRemoved(address indexed child);
    event WeightUpdated(uint8 count);
    event ProbeUpdated(uint16 bps);
    event Optimized(uint256 timestamp, address winner, int256 winnerScore);
    event ChildScore(address indexed child, uint256 beforePps, uint256 afterPps, int256 score);

    error BadChild();
    error BadWeights();
    error MissingLiquidity();
    error Premature();
    error UnauthorizedReport();

    constructor(address _asset, string memory _name) BaseStrategy(_asset, _name) {
        rankWeights[0] = 7000;
        rankWeights[1] = 3000;
        weightCount = 2;
    }

    function childCount() external view returns (uint256) { return children.length; }
    function rankingCount() external view returns (uint256) { return lastRanking.length; }

    function addChild(address c) external onlyManagement {
        if (
            c == address(0) || c == address(this) || isChild[c] ||
            children.length == MAX_CHILDREN || c.code.length == 0
        ) revert BadChild();
        IYearnMorphoChildV1 child = IYearnMorphoChildV1(c);
        if (
            child.asset() != address(asset) ||
            child.keeper() != address(this) ||
            child.profitMaxUnlockTime() != 0 ||
            child.isShutdown()
        ) revert BadChild();
        isChild[c] = true;
        children.push(c);
        lastRanking.push(c);
        lastMasterReport[c] = child.lastReport();
        emit ChildAdded(c);
    }

    function removeChild(address c) external onlyManagement {
        if (!isChild[c] || IYearnMorphoChildV1(c).balanceOf(address(this)) != 0) revert BadChild();
        isChild[c] = false;
        delete lastMasterReport[c];
        for (uint256 i; i < children.length; ++i) {
            if (children[i] == c) {
                for (uint256 j = i; j + 1 < children.length; ++j) children[j] = children[j + 1];
                children.pop();
                break;
            }
        }
        for (uint256 i; i < lastRanking.length; ++i) {
            if (lastRanking[i] == c) {
                for (uint256 j = i; j + 1 < lastRanking.length; ++j) lastRanking[j] = lastRanking[j + 1];
                lastRanking.pop();
                break;
            }
        }
        emit ChildRemoved(c);
    }

    /// @dev Owner may configure 1-10 recipient weights, totaling exactly 100%.
    ///      Weights are ordinal ranks, not fixed market addresses.
    ///      If fewer strategies exist than ranks, effective weights renormalize.
    function setRankWeights(uint16[] calldata weights) external onlyManagement {
        if (weights.length == 0 || weights.length > MAX_CHILDREN) revert BadWeights();
        uint256 total;
        for (uint256 i; i < MAX_CHILDREN; ++i) {
            if (i < weights.length) {
                rankWeights[i] = weights[i];
                total += weights[i];
            } else {
                rankWeights[i] = 0;
            }
        }
        if (total != BPS) revert BadWeights();
        weightCount = uint8(weights.length);
        emit WeightUpdated(weightCount);
    }

    /// @notice A probe position permits a losing/unranked strategy to still
    ///         generate measurable yield; zero keeps strict 70/30 allocations.
    function setProbeBps(uint16 bps) external onlyManagement {
        if (bps > 100) revert BadWeights(); // max 1% in each of 10 strategies
        probeBps = bps;
        emit ProbeUpdated(bps);
    }

    function setMinimumInterval(uint256 interval) external onlyManagement {
        if (interval < 1 hours || interval > 30 days) revert BadWeights();
        minimumInterval = interval;
    }

    /// @notice Atomic sequence. Any failed Merkl claim, swap, report or
    ///         withdrawal reverts all prior steps, preventing a half-cycle.
    function optimizeFunds(ClaimBundle[] calldata claims)
        external onlyKeepers nonReentrantTokenized
    {
        uint256 n = children.length;
        if (n == 0 || claims.length != n) revert BadChild();
        if (lastOptimize != 0 && block.timestamp < lastOptimize + minimumInterval) revert Premature();

        address[] memory order = new address[](n);
        int256[] memory scores = new int256[](n);

        // IMPORTANT: no external rate inputs. PPS sampled from the child's ERC4626
        // contract before claim+compound+report, and again immediately afterward.
        for (uint256 i; i < n; ++i) {
            address c = children[i];
            int256 score = _reportAndScore(c, claims[i]);

            // Stable insertion sort for <=10 strategies. Scores computed solely on-chain.
            uint256 j = i;
            while (j > 0 && score > scores[j - 1]) {
                order[j] = order[j - 1];
                scores[j] = scores[j - 1];
                --j;
            }
            order[j] = c;
            scores[j] = score;
        }

        delete lastRanking;
        for (uint256 i; i < n; ++i) lastRanking.push(order[i]);
        // Update before external rebalances: all changes revert atomically on failure.
        lastOptimize = block.timestamp;
        _rebalance();
        emit Optimized(block.timestamp, order[0], scores[0]);
    }

    /// @dev Isolate Yearn report and Merkl proof calldata handling from
    ///      ranking loop to avoid stack pressure; no stateful APR oracles.
    function _reportAndScore(address c, ClaimBundle calldata input)
        internal returns (int256 score)
    {
        IYearnMorphoChildV1 child = IYearnMorphoChildV1(c);
        if (input.child != c || child.profitMaxUnlockTime() != 0) revert BadChild();
        if (child.lastReport() != lastMasterReport[c]) revert UnauthorizedReport();
        uint256 beforePps = child.pricePerShare();
        if (beforePps == 0) revert BadChild();

        child.claimAndCompound(
            input.users, input.tokens, input.amounts, input.proofs,
            input.minNetAmountOut, input.deadline
        );
        child.report();
        uint256 afterPps = child.pricePerShare();
        lastMasterReport[c] = child.lastReport();

        uint256 change = afterPps >= beforePps ? afterPps - beforePps : beforePps - afterPps;
        uint256 magnitude = Math.mulDiv(change, ONE, beforePps);
        if (magnitude > uint256(type(int256).max)) revert BadChild();
        score = afterPps >= beforePps ? int256(magnitude) : -int256(magnitude);
        emit ChildScore(c, beforePps, afterPps, score);
    }

    // Minimum probe allocation to each strategy; remainder apportioned by
    // ordinal performance rank and owner weights, with dust to final recipient.
    function _targetFor(address c, uint256 total) internal view returns (uint256 target) {
        uint256 n = lastRanking.length;
        if (n == 0) return 0;
        uint256 probe = Math.mulDiv(total, probeBps, BPS);
        uint256 base = probe * n;
        if (base > total) revert BadWeights();
        target = probe;

        uint256 recipients = Math.min(n, uint256(weightCount));
        uint256 denom;
        for (uint256 i; i < recipients; ++i) denom += rankWeights[i];
        if (denom == 0) revert BadWeights();
        uint256 free = total - base;
        uint256 previouslyAllocated;
        for (uint256 i; i < recipients; ++i) {
            uint256 a = i + 1 == recipients
                ? free - previouslyAllocated
                : Math.mulDiv(free, rankWeights[i], denom);
            previouslyAllocated += a;
            if (lastRanking[i] == c) return target + a;
        }
    }

    function _rebalance() internal {
        uint256 total = asset.balanceOf(address(this));
        for (uint256 i; i < children.length; ++i) {
            IYearnMorphoChildV1 child = IYearnMorphoChildV1(children[i]);
            total += child.convertToAssets(child.balanceOf(address(this)));
        }

        // Withdraw excess *before* depositing; never treat illiquidity as a loss.
        for (uint256 i; i < children.length; ++i) {
            IYearnMorphoChildV1 child = IYearnMorphoChildV1(children[i]);
            uint256 current = child.convertToAssets(child.balanceOf(address(this)));
            uint256 wanted = _targetFor(children[i], total);
            if (current > wanted + 1) {
                uint256 shares = child.previewWithdraw(current - wanted);
                if (shares > child.maxRedeem(address(this))) revert MissingLiquidity();
                child.redeem(shares, address(this), address(this), 0);
            }
        }

        // Fund each underweight strategy. Both funding and withdrawals must
        // preserve full asset value; all calls revert together on any failure.
        for (uint256 i; i < children.length; ++i) {
            IYearnMorphoChildV1 child = IYearnMorphoChildV1(children[i]);
            uint256 current = child.convertToAssets(child.balanceOf(address(this)));
            uint256 wanted = _targetFor(children[i], total);
            if (wanted > current + 1) {
                uint256 amount = wanted - current;
                if (amount > asset.balanceOf(address(this)) || amount > child.maxDeposit(address(this))) {
                    revert MissingLiquidity();
                }
                _depositIn(child, amount);
            }
        }
    }

    function _depositIn(IYearnMorphoChildV1 child, uint256 amount) internal {
        if (amount == 0) return;
        asset.forceApprove(address(child), amount);
        child.deposit(amount, address(this));
        asset.forceApprove(address(child), 0);
    }

    // Derived from Yearn Base4626Compounder._deployFunds, extended to <=10 children.
    function _deployFunds(uint256 amount) internal override {
        if (TokenizedStrategy.isShutdown() || amount == 0) return;
        if (lastRanking.length == 0) revert BadChild();
        uint256 allocated;
        for (uint256 i; i < lastRanking.length; ++i) {
            uint256 wanted = _targetFor(lastRanking[i], amount);
            allocated += wanted;
            if (wanted > IYearnMorphoChildV1(lastRanking[i]).maxDeposit(address(this))) {
                revert MissingLiquidity();
            }
            _depositIn(IYearnMorphoChildV1(lastRanking[i]), wanted);
        }
        if (allocated != amount) revert BadWeights();
    }

    // Base4626Compounder-style redeem, extended across ranked child shares.
    // Reverse order preferentially withdraws from the weakest strategies.
    function _freeFunds(uint256 amount) internal override {
        uint256 beforeAmount = asset.balanceOf(address(this));
        uint256 remaining = amount;
        for (uint256 i = lastRanking.length; i > 0 && remaining != 0; --i) {
            IYearnMorphoChildV1 child = IYearnMorphoChildV1(lastRanking[i - 1]);
            uint256 availableShares = child.maxRedeem(address(this));
            if (availableShares == 0) continue;
            uint256 availableAssets = child.previewRedeem(availableShares);
            if (availableAssets == 0) continue;
            uint256 pull = Math.min(remaining, availableAssets);
            uint256 shares = child.previewWithdraw(pull);
            if (shares > availableShares) shares = availableShares;
            if (shares == 0) continue;
            uint256 assetsBefore = asset.balanceOf(address(this));
            child.redeem(shares, address(this), address(this), 0);
            uint256 recovered = asset.balanceOf(address(this)) - assetsBefore;
            remaining = recovered >= remaining ? 0 : remaining - recovered;
        }
        if (asset.balanceOf(address(this)) - beforeAmount < amount) revert MissingLiquidity();
    }

    function _harvestAndReport() internal override returns (uint256 total) {
        total = asset.balanceOf(address(this));
        for (uint256 i; i < children.length; ++i) {
            IYearnMorphoChildV1 child = IYearnMorphoChildV1(children[i]);
            total += child.convertToAssets(child.balanceOf(address(this)));
        }
    }

    function availableWithdrawLimit(address) public view override returns (uint256 available) {
        available = asset.balanceOf(address(this));
        for (uint256 i; i < children.length; ++i) {
            IYearnMorphoChildV1 child = IYearnMorphoChildV1(children[i]);
            available += child.previewRedeem(child.maxRedeem(address(this)));
        }
    }

    function _emergencyWithdraw(uint256 amount) internal override {
        // Shutdown withdrawals reuse the exact same strict redemption path.
        uint256 liquid = availableWithdrawLimit(address(this)) - asset.balanceOf(address(this));
        _freeFunds(Math.min(amount, liquid));
    }
}

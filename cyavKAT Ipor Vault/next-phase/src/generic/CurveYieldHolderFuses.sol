// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {ICyErc20} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CyLpPosition} from "../lp/CurveYieldSushiLpHolder.sol";

/// @notice A holder contract that keeps a leveraged concentrated-liquidity position for ONE vault (only that vault may
/// call it; everything it releases goes back to the vault). CurveYieldSushiLpHolder implements it.
interface ICurveYieldClHolder {
    function AVKAT() external view returns (address); // the token the vault funds it with / receives back
    function open(int24 lower, int24 upper) external;
    function increase() external;
    function withdraw(uint256 bps) external returns (uint256 out);
    function rebalance(int24 lower, int24 upper) external;
    function collectFees() external;
    function deleverage(uint256 targetLtvBps) external;
    function position() external view returns (CyLpPosition memory);
}

/// @notice Optional hooks called in the vault's context: a yield checkpoint (e.g. the LP controller's
/// recordCheckpoint, which only accepts the vault) and a live "is a rebalance still worth it" check.
interface ICurveYieldHolderHook {
    function recordCheckpoint() external;
    function needsRebalance() external view returns (bool);
}

/// @notice Shared checks: the holder is a `4 << 160 | holder` substrate and every hook a `5 << 160 | hook` substrate of
/// SUBSTRATE_MARKET_ID; the fuse itself runs in MARKET_ID (ERC20_VAULT_BALANCE, 7, for the cyavKAT vault).
/// Typed substrates live in a SUBSTRATE-ONLY market (the cyavKAT vault: 54, next to the vKAT list) so the vault's
/// accounting markets keep only IPOR's standard entries (the IPOR front end reads every market-14 substrate as a Morpho
/// market id and every market-7 substrate as a token).
abstract contract CurveYieldHolderFuseBase is IFuseCommon {
    uint256 internal constant BPS = 10_000;
    uint256 public constant TYPE_HOLDER = 4;
    uint256 public constant TYPE_HOOK = 5;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID;

    error NotGranted(bytes32 substrate);
    error TransferFailed();

    constructor(uint256 marketId_, uint256 substrateMarketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    function typed(uint256 type_, address account_) public pure returns (bytes32) {
        return bytes32((type_ << 160) | uint256(uint160(account_)));
    }

    function _holder(address holder_) internal view returns (ICurveYieldClHolder) {
        bytes32 s = typed(TYPE_HOLDER, holder_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(SUBSTRATE_MARKET_ID, s)) revert NotGranted(s);
        return ICurveYieldClHolder(holder_);
    }

    function _hook(address hook_) internal view returns (ICurveYieldHolderHook) {
        if (hook_ == address(0)) return ICurveYieldHolderHook(address(0));
        bytes32 s = typed(TYPE_HOOK, hook_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(SUBSTRATE_MARKET_ID, s)) revert NotGranted(s);
        return ICurveYieldHolderHook(hook_);
    }

    function _checkpoint(address hook_) internal {
        ICurveYieldHolderHook h = _hook(hook_);
        if (address(h) != address(0)) h.recordCheckpoint();
    }

    /// @dev Sends up to `amount_` of the holder's funding token from the vault to the holder.
    function _send(ICurveYieldClHolder holder_, uint256 amount_) internal returns (uint256 sent_) {
        address token = holder_.AVKAT();
        uint256 balance = ICyErc20(token).balanceOf(address(this));
        sent_ = amount_ > balance ? balance : amount_;
        if (sent_ != 0 && !ICyErc20(token).transfer(address(holder_), sent_)) revert TransferFailed();
    }
}

struct HolderOpenData { address holder; uint256 amount; int24 lower; int24 upper; address checkpointHook; }
struct HolderIncreaseData { address holder; uint256 amount; address checkpointHook; }
struct HolderWithdrawData { address holder; uint256 bps; uint256 maxLossBps; bool gated; address checkpointHook; }
struct HolderRebalanceData { address holder; int24 lower; int24 upper; address rebalanceCheckHook; address checkpointHook; }
struct HolderDeleverageData { address holder; uint256 triggerLtvBps; uint256 targetLtvBps; }

/// @title HolderOpenFuse: funds the holder and opens the position in [lower, upper); checkpoint after.
contract CurveYieldHolderOpenFuse is CurveYieldHolderFuseBase {
    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldHolderFuseBase(marketId_, substrateMarketId_) {}

    function enter(HolderOpenData memory d_) external {
        ICurveYieldClHolder holder = _holder(d_.holder);
        if (_send(holder, d_.amount) == 0) return;
        holder.open(d_.lower, d_.upper);
        _checkpoint(d_.checkpointHook);
    }
}

/// @title HolderIncreaseFuse: checkpoint first (the yield before the basis changes), then adds to the range.
contract CurveYieldHolderIncreaseFuse is CurveYieldHolderFuseBase {
    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldHolderFuseBase(marketId_, substrateMarketId_) {}

    function enter(HolderIncreaseData memory d_) external {
        ICurveYieldClHolder holder = _holder(d_.holder);
        _checkpoint(d_.checkpointHook);
        if (_send(holder, d_.amount) == 0) return;
        holder.increase();
    }
}

/// @title HolderWithdrawFuse: withdraws `bps` of the position to the vault; when `gated`, reverts if what comes back is
/// more than `maxLossBps` under the basis share withdrawn (#19: 1% standard, 4% scheduled).
contract CurveYieldHolderWithdrawFuse is CurveYieldHolderFuseBase {
    error LossAboveGate(uint256 loss, uint256 allowed);

    event HolderWithdrawn(address version, address holder, uint256 bps, uint256 out, uint256 basisShare, bool gated);

    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldHolderFuseBase(marketId_, substrateMarketId_) {}

    function enter(HolderWithdrawData memory d_) external returns (uint256 out_) {
        ICurveYieldClHolder holder = _holder(d_.holder);
        CyLpPosition memory p = holder.position();
        if (p.tokenId == 0 || d_.bps == 0) return 0;
        uint256 bps = d_.bps > BPS ? BPS : d_.bps;
        uint256 basisShare = bps >= BPS ? p.basisAvkat : p.basisAvkat * bps / BPS;
        _checkpoint(d_.checkpointHook);
        out_ = holder.withdraw(bps);
        if (d_.gated) {
            uint256 allowed = basisShare * d_.maxLossBps / BPS;
            uint256 loss = basisShare > out_ ? basisShare - out_ : 0;
            if (loss > allowed) revert LossAboveGate(loss, allowed);
        }
        emit HolderWithdrawn(VERSION, d_.holder, bps, out_, basisShare, d_.gated);
    }
}

/// @title HolderRebalanceFuse: collects fees, re-checks live that the move is still wanted (no-op otherwise), moves the
/// whole position to [lower, upper), checkpoints.
contract CurveYieldHolderRebalanceFuse is CurveYieldHolderFuseBase {
    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldHolderFuseBase(marketId_, substrateMarketId_) {}

    function enter(HolderRebalanceData memory d_) external {
        ICurveYieldClHolder holder = _holder(d_.holder);
        holder.collectFees(); // fees count toward the close >= basis gate
        ICurveYieldHolderHook check = _hook(d_.rebalanceCheckHook);
        if (address(check) != address(0) && !check.needsRebalance()) return;
        holder.rebalance(d_.lower, d_.upper);
        _checkpoint(d_.checkpointHook);
    }
}

/// @title HolderDeleverageFuse: emergency de-leverage of the holder's own loan, only above `triggerLtvBps`.
contract CurveYieldHolderDeleverageFuse is CurveYieldHolderFuseBase {
    error NotAboveTrigger(uint256 ltvBps, uint256 triggerLtvBps);

    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldHolderFuseBase(marketId_, substrateMarketId_) {}

    function enter(HolderDeleverageData memory d_) external {
        ICurveYieldClHolder holder = _holder(d_.holder);
        uint256 ltv = holder.position().ltvBps;
        if (ltv <= d_.triggerLtvBps) revert NotAboveTrigger(ltv, d_.triggerLtvBps);
        holder.deleverage(d_.targetLtvBps);
    }
}

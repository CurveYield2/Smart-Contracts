// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IAccessManagerCyvbWmV1 {
    function hasRole(uint64 roleId, address account) external view returns (bool isMember, uint32 executionDelay);
}

struct FuseActionCyvbWmV1 {
    address fuse;
    bytes data;
}

interface IPlasmaVaultCyvbWmV1 {
    function asset() external view returns (address);
    function authority() external view returns (address);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function execute(FuseActionCyvbWmV1[] calldata calls) external;
}

interface IERC20CyvbWmV1 {
    function balanceOf(address account) external view returns (uint256);
}

struct WithdrawRequestInfo {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}

/// @title CyvbWbtcWithdrawManager_v1 (EARN_POOL_SPEC_v1)
/// @notice cyvbWBTC's withdraw manager: IPOR WithdrawManager semantics (scheduled requests + withdraw window,
///         released shares reserved from instant withdrawals, instant-withdraw fee burned by the vault) plus the
///         automation of the earn-pool leg, with no bot:
///         - `requestShares` takes the request fee (shares pulled from the user: approve this manager once) and itself
///           starts the fee-free fxBASE redeem through the strategy fuse (`requestEarnRedeem`);
///         - `finish()` (permissionless, after the fxBASE 1 h cooldown) completes it (`completeScheduledWithdrawal`,
///           which burns the fee shares held here - onboarding + request fees - and enforces PPS not lower) and
///           releases every pending request.
///         Users then claim with PlasmaVault.redeemFromRequest.
/// @dev Installed on a factory clone with IPOR's UpdateWithdrawManagerMaintenanceFuse and granted ALPHA (to call
///      vault.execute). Factory clones have no access-manager admin to map a new manager's functions to roles, so
///      authorization is checked here: vault-only hooks, ATOMIST (via the vault's access manager) for configuration.
///      Requests are tracked by release round (`currentRound`), not by timestamp: a request is released when its round
///      is older than the current one, so a request made in the same block as `finish()` can never be marked released
///      without funds.
contract CyvbWbtcWithdrawManager_v1 {
    uint64 public constant ATOMIST_ROLE = 100;
    uint256 public constant MAX_FEE = 0.05e18; // 5% hard cap on the request / withdraw fee
    uint256 public constant MIN_WITHDRAW_WINDOW = 1 days;

    struct Request {
        uint128 shares;
        uint64 round;
        uint64 endWithdrawWindowTimestamp;
    }

    address public immutable PLASMA_VAULT;
    address public immutable ASSET;

    /// @notice Scheduled withdrawals are off until the earn pool is in use (owner/atomist turns them on together with
    ///         the earn-split fuse version); while off, `requestShares` reverts and exits are instant only.
    bool public scheduledWithdrawalsEnabled;
    address public strategyFuse;
    address public burnFuse;
    uint256 public withdrawWindow;
    uint256 public withdrawFee;
    uint256 public requestFee;

    uint64 public currentRound = 1;
    uint256 public lastReleaseFundsTimestamp;
    /// @notice shares released and reserved for their owners (not usable by instant withdrawals)
    uint256 public sharesToRelease;
    /// @notice shares requested in the current round (not yet released)
    uint256 public pendingShares;
    /// @notice vbWBTC the earn-pool redeem has already been requested for in the current round
    uint256 public requestedVbWbtc;

    mapping(address account => Request) public requests;

    error NotVault(address caller);
    error NotAtomist(address caller);
    error ZeroShares();
    error InvalidFee(uint256 fee);
    error InvalidWindow(uint256 window);
    error InvalidAddress();
    error NothingToRelease();
    error InsufficientFreedAssets(uint256 required, uint256 available);
    error InvalidSharesToRelease(uint256 sharesToRelease, uint256 shares, uint256 unallocatedShares);
    error RequestFeeTransferFailed();
    error ScheduledWithdrawalsDisabled();

    event WithdrawRequested(address indexed account, uint256 shares, uint256 feeShares, uint64 round, uint256 endWindow);
    event EarnRedeemStarted(uint256 neededVbWbtc, bool executed);
    event FundsReleased(uint64 round, uint256 shares, uint256 sharesToRelease);
    event RequestExpired(address indexed account, uint256 shares);
    event UnallocatedWithdrawalValidated(address indexed caller, uint256 shares, uint256 sharesToRelease, uint256 feeShares);
    event ConfigUpdated(bytes32 indexed what, uint256 value);
    event FuseUpdated(bytes32 indexed what, address fuse);

    modifier onlyVault() {
        if (msg.sender != PLASMA_VAULT) revert NotVault(msg.sender);
        _;
    }

    modifier onlyAtomist() {
        (bool isAtomist,) =
            IAccessManagerCyvbWmV1(IPlasmaVaultCyvbWmV1(PLASMA_VAULT).authority()).hasRole(ATOMIST_ROLE, msg.sender);
        if (!isAtomist) revert NotAtomist(msg.sender);
        _;
    }

    constructor(address plasmaVault_, uint256 withdrawWindow_, uint256 withdrawFee_, uint256 requestFee_) {
        if (plasmaVault_.code.length == 0) revert InvalidAddress();
        if (withdrawWindow_ < MIN_WITHDRAW_WINDOW) revert InvalidWindow(withdrawWindow_);
        if (withdrawFee_ > MAX_FEE) revert InvalidFee(withdrawFee_);
        if (requestFee_ > MAX_FEE) revert InvalidFee(requestFee_);
        PLASMA_VAULT = plasmaVault_;
        ASSET = IPlasmaVaultCyvbWmV1(plasmaVault_).asset();
        withdrawWindow = withdrawWindow_;
        withdrawFee = withdrawFee_;
        requestFee = requestFee_;
    }

    // ---------------------------------------------------------------- scheduled withdrawals

    /// @notice Requests a scheduled withdrawal of `shares_` (gross; the request fee is taken from them). Approve this
    ///         manager for the fee shares first. Starts the earn-pool redeem for everything pending.
    function requestShares(uint256 shares_) external {
        if (!scheduledWithdrawalsEnabled) revert ScheduledWithdrawalsDisabled();
        if (shares_ == 0) revert ZeroShares();
        uint256 feeShares = (shares_ * requestFee) / 1e18;
        if (feeShares != 0 && !IPlasmaVaultCyvbWmV1(PLASMA_VAULT).transferFrom(msg.sender, address(this), feeShares)) {
            revert RequestFeeTransferFailed();
        }
        _dropRequest(msg.sender);
        uint256 net = shares_ - feeShares;
        uint256 end = block.timestamp + withdrawWindow;
        requests[msg.sender] = Request(uint128(net), currentRound, uint64(end));
        pendingShares += net;
        emit WithdrawRequested(msg.sender, net, feeShares, currentRound, end);
        _startEarnRedeem();
    }

    /// @notice Permissionless: completes the earn-pool redeem (after its cooldown), frees the vbWBTC for every pending
    ///         request, burns the fee shares held here and releases the round. Reverts while fxBASE is still locked.
    function finish() external {
        uint256 pending = pendingShares;
        if (pending == 0) revert NothingToRelease();
        uint256 needed = _neededVbWbtc();
        // the strategy fuse burns the fee shares held here itself (inside its PPS guard); the burn fuse is the fallback
        // when no strategy fuse is set
        uint256 feeShares = IPlasmaVaultCyvbWmV1(PLASMA_VAULT).balanceOf(address(this));
        FuseActionCyvbWmV1[] memory actions = new FuseActionCyvbWmV1[](1);
        if (strategyFuse != address(0)) {
            actions[0] = FuseActionCyvbWmV1(
                strategyFuse,
                abi.encodeWithSignature("completeScheduledWithdrawal(uint256,uint256)", needed, block.timestamp)
            );
            IPlasmaVaultCyvbWmV1(PLASMA_VAULT).execute(actions);
        } else if (burnFuse != address(0) && feeShares != 0) {
            actions[0] = FuseActionCyvbWmV1(burnFuse, abi.encodeWithSignature("enter((uint256))", feeShares));
            IPlasmaVaultCyvbWmV1(PLASMA_VAULT).execute(actions);
        }
        uint256 required = IPlasmaVaultCyvbWmV1(PLASMA_VAULT).convertToAssets(sharesToRelease + pending);
        uint256 idle = IERC20CyvbWmV1(ASSET).balanceOf(PLASMA_VAULT);
        if (idle < required) revert InsufficientFreedAssets(required, idle);

        uint64 round = currentRound;
        sharesToRelease += pending;
        pendingShares = 0;
        requestedVbWbtc = 0;
        currentRound = round + 1;
        lastReleaseFundsTimestamp = block.timestamp;
        emit FundsReleased(round, pending, sharesToRelease);
    }

    /// @notice Permissionless: drops an expired request (its released reservation, or its pending amount).
    function expire(address account_) external {
        Request memory r = requests[account_];
        if (r.shares == 0 || block.timestamp <= r.endWithdrawWindowTimestamp) return;
        _dropRequest(account_);
        emit RequestExpired(account_, r.shares);
    }

    // ---------------------------------------------------------------- PlasmaVault hooks

    function canWithdrawFromRequest(address account_, uint256 shares_) external onlyVault returns (bool) {
        Request memory r = requests[account_];
        if (r.round >= currentRound || block.timestamp > r.endWithdrawWindowTimestamp || r.shares < shares_) {
            return false;
        }
        requests[account_].shares = r.shares - uint128(shares_);
        sharesToRelease = sharesToRelease > shares_ ? sharesToRelease - shares_ : 0;
        return true;
    }

    /// @dev IPOR WithdrawManager.canWithdrawFromUnallocated: instant withdrawals may not use released (reserved) assets;
    ///      returns the fee shares the vault burns.
    function canWithdrawFromUnallocated(uint256 shares_) external onlyVault returns (uint256 feeSharesToBurn) {
        uint256 unallocated = IPlasmaVaultCyvbWmV1(PLASMA_VAULT).convertToShares(
            IERC20CyvbWmV1(ASSET).balanceOf(PLASMA_VAULT)
        );
        uint256 reserved = sharesToRelease;
        if (reserved > 0 && unallocated < reserved + shares_) {
            revert InvalidSharesToRelease(reserved, shares_, unallocated);
        }
        feeSharesToBurn = (shares_ * withdrawFee) / 1e18;
        emit UnallocatedWithdrawalValidated(msg.sender, shares_, reserved, feeSharesToBurn);
    }

    // ---------------------------------------------------------------- configuration (ATOMIST)

    function updateWithdrawFee(uint256 fee_) external onlyAtomist {
        if (fee_ > MAX_FEE) revert InvalidFee(fee_);
        withdrawFee = fee_;
        emit ConfigUpdated("withdrawFee", fee_);
    }

    function updateRequestFee(uint256 fee_) external onlyAtomist {
        if (fee_ > MAX_FEE) revert InvalidFee(fee_);
        requestFee = fee_;
        emit ConfigUpdated("requestFee", fee_);
    }

    function updateWithdrawWindow(uint256 window_) external onlyAtomist {
        if (window_ < MIN_WITHDRAW_WINDOW) revert InvalidWindow(window_);
        withdrawWindow = window_;
        emit ConfigUpdated("withdrawWindow", window_);
    }

    function setScheduledWithdrawalsEnabled(bool enabled_) external onlyAtomist {
        scheduledWithdrawalsEnabled = enabled_;
        emit ConfigUpdated("scheduledEnabled", enabled_ ? 1 : 0);
    }

    /// @notice The strategy fuse (FxMintCyvbWbtcFuse) and the fee-share burn fuse; both must be vault fuses.
    function setFuses(address strategyFuse_, address burnFuse_) external onlyAtomist {
        strategyFuse = strategyFuse_;
        burnFuse = burnFuse_;
        emit FuseUpdated("strategy", strategyFuse_);
        emit FuseUpdated("burn", burnFuse_);
    }

    // ---------------------------------------------------------------- views (IPOR WithdrawManager interface)

    function getSharesToRelease() external view returns (uint256) {
        return sharesToRelease;
    }

    function getWithdrawFee() external view returns (uint256) {
        return withdrawFee;
    }

    function getRequestFee() external view returns (uint256) {
        return requestFee;
    }

    function getWithdrawWindow() external view returns (uint256) {
        return withdrawWindow;
    }

    function getLastReleaseFundsTimestamp() external view returns (uint256) {
        return lastReleaseFundsTimestamp;
    }

    function getPlasmaVaultAddress() external view returns (address) {
        return PLASMA_VAULT;
    }

    function requestInfo(address account_) external view returns (WithdrawRequestInfo memory) {
        Request memory r = requests[account_];
        return WithdrawRequestInfo({
            shares: r.shares,
            endWithdrawWindowTimestamp: r.endWithdrawWindowTimestamp,
            canWithdraw: r.shares != 0 && r.round < currentRound && block.timestamp <= r.endWithdrawWindowTimestamp,
            withdrawWindowInSeconds: withdrawWindow
        });
    }

    /// @notice vbWBTC the vault must free for every released and pending request (beyond its idle balance).
    function neededVbWbtc() external view returns (uint256) {
        return _neededVbWbtc();
    }

    // ---------------------------------------------------------------- internals

    function _neededVbWbtc() private view returns (uint256) {
        uint256 required = IPlasmaVaultCyvbWmV1(PLASMA_VAULT).convertToAssets(sharesToRelease + pendingShares);
        uint256 idle = IERC20CyvbWmV1(ASSET).balanceOf(PLASMA_VAULT);
        return required > idle ? required - idle : 0;
    }

    /// @dev Requests the fxBASE redeem for the part of the need not already requested this round. Best effort: a
    ///      user's request never fails because of it (finish() then simply frees what the instant sources allow).
    function _startEarnRedeem() private {
        if (strategyFuse == address(0)) return;
        uint256 needed = _neededVbWbtc();
        if (needed <= requestedVbWbtc) return;
        uint256 delta = needed - requestedVbWbtc;
        FuseActionCyvbWmV1[] memory actions = new FuseActionCyvbWmV1[](1);
        actions[0] = FuseActionCyvbWmV1(strategyFuse, abi.encodeWithSignature("requestEarnRedeem(uint256)", delta));
        try IPlasmaVaultCyvbWmV1(PLASMA_VAULT).execute(actions) {
            requestedVbWbtc = needed;
            emit EarnRedeemStarted(delta, true);
        } catch {
            emit EarnRedeemStarted(delta, false);
        }
    }

    /// @dev Removes an account's request from the pending or the released total.
    function _dropRequest(address account_) private {
        Request memory r = requests[account_];
        if (r.shares == 0) return;
        if (r.round >= currentRound) pendingShares = pendingShares > r.shares ? pendingShares - r.shares : 0;
        else sharesToRelease = sharesToRelease > r.shares ? sharesToRelease - r.shares : 0;
        delete requests[account_];
    }
}

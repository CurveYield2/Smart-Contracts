// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AccessManagedUpgradeable} from "managers/access/AccessManagedUpgradeable.sol";
import {ContextClient} from "managers/context/ContextClient.sol";
import {IPlasmaVaultBase} from "interfaces/IPlasmaVaultBase.sol";
import {WithdrawManagerStorageLib} from "managers/withdraw/WithdrawManagerStorageLib.sol";
import {FuseAction, IPlasmaVaultKatana} from "./interfaces/CurveYieldKatanaInterfaces.sol";
import {ICurveYieldConfigGate, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {
    CurveYieldRequestAccounting,
    CurveYieldRequestQueueEntry,
    CurveYieldWithdrawalManagerStorageLib
} from "./CurveYieldWithdrawalManagerStorageLib.sol";

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

struct CurveYieldWithdrawRequestInfo {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
    uint256 refundableFeeShares;
}

interface ICurveYieldFeeAuthority {
    function isFeeAuthority(address account) external view returns (bool);
}

/// @notice IPOR WithdrawManager derivative with an enumerable expiry queue and exact request-fee escrow.
/// @dev v2 (Phase 2, spec #3b): the request fee earned on release is burned inside the release call and returned,
/// so the executor books fee and unwind loss in one transaction. The request-fee custody cut is removed (the
/// executor splits unwind profit per #16, D2). ONBOARDING_FEE_SPEC: the instant fee has no custody cut (burned in full
/// unless a split is set, cyavKAT+); the onboarding (deposit) fee shares IPOR mints here go 70/30 to custody / admin.
/// @dev The vault-facing withdrawal checks preserve the upstream manager's release semantics.
contract CurveYieldWithdrawalManagerV2 is Initializable, AccessManagedUpgradeable, ContextClient {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    mapping(address requester => uint256 shares) private _reservedShares;
    mapping(address requester => uint256 shares) private _escrowedEarnedFeeShares;
    mapping(address requester => uint256 shares) private _claimedFeeShares;
    uint256 private _totalReservedShares;
    uint256 private _totalEscrowedEarnedFeeShares;
    /// @notice Optional fee split (cyavKAT+): up to 3 recipients paid in the underlying, bps of each fee; the rest of the
    /// fee stays burned (holder PPS). Unset = the single profit-custody cut (cyavKAT). Fee authority only (gate).
    address[3] private _splitRecipients;
    uint16[3] private _splitBps;
    bool public splitRequestFee; // also split the request fee when it is burned at release
    uint256 public owedSplitShares; // instant-fee split accrued (in vault shares), paid by settleSplit()
    /// @notice POL spec 3b: accounts whose instant-withdrawal fee is burned in full (no split, no custody cut, nothing
    /// booked as profit). The account arms it (transient, one withdrawal) right before redeeming.
    mapping(address account => bool enabled) public burnOnlyFee;
    /// @dev keccak256("curveyield.wm.burnOnlyArmed") - transient flag, cleared by the withdrawal that uses it
    bytes32 private constant BURN_ONLY_ARMED_SLOT = 0x5e9ad4a930fa54042e3b65e7192fd1711e61dcd9a1c5a6e0b3f8fa4d154025c5;
    /// @notice PPS spec B5 (D3): accounts (the cyavKAT+ vault) whose instant fee is waived for emergency de-leverage only.
    mapping(address account => bool enabled) public emergencyFeeExempt;
    /// @dev keccak256("curveyield.wm.emergencyExemptArmed") - transient flag, cleared by the withdrawal that uses it
    bytes32 private constant EMERGENCY_EXEMPT_ARMED_SLOT = 0xf2b3e961e76abb1af616e863407bd5b98d9627f18a6468fd6d9e1b2a307b1ea5;
    /// @notice GATE_CONFIG_SPEC: when set, the instant / request fees and the fee-split bps are read from the governance
    /// gate (cyavKAT); when 0 they are this manager's own settings (cyavKAT+, outside the gate).
    address public configGate;
    /// @notice ONBOARDING_FEE_SPEC: every share this manager holds on someone's behalf (unearned request-fee escrow, earned
    /// fees awaiting their burn, charged shares in flight). Any balance above it is onboarding (deposit) fee shares.
    uint256 public committedShares;
    /// @notice ONBOARDING_FEE_SPEC: receives 30% of the onboarding fee shares. Fee authority only (admin fees are user-only).
    address public onboardingAdmin;
    uint256 public constant ONBOARDING_CUSTODY_BPS = 7_000;

    uint256 public constant MAX_PRUNE_BATCH = 500;
    uint256 public constant DEFAULT_REQUEST_FEE = 0.039e18;
    uint256 public constant DEFAULT_WITHDRAW_FEE = 0.009e18;
    uint256 public constant DEFAULT_WITHDRAW_WINDOW = 120 days;
    address public immutable ROLE_TEMPLATE_MANAGER;

    error ZeroShares();
    error InvalidFee(uint256 fee);
    error InvalidTimestamp(uint256 timestamp);
    error InvalidSharesToRelease(uint256 requested, uint256 active);
    error InvalidPruneBatch(uint256 requested);
    error UnauthorizedController(address caller);
    error UnauthorizedConfigurator(address caller, bytes4 selector);
    error InvalidBurnRequestFeeFuse(address fuse);
    error InvalidRequestFeeFuse(address fuse);
    error InvalidRoleTemplateManager(address manager);
    error InvalidVaultCaller(address caller);
    error InvalidUnallocatedShares(uint256 released, uint256 requested, uint256 available);
    error InvalidRequester(address requester);
    error InvalidProfitCustody(address custody);
    error NotBurnOnlyAccount(address account);
    error NotEmergencyExemptAccount(address account);
    error FeesInGate();
    error ChargeAboveMaximum(uint256 shares, uint256 maxShares);
    error NotFeeAuthority(address caller);
    error InvalidOnboardingAdmin(address admin);

    event ControllerSet(address indexed controller);
    event ManagerDependenciesUpdated(address indexed controller, address indexed burnRequestFeeFuse, address indexed requestFeeFuse);
    event RequestReplaced(address indexed requester, uint256 refundedFeeShares);
    event RequestExpired(address indexed requester, uint256 remainingShares);
    event ExpiredRequestFeeRefunded(address indexed requester, uint256 refundedFeeShares);
    event EarnedFeeSharesBurned(uint256 amount);
    event EarnedFeeBurnDeferred(uint256 amount);
    event ProfitCustodyUpdated(address indexed custody);
    event FeeSplitSet(address[3] recipients, uint16[3] bps, bool splitRequestFee);
    event FeeSplitPaid(uint256 feeShares, uint256[3] assets);
    event FeeSplitAccrued(uint256 splitShares, uint256 owedSplitShares);
    event BurnOnlyFeeSet(address indexed account, bool enabled);
    event BurnOnlyWithdrawal(uint256 shares, uint256 feeSharesBurned);
    event RequestCharged(address indexed requester, uint256 shares);
    event LaneFeesEarned(uint256 shares);
    event EmergencyFeeExemptSet(address indexed account, bool enabled);
    event EmergencyFeeExemptWithdrawal(uint256 shares);
    event ConfigGateUpdated(address indexed gate);
    event OnboardingAdminSet(address indexed admin);
    event OnboardingFeeSettled(uint256 feeShares, uint256 custodyShares, uint256 adminShares);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address accessManager_, address roleTemplateManager_) initializer {
        if (roleTemplateManager_ == address(0)) revert InvalidRoleTemplateManager(roleTemplateManager_);
        ROLE_TEMPLATE_MANAGER = roleTemplateManager_;
        __AccessManaged_init(accessManager_);
        _initializeDefaults();
    }

    function proxyInitialize(address accessManager_) external initializer {
        __AccessManaged_init(accessManager_);
        _initializeDefaults();
    }

    function requestShares(uint256 grossShares_) external {
        pruneExpiredRequests(MAX_PRUNE_BATCH);
        if (grossShares_ == 0) revert ZeroShares();
        address requester = _msgSender();
        uint256 refund = _settleExistingRequest(requester);

        uint256 feeShares = Math.mulDiv(
            grossShares_, _requestFee(), 1e18, Math.Rounding.Ceil
        );
        if (feeShares >= grossShares_) revert ZeroShares();
        uint256 netShares = grossShares_ - feeShares;
        uint256 endTimestamp = block.timestamp + WithdrawManagerStorageLib.getWithdrawWindowInSeconds();

        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        CurveYieldRequestAccounting storage request = state.requests[requester];
        uint64 nextGeneration = request.generation + 1;
        request.remainingShares = netShares.toUint128();
        request.initialNetShares = netShares.toUint128();
        request.totalFeeShares = feeShares.toUint128();
        request.earnedFeeShares = 0;
        request.endWithdrawWindowTimestamp = endTimestamp.toUint32();
        request.generation = nextGeneration;
        request.active = true;
        state.activeRequestedShares += netShares;

        WithdrawManagerStorageLib.updateWithdrawRequest(requester, netShares);
        CurveYieldWithdrawalManagerStorageLib.push(
            CurveYieldRequestQueueEntry(requester, endTimestamp.toUint32(), nextGeneration)
        );
        if (feeShares != 0) {
            _moveRequestFeeShares(requester, address(this), feeShares);
            committedShares += feeShares;
        }
        if (refund != 0) emit RequestReplaced(requester, refund);
        _burnEarnedFeesIfAny(false);
    }

    function canWithdrawFromRequest(address account_, uint256 shares_) external onlyVault returns (bool) {
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        CurveYieldRequestAccounting storage request = state.requests[account_];
        uint256 releaseTimestamp = WithdrawManagerStorageLib.getLastReleaseFundsTimestamp();
        if (
            !_canWithdraw(request, releaseTimestamp) || shares_ == 0 || request.remainingShares < shares_ ||
            _reservedShares[account_] < shares_
        ) {
            return false;
        }

        request.remainingShares -= shares_.toUint128();
        state.activeRequestedShares -= shares_;
        _reservedShares[account_] -= shares_;
        _totalReservedShares -= shares_;
        WithdrawManagerStorageLib.decreaseSharesFromWithdrawRequest(account_, shares_);
        WithdrawManagerStorageLib.decreaseSharesToRelease(shares_);
        _matureClaimedFee(state, request, account_);
        if (request.remainingShares == 0) request.active = false;
        return true;
    }

    function canWithdrawFromUnallocated(uint256 shares_) external onlyVault returns (uint256 feeSharesToBurn) {
        address plasmaVault = msg.sender;
        // settle the split owed from EARLIER withdrawals first, so this redeemer bears its fair share of that liability
        if (owedSplitShares != 0) _settle(plasmaVault);
        uint256 balance = ERC4626(ERC4626(plasmaVault).asset()).balanceOf(plasmaVault);
        uint256 availableShares = ERC4626(plasmaVault).convertToShares(balance);
        uint256 releasedShares = WithdrawManagerStorageLib.getSharesToRelease();
        if (_consumeEmergencyExempt()) {
            // armed by an emergencyFeeExempt account's emergency de-leverage bundle: no fee, nothing leaves but the payout
            if (availableShares < releasedShares + shares_) {
                revert InvalidUnallocatedShares(releasedShares, shares_, availableShares);
            }
            emit EmergencyFeeExemptWithdrawal(shares_);
            return 0;
        }
        uint256 feeRate = _withdrawFee();
        uint16[3] memory splitBps = _splitBpsNow();
        if (feeRate != 0) feeSharesToBurn = Math.mulDiv(shares_, feeRate, 1e18);
        if (_consumeBurnOnly()) {
            // armed by a burnOnlyFee account (POL custody): the whole fee is burned for holders, nothing leaves
            if (availableShares < releasedShares + shares_) {
                revert InvalidUnallocatedShares(releasedShares, shares_, availableShares);
            }
            emit BurnOnlyWithdrawal(shares_, feeSharesToBurn);
            return feeSharesToBurn;
        }
        if (splitBps[0] + splitBps[1] + splitBps[2] != 0) {
            // cyavKAT+: split the fee to its recipients in the underlying; the rest stays burned
            // only the redeemer's own outflow must fit now; the split is ACCRUED (in shares) and paid later by
            // settleSplit(), so paying it can never shrink this redeemer's payout
            if (availableShares < releasedShares + shares_) {
                revert InvalidUnallocatedShares(releasedShares, shares_, availableShares);
            }
            uint256 splitShares = Math.mulDiv(feeSharesToBurn, uint256(splitBps[0]) + splitBps[1] + splitBps[2], 10_000);
            owedSplitShares += splitShares;
            emit FeeSplitAccrued(splitShares, owedSplitShares);
            return feeSharesToBurn;
        }
        // ONBOARDING_FEE_SPEC: no split (cyavKAT) = the instant fee is burned in full for holders, nothing leaves
        if (availableShares < releasedShares + shares_) {
            revert InvalidUnallocatedShares(releasedShares, shares_, availableShares);
        }
    }

    /// @notice Fee split (fee authority only, via the governance gate). Each bps <= 5,000; total <= 7,500 so at least a
    /// quarter of every fee stays burned for holders. All-zero bps = off (profit-custody cut instead).
    function setFeeSplit(address[3] calldata recipients_, uint16[3] calldata bps_, bool splitRequestFee_) external {
        // the template (IPOR WM) has no setFeeSplit selector: gate it by the withdraw-fee setter permission (role 902)
        _checkTemplatePermission(bytes4(keccak256("updateWithdrawFee(uint256)")));
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            if (bps_[i] > 5_000 || (bps_[i] != 0 && recipients_[i] == address(0))) revert InvalidFee(bps_[i]);
            total += bps_[i];
        }
        if (total > 7_500) revert InvalidFee(total);
        _splitRecipients = recipients_;
        _splitBps = bps_;
        splitRequestFee = splitRequestFee_;
        emit FeeSplitSet(recipients_, bps_, splitRequestFee_);
    }

    /// @notice Pays the accrued instant-fee split (anyone; the bot calls it), limited to idle not reserved for released
    /// requests. Each recipient gets its bps share of the owed value at the current price.
    /// @notice Enable / disable burn-only fees for an account (same permission as the withdraw-fee setter; reversible).
    function setBurnOnlyFee(address account_, bool enabled_) external {
        _checkTemplatePermission(bytes4(keccak256("updateWithdrawFee(uint256)")));
        burnOnlyFee[account_] = enabled_;
        emit BurnOnlyFeeSet(account_, enabled_);
    }

    /// @notice Arms burn-only for the NEXT instant withdrawal in this transaction (call right before redeem/withdraw).
    function armBurnOnlyFee() external {
        if (!burnOnlyFee[msg.sender]) revert NotBurnOnlyAccount(msg.sender);
        bytes32 slot = BURN_ONLY_ARMED_SLOT;
        assembly {
            tstore(slot, 1)
        }
    }

    function _consumeBurnOnly() private returns (bool armed_) {
        bytes32 slot = BURN_ONLY_ARMED_SLOT;
        assembly {
            armed_ := tload(slot)
            if armed_ { tstore(slot, 0) }
        }
    }

    function settleSplit() external returns (uint256 paidShares_) {
        return _settle(getPlasmaVaultAddress());
    }

    function _settle(address plasmaVault_) private returns (uint256 paidShares_) {
        uint256 owed = owedSplitShares;
        if (owed == 0) return 0;
        uint256 idle = IERC20(ERC4626(plasmaVault_).asset()).balanceOf(plasmaVault_);
        uint256 reserved = ERC4626(plasmaVault_).convertToAssets(WithdrawManagerStorageLib.getSharesToRelease());
        if (idle <= reserved) return 0;
        uint256 payableShares = ERC4626(plasmaVault_).convertToShares(idle - reserved);
        paidShares_ = owed < payableShares ? owed : payableShares;
        owedSplitShares = owed - paidShares_;
        uint16[3] memory splitBps = _splitBpsNow();
        uint256 totalBps = uint256(splitBps[0]) + splitBps[1] + splitBps[2];
        if (totalBps == 0) return paidShares_; // split switched off: the owed value simply stays with holders
        // paidShares_ is the split part of the fee; pass the equivalent full fee so _paySplit pays exactly it
        _paySplit(plasmaVault_, Math.mulDiv(paidShares_, 10_000, totalBps));
    }

    function feeSplit() external view returns (address[3] memory recipients_, uint16[3] memory bps_) {
        return (_splitRecipients, _splitBpsNow());
    }

    /// @dev Pays each recipient the underlying worth its bps of `feeShares_` (the vault approved this manager); the
    /// fee shares themselves are burned in full, so the unpaid rest raises holders' PPS.
    function _paySplit(address plasmaVault_, uint256 feeShares_) private {
        if (feeShares_ == 0) return;
        uint16[3] memory splitBps = _splitBpsNow();
        IERC20 asset = IERC20(ERC4626(plasmaVault_).asset());
        uint256[3] memory paid;
        for (uint256 i; i < 3; ++i) {
            if (splitBps[i] == 0) continue;
            paid[i] = ERC4626(plasmaVault_).convertToAssets(Math.mulDiv(feeShares_, splitBps[i], 10_000));
            if (paid[i] != 0) asset.safeTransferFrom(plasmaVault_, _splitRecipients[i], paid[i]);
        }
        emit FeeSplitPaid(feeShares_, paid);
    }

    function pruneExpiredRequests(uint256 maxEntries_) public returns (uint256 processed, bool complete) {
        if (maxEntries_ == 0 || maxEntries_ > MAX_PRUNE_BATCH) revert InvalidPruneBatch(maxEntries_);
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        bool expiredEarnedFee;

        while (processed < maxEntries_ && CurveYieldWithdrawalManagerStorageLib.queueLength() != 0) {
            CurveYieldRequestQueueEntry memory entry = CurveYieldWithdrawalManagerStorageLib.peek();
            CurveYieldRequestAccounting storage request = state.requests[entry.requester];
            bool stale = !request.active || request.generation != entry.generation;
            bool expired = !stale && block.timestamp > entry.endWithdrawWindowTimestamp;
            if (!stale && !expired) break;

            CurveYieldWithdrawalManagerStorageLib.pop();
            unchecked { ++processed; }
            if (expired) {
                uint256 remaining = request.remainingShares;
                state.activeRequestedShares -= remaining;
                request.active = false;
                _cancelReservation(entry.requester);
                _matureEscrowedFee(state, entry.requester);
                if (request.earnedFeeShares != 0) expiredEarnedFee = true;
                uint256 refund = uint256(request.totalFeeShares) - uint256(request.earnedFeeShares);
                request.totalFeeShares = request.earnedFeeShares;
                if (refund != 0) {
                    committedShares -= refund;
                    _moveRequestFeeShares(address(this), entry.requester, refund);
                    emit ExpiredRequestFeeRefunded(entry.requester, refund);
                }
                emit RequestExpired(entry.requester, remaining);
            }
        }
        complete = !hasMoreStaleEntries();
        _burnEarnedFeesIfAny(expiredEarnedFee);
    }

    function hasMoreStaleEntries() public view returns (bool) {
        if (CurveYieldWithdrawalManagerStorageLib.queueLength() == 0) return false;
        CurveYieldRequestQueueEntry memory entry = CurveYieldWithdrawalManagerStorageLib.peek();
        CurveYieldRequestAccounting storage request =
            CurveYieldWithdrawalManagerStorageLib.layout().requests[entry.requester];
        return !request.active || request.generation != entry.generation ||
            block.timestamp > entry.endWithdrawWindowTimestamp;
    }

    function releaseActiveShares(uint256 timestamp_, uint256 shares_)
        external onlyController returns (uint256 feeSharesBurned)
    {
        if (timestamp_ >= block.timestamp) revert InvalidTimestamp(timestamp_);
        uint256 available = activeUnreleasedShares();
        if (shares_ == 0 || shares_ > available) revert InvalidSharesToRelease(shares_, available);
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        uint256 remaining = shares_;
        uint256 length = state.queue.length;
        for (uint256 i; i < length && remaining != 0; ++i) {
            CurveYieldRequestQueueEntry memory entry = state.queue[i];
            CurveYieldRequestAccounting storage request = state.requests[entry.requester];
            if (!_releasable(request, entry.generation, timestamp_)) continue;
            uint256 room = uint256(request.remainingShares) - _reservedShares[entry.requester];
            uint256 take = room < remaining ? room : remaining;
            if (take == 0) continue;
            _reservedShares[entry.requester] += take;
            _totalReservedShares += take;
            _accrueEarnedFee(request, entry.requester);
            remaining -= take;
        }
        if (remaining != 0) revert InvalidSharesToRelease(shares_, shares_ - remaining);
        WithdrawManagerStorageLib.releaseFunds(
            timestamp_, WithdrawManagerStorageLib.getSharesToRelease() + shares_
        );
        feeSharesBurned = _burnEarnedFeesIfAny(true);
    }

    function releaseFor(address requester_, uint256 timestamp_, uint256 shares_)
        external onlyController returns (uint256 feeSharesBurned)
    {
        if (timestamp_ >= block.timestamp) revert InvalidTimestamp(timestamp_);
        CurveYieldRequestAccounting storage request =
            CurveYieldWithdrawalManagerStorageLib.layout().requests[requester_];
        if (!_releasable(request, request.generation, timestamp_)) revert InvalidRequester(requester_);
        uint256 available = uint256(request.remainingShares) - _reservedShares[requester_];
        if (shares_ == 0 || shares_ > available) revert InvalidSharesToRelease(shares_, available);
        _reservedShares[requester_] += shares_;
        _totalReservedShares += shares_;
        _accrueEarnedFee(request, requester_);
        WithdrawManagerStorageLib.releaseFunds(
            timestamp_, WithdrawManagerStorageLib.getSharesToRelease() + shares_
        );
        feeSharesBurned = _burnEarnedFeesIfAny(true);
    }

    /// @notice POL spec 3c: the executor charges a requester the extra cost of funding their withdrawal from POL (so
    /// the vault keeps its minimum profit). The shares come out of the requester's open, unreleased request and are
    /// burned directly (no request-fee split): PPS up, nothing leaves the vault.
    function chargeRequest(address requester_, uint256 shares_) external onlyController {
        _chargeRequest(requester_, shares_);
    }

    /// @notice chargeRequest for an amount of the vault's asset, at most `maxShares_` shares; returns the shares charged.
    function chargeRequestForAssets(address requester_, uint256 assets_, uint256 maxShares_)
        external onlyController returns (uint256 shares_)
    {
        if (assets_ == 0) return 0;
        shares_ = ERC4626(getPlasmaVaultAddress()).convertToShares(assets_) + 1;
        if (shares_ > maxShares_) revert ChargeAboveMaximum(shares_, maxShares_);
        _chargeRequest(requester_, shares_);
    }

    function _chargeRequest(address requester_, uint256 shares_) private {
        if (shares_ == 0) return;
        CurveYieldWithdrawalManagerStorageLib.Layout storage state = CurveYieldWithdrawalManagerStorageLib.layout();
        CurveYieldRequestAccounting storage request = state.requests[requester_];
        uint256 available = request.active ? uint256(request.remainingShares) - _reservedShares[requester_] : 0;
        if (shares_ > available) revert InvalidSharesToRelease(shares_, available);
        request.remainingShares -= shares_.toUint128();
        state.activeRequestedShares -= shares_;
        WithdrawManagerStorageLib.decreaseSharesFromWithdrawRequest(requester_, shares_);
        if (request.remainingShares == 0) request.active = false;
        _moveRequestFeeShares(requester_, address(this), shares_);
        address fuse = state.burnRequestFeeFuse;
        if (fuse == address(0)) revert InvalidBurnRequestFeeFuse(fuse);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse, abi.encodeWithSignature("enter((uint256))", shares_));
        IPlasmaVaultKatana(getPlasmaVaultAddress()).execute(actions);
        emit RequestCharged(requester_, shares_);
    }

    /// @notice PPS spec A1: pays a native-exit lane cost in the same transaction. Marks up to `feeShares_` of escrowed,
    /// not yet earned request fees as earned (non-refundable: replace / expiry refund only `total - earned`), in release
    /// order, and burns them. Each request keeps `keepBps_` of its remaining shares unearned (its minimum unwind profit,
    /// earned at release). Returns the shares earned and burned.
    function earnRequestFees(uint256 feeShares_, uint256 keepBps_) external onlyController returns (uint256 earned_) {
        return _earnRequestFees(feeShares_, keepBps_);
    }

    /// @notice earnRequestFees for a loss given in the vault's asset: earns (and burns) the fee shares worth it.
    function earnRequestFeesForLoss(uint256 lossAssets_, uint256 keepBps_) external onlyController returns (uint256) {
        if (lossAssets_ == 0) return 0;
        return _earnRequestFees(ERC4626(getPlasmaVaultAddress()).convertToShares(lossAssets_) + 1, keepBps_);
    }

    /// @notice Assets needed to pay every released-but-unredeemed share plus `shares_` more (at the redeem rate).
    function assetsNeededFor(uint256 shares_) external view returns (uint256) {
        return ERC4626(getPlasmaVaultAddress()).previewRedeem(WithdrawManagerStorageLib.getSharesToRelease() + shares_);
    }

    /// @notice Requested shares the vault's idle assets can release now, after what released shares already reserve.
    function releasableShares() external view returns (uint256) {
        ERC4626 vault = ERC4626(getPlasmaVaultAddress());
        uint256 idle = IERC20(vault.asset()).balanceOf(address(vault));
        uint256 reserved = vault.previewRedeem(WithdrawManagerStorageLib.getSharesToRelease());
        return idle > reserved ? vault.convertToShares(idle - reserved) : 0;
    }

    function _earnRequestFees(uint256 feeShares_, uint256 keepBps_) private returns (uint256 earned_) {
        if (feeShares_ == 0) return 0;
        CurveYieldWithdrawalManagerStorageLib.Layout storage state = CurveYieldWithdrawalManagerStorageLib.layout();
        uint256 length = state.queue.length;
        for (uint256 i; i < length && earned_ < feeShares_; ++i) {
            CurveYieldRequestQueueEntry memory entry = state.queue[i];
            CurveYieldRequestAccounting storage request = state.requests[entry.requester];
            uint256 room = _feeHeadroom(request, entry.generation, keepBps_);
            if (room == 0) continue;
            uint256 take = feeShares_ - earned_ < room ? feeShares_ - earned_ : room;
            request.earnedFeeShares += take.toUint128();
            earned_ += take;
        }
        if (earned_ == 0) return 0;
        state.earnedFeeShares += earned_;
        _burnEarnedFeesIfAny(true);
        emit LaneFeesEarned(earned_);
    }

    /// @notice Escrowed request-fee shares `earnRequestFees` could earn now (see there).
    function escrowedFeeHeadroomShares(uint256 keepBps_) external view returns (uint256 total_) {
        CurveYieldWithdrawalManagerStorageLib.Layout storage state = CurveYieldWithdrawalManagerStorageLib.layout();
        uint256 length = state.queue.length;
        for (uint256 i; i < length; ++i) {
            CurveYieldRequestQueueEntry memory entry = state.queue[i];
            total_ += _feeHeadroom(state.requests[entry.requester], entry.generation, keepBps_);
        }
    }

    /// @dev Unearned fee of an active, current, unexpired request above what it must keep for release.
    function _feeHeadroom(CurveYieldRequestAccounting storage request_, uint64 generation_, uint256 keepBps_)
        private view returns (uint256)
    {
        if (!request_.active || request_.generation != generation_ || block.timestamp > request_.endWithdrawWindowTimestamp) {
            return 0;
        }
        uint256 unearned = uint256(request_.totalFeeShares) - uint256(request_.earnedFeeShares);
        uint256 keep = Math.mulDiv(request_.remainingShares, keepBps_, 10_000, Math.Rounding.Ceil);
        return unearned > keep ? unearned - keep : 0;
    }

    /// @notice PPS spec B5 (D3): accounts whose instant-withdrawal fee is waived for EMERGENCY de-leverage only. The
    /// account arms it (transient, one withdrawal) from its emergency bundle; every other withdrawal pays the fee.
    function setEmergencyFeeExempt(address account_, bool enabled_) external {
        _checkTemplatePermission(bytes4(keccak256("updateWithdrawFee(uint256)")));
        emergencyFeeExempt[account_] = enabled_;
        emit EmergencyFeeExemptSet(account_, enabled_);
    }

    /// @notice Arms a zero instant fee for the NEXT instant withdrawal in this transaction (emergency de-leverage).
    function armEmergencyFeeExempt() external {
        if (!emergencyFeeExempt[msg.sender]) revert NotEmergencyExemptAccount(msg.sender);
        bytes32 slot = EMERGENCY_EXEMPT_ARMED_SLOT;
        assembly {
            tstore(slot, 1)
        }
    }

    /// @notice Clears an unused arm (last action of the same emergency bundle).
    function disarmEmergencyFeeExempt() external {
        if (!emergencyFeeExempt[msg.sender]) revert NotEmergencyExemptAccount(msg.sender);
        bytes32 slot = EMERGENCY_EXEMPT_ARMED_SLOT;
        assembly {
            tstore(slot, 0)
        }
    }

    function _consumeEmergencyExempt() private returns (bool armed_) {
        bytes32 slot = EMERGENCY_EXEMPT_ARMED_SLOT;
        assembly {
            armed_ := tload(slot)
            if armed_ { tstore(slot, 0) }
        }
    }

    /// @notice ONBOARDING_FEE_SPEC: the onboarding fee shares IPOR minted to this manager, not yet paid out.
    function pendingOnboardingFeeShares() public view returns (uint256) {
        uint256 balance = IERC20(getPlasmaVaultAddress()).balanceOf(address(this));
        return balance > committedShares ? balance - committedShares : 0;
    }

    /// @notice ONBOARDING_FEE_SPEC: pays the onboarding fee shares out as cyavKAT, 70% to the profit custody (into its
    /// general holdings) and 30% to the admin receiver. Permissionless; the executor calls it in deployAssets.
    function settleOnboardingFee() external returns (uint256 shares_) {
        shares_ = pendingOnboardingFeeShares();
        if (shares_ == 0) return 0;
        address custody = CurveYieldWithdrawalManagerStorageLib.layout().profitCustody;
        address admin = onboardingAdmin;
        if (custody == address(0)) revert InvalidProfitCustody(custody);
        if (admin == address(0)) revert InvalidOnboardingAdmin(admin);
        uint256 custodyShares = Math.mulDiv(shares_, ONBOARDING_CUSTODY_BPS, 10_000);
        _moveRequestFeeShares(address(this), custody, custodyShares);
        _moveRequestFeeShares(address(this), admin, shares_ - custodyShares);
        emit OnboardingFeeSettled(shares_, custodyShares, shares_ - custodyShares);
    }

    /// @notice Sets the onboarding admin receiver: the gate's fee authority only (or, with no gate, the fee setter).
    function setOnboardingAdmin(address admin_) external {
        address gate = configGate;
        if (gate == address(0)) _checkTemplatePermission(bytes4(keccak256("updateWithdrawFee(uint256)")));
        else if (!ICurveYieldFeeAuthority(gate).isFeeAuthority(msg.sender)) revert NotFeeAuthority(msg.sender);
        if (admin_ == address(0) || admin_ == address(this)) revert InvalidOnboardingAdmin(admin_);
        onboardingAdmin = admin_;
        emit OnboardingAdminSet(admin_);
    }

    function activeUnreleasedShares() public view returns (uint256) {
        return activeRequestedShares() - _totalReservedShares;
    }

    function reservedSharesOf(address requester_) external view returns (uint256) {
        return _reservedShares[requester_];
    }

    /// @notice Shares of an active, unexpired request that are not yet released.
    function availableSharesOf(address requester_) external view returns (uint256) {
        CurveYieldRequestAccounting storage request =
            CurveYieldWithdrawalManagerStorageLib.layout().requests[requester_];
        if (!request.active || block.timestamp > request.endWithdrawWindowTimestamp) return 0;
        uint256 reserved = _reservedShares[requester_];
        return request.remainingShares > reserved ? request.remainingShares - reserved : 0;
    }

    function setDependencies(
        address controller_, address burnRequestFeeFuse_, address requestFeeFuse_, address previousManager_
    ) external {
        _checkTemplatePermission(bytes4(keccak256("updatePlasmaVaultAddress(address)")));
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        if (controller_ == address(0)) revert UnauthorizedController(controller_);
        if (burnRequestFeeFuse_ == address(0)) revert InvalidBurnRequestFeeFuse(burnRequestFeeFuse_);
        if (requestFeeFuse_ == address(0)) revert InvalidRequestFeeFuse(requestFeeFuse_);
        state.controller = controller_;
        state.burnRequestFeeFuse = burnRequestFeeFuse_;
        state.requestFeeFuse = requestFeeFuse_;
        emit ControllerSet(controller_);
        emit ManagerDependenciesUpdated(controller_, burnRequestFeeFuse_, requestFeeFuse_);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            requestFeeFuse_, abi.encodeWithSignature("configureManagerAssetAllowance(address)", previousManager_)
        );
        IPlasmaVaultKatana(getPlasmaVaultAddress()).execute(actions);
    }

    function activeRequestedShares() public view returns (uint256) {
        return CurveYieldWithdrawalManagerStorageLib.layout().activeRequestedShares;
    }

    function earnedFeeShares() external view returns (uint256) {
        return CurveYieldWithdrawalManagerStorageLib.layout().earnedFeeShares + _totalEscrowedEarnedFeeShares;
    }

    function controller() external view returns (address) {
        return CurveYieldWithdrawalManagerStorageLib.layout().controller;
    }

    function setProfitCustody(address profitCustody_) external {
        _checkTemplatePermission(bytes4(keccak256("updatePlasmaVaultAddress(address)")));
        if (profitCustody_ == address(0) || profitCustody_ == address(this)) {
            revert InvalidProfitCustody(profitCustody_);
        }
        CurveYieldWithdrawalManagerStorageLib.layout().profitCustody = profitCustody_;
        emit ProfitCustodyUpdated(profitCustody_);
    }

    function profitCustody() external view returns (address) {
        return CurveYieldWithdrawalManagerStorageLib.layout().profitCustody;
    }

    function requestInfo(address account_) external view returns (CurveYieldWithdrawRequestInfo memory info) {
        CurveYieldRequestAccounting storage request =
            CurveYieldWithdrawalManagerStorageLib.layout().requests[account_];
        bool canWithdraw = _reservedShares[account_] != 0 &&
            _canWithdraw(request, WithdrawManagerStorageLib.getLastReleaseFundsTimestamp());
        uint256 totalFee = request.totalFeeShares;
        info = CurveYieldWithdrawRequestInfo({
            shares: canWithdraw ? _reservedShares[account_] : request.remainingShares,
            endWithdrawWindowTimestamp: request.endWithdrawWindowTimestamp,
            canWithdraw: canWithdraw,
            withdrawWindowInSeconds: WithdrawManagerStorageLib.getWithdrawWindowInSeconds(),
            refundableFeeShares: totalFee - request.earnedFeeShares
        });
    }

    function rawRequestInfo(address account_) external view returns (CurveYieldWithdrawRequestInfo memory info) {
        CurveYieldRequestAccounting storage request =
            CurveYieldWithdrawalManagerStorageLib.layout().requests[account_];
        uint256 totalFee = request.totalFeeShares;
        info = CurveYieldWithdrawRequestInfo({
            shares: request.remainingShares,
            endWithdrawWindowTimestamp: request.endWithdrawWindowTimestamp,
            canWithdraw: _reservedShares[account_] != 0 &&
                _canWithdraw(request, WithdrawManagerStorageLib.getLastReleaseFundsTimestamp()),
            withdrawWindowInSeconds: WithdrawManagerStorageLib.getWithdrawWindowInSeconds(),
            refundableFeeShares: totalFee - request.earnedFeeShares
        });
    }

    function getLastReleaseFundsTimestamp() external view returns (uint256) {
        return WithdrawManagerStorageLib.getLastReleaseFundsTimestamp();
    }

    function getSharesToRelease() external view returns (uint256) {
        return WithdrawManagerStorageLib.getSharesToRelease();
    }

    function updateWithdrawWindow(uint256 window_) external {
        _checkTemplatePermission(bytes4(keccak256("updateWithdrawWindow(uint256)")));
        WithdrawManagerStorageLib.updateWithdrawWindowLength(window_);
    }

    function getWithdrawWindow() external view returns (uint256) {
        return WithdrawManagerStorageLib.getWithdrawWindowInSeconds();
    }

    function updateWithdrawFee(uint256 fee_) external {
        if (configGate != address(0)) revert FeesInGate();
        _checkTemplatePermission(bytes4(keccak256("updateWithdrawFee(uint256)")));
        if (fee_ > 1e18) revert InvalidFee(fee_);
        WithdrawManagerStorageLib.setWithdrawFee(fee_);
    }

    function getWithdrawFee() external view returns (uint256) {
        return _withdrawFee();
    }

    function updateRequestFee(uint256 fee_) external {
        if (configGate != address(0)) revert FeesInGate();
        _checkTemplatePermission(bytes4(keccak256("updateRequestFee(uint256)")));
        if (fee_ > 1e18) revert InvalidFee(fee_);
        WithdrawManagerStorageLib.setRequestFee(fee_);
    }

    function getRequestFee() external view returns (uint256) {
        return _requestFee();
    }

    /// @notice Points the fees and split bps at the governance gate. First set with the fee-setter permission; after
    /// that only the current gate may move it (GATE_CONFIG_SPEC).
    function setConfigGate(address gate_) external {
        if (configGate == address(0)) _checkTemplatePermission(bytes4(keccak256("updateWithdrawFee(uint256)")));
        else if (msg.sender != configGate) revert UnauthorizedConfigurator(msg.sender, msg.sig);
        configGate = gate_;
        emit ConfigGateUpdated(gate_);
    }

    /// @notice The instant fee the vault keeps after the custody cut or the fee split, in bps (the LP exit limit).
    function retainedWithdrawFeeBps() external view returns (uint256) {
        uint256 feeBps = _withdrawFee() / 1e14;
        uint16[3] memory splitBps = _splitBpsNow();
        uint256 out = uint256(splitBps[0]) + splitBps[1] + splitBps[2];
        return out >= 10_000 ? 0 : feeBps * (10_000 - out) / 10_000;
    }

    function _withdrawFee() private view returns (uint256) {
        address gate = configGate;
        if (gate == address(0)) return WithdrawManagerStorageLib.getWithdrawFee();
        bytes32[] memory k = new bytes32[](1);
        k[0] = K.WM_WITHDRAW_FEE;
        return ICurveYieldConfigGate(gate).getMany(k)[0];
    }

    function _requestFee() private view returns (uint256) {
        address gate = configGate;
        if (gate == address(0)) return WithdrawManagerStorageLib.getRequestFee();
        bytes32[] memory k = new bytes32[](1);
        k[0] = K.WM_REQUEST_FEE;
        return ICurveYieldConfigGate(gate).getMany(k)[0];
    }

    function _splitBpsNow() private view returns (uint16[3] memory bps_) {
        address gate = configGate;
        if (gate == address(0)) return _splitBps;
        bytes32[] memory k = new bytes32[](3);
        (k[0], k[1], k[2]) = (K.WM_SPLIT_BPS_0, K.WM_SPLIT_BPS_1, K.WM_SPLIT_BPS_2);
        uint256[] memory v = ICurveYieldConfigGate(gate).getMany(k);
        (bps_[0], bps_[1], bps_[2]) = (uint16(v[0]), uint16(v[1]), uint16(v[2]));
    }

    function updatePlasmaVaultAddress(address plasmaVault_) external {
        _checkTemplatePermission(bytes4(keccak256("updatePlasmaVaultAddress(address)")));
        WithdrawManagerStorageLib.setPlasmaVaultAddress(plasmaVault_);
    }

    function getPlasmaVaultAddress() public view returns (address) {
        return WithdrawManagerStorageLib.getPlasmaVaultAddress();
    }

    function _initializeDefaults() private {
        WithdrawManagerStorageLib.updateWithdrawWindowLength(DEFAULT_WITHDRAW_WINDOW);
        WithdrawManagerStorageLib.setRequestFee(DEFAULT_REQUEST_FEE);
        WithdrawManagerStorageLib.setWithdrawFee(DEFAULT_WITHDRAW_FEE);
    }

    function _settleExistingRequest(address requester_) private returns (uint256 refund) {
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        CurveYieldRequestAccounting storage oldRequest = state.requests[requester_];
        if (oldRequest.initialNetShares == 0) return 0;
        if (oldRequest.active) {
            state.activeRequestedShares -= oldRequest.remainingShares;
            oldRequest.active = false;
        }
        _cancelReservation(requester_);
        _matureEscrowedFee(state, requester_);
        refund = uint256(oldRequest.totalFeeShares) - uint256(oldRequest.earnedFeeShares);
        if (refund != 0) {
            committedShares -= refund;
            _moveRequestFeeShares(address(this), requester_, refund);
        }
    }

    function _accrueEarnedFee(CurveYieldRequestAccounting storage request, address requester_) private {
        if (request.initialNetShares == 0 || request.totalFeeShares == 0) return;
        uint256 consumed = uint256(request.initialNetShares) - uint256(request.remainingShares) +
            _reservedShares[requester_];
        uint256 targetEarned = Math.mulDiv(
            request.totalFeeShares, consumed, request.initialNetShares, Math.Rounding.Ceil
        );
        uint256 alreadyEarned = request.earnedFeeShares;
        if (targetEarned > alreadyEarned) {
            uint256 newlyEarned = targetEarned - alreadyEarned;
            request.earnedFeeShares = targetEarned.toUint128();
            CurveYieldWithdrawalManagerStorageLib.layout().earnedFeeShares += newlyEarned;
        }
    }

    /// @dev v2: earned fees are burned at release, so there is nothing left in escrow to mature on redeem.
    function _matureClaimedFee(
        CurveYieldWithdrawalManagerStorageLib.Layout storage,
        CurveYieldRequestAccounting storage,
        address
    ) private pure {}

    function _matureEscrowedFee(
        CurveYieldWithdrawalManagerStorageLib.Layout storage state,
        address requester_
    ) private {
        uint256 amount = _escrowedEarnedFeeShares[requester_];
        if (amount != 0) {
            state.earnedFeeShares += amount;
            _totalEscrowedEarnedFeeShares -= amount;
            delete _escrowedEarnedFeeShares[requester_];
        }
        delete _claimedFeeShares[requester_];
    }

    function _burnEarnedFeesIfAny(bool strict_) private returns (uint256 burned) {
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        uint256 amount = state.earnedFeeShares;
        address fuse = state.burnRequestFeeFuse;
        if (amount == 0) return 0;
        if (fuse == address(0)) {
            if (strict_) revert InvalidBurnRequestFeeFuse(fuse);
            return 0;
        }
        state.earnedFeeShares = 0;
        uint16[3] memory splitBps = _splitBpsNow();
        if (splitRequestFee && splitBps[0] + splitBps[1] + splitBps[2] != 0) _paySplit(getPlasmaVaultAddress(), amount);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse, abi.encodeWithSignature("enter((uint256))", amount));
        if (strict_) {
            IPlasmaVaultKatana(getPlasmaVaultAddress()).execute(actions);
            committedShares -= amount;
            emit EarnedFeeSharesBurned(amount);
            return amount;
        }
        try IPlasmaVaultKatana(getPlasmaVaultAddress()).execute(actions) {
            committedShares -= amount;
            emit EarnedFeeSharesBurned(amount);
            burned = amount;
        } catch {
            state.earnedFeeShares = amount;
            emit EarnedFeeBurnDeferred(amount);
        }
    }

    function _canWithdraw(
        CurveYieldRequestAccounting storage request,
        uint256 releaseTimestamp_
    ) private view returns (bool) {
        if (!request.active) return false;
        uint256 window = WithdrawManagerStorageLib.getWithdrawWindowInSeconds();
        uint256 end = request.endWithdrawWindowTimestamp;
        if (end < window) return false;
        uint256 requestTimestamp = end - window;
        return block.timestamp >= requestTimestamp && block.timestamp <= end && requestTimestamp < releaseTimestamp_;
    }

    function _releasable(
        CurveYieldRequestAccounting storage request,
        uint64 generation_,
        uint256 timestamp_
    ) private view returns (bool) {
        if (!request.active || request.generation != generation_ || block.timestamp > request.endWithdrawWindowTimestamp) {
            return false;
        }
        uint256 window = WithdrawManagerStorageLib.getWithdrawWindowInSeconds();
        return request.endWithdrawWindowTimestamp >= window &&
            request.endWithdrawWindowTimestamp - window < timestamp_;
    }

    function _cancelReservation(address requester_) private {
        uint256 reserved = _reservedShares[requester_];
        if (reserved == 0) return;
        delete _reservedShares[requester_];
        _totalReservedShares -= reserved;
        WithdrawManagerStorageLib.decreaseSharesToRelease(reserved);
    }

    function _moveRequestFeeShares(address from_, address to_, uint256 amount_) private {
        address fuse = CurveYieldWithdrawalManagerStorageLib.layout().requestFeeFuse;
        if (fuse == address(0)) revert InvalidRequestFeeFuse(fuse);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            fuse,
            abi.encodeWithSignature("moveRequestFeeShares(address,address,uint256)", from_, to_, amount_)
        );
        IPlasmaVaultKatana(getPlasmaVaultAddress()).execute(actions);
    }

    function _checkTemplatePermission(bytes4 selector_) private view {
        address caller = _msgSender();
        (bool immediate,) = IAccessManager(authority()).canCall(caller, ROLE_TEMPLATE_MANAGER, selector_);
        if (!immediate) revert UnauthorizedConfigurator(caller, selector_);
    }

    modifier onlyController() {
        address expected = CurveYieldWithdrawalManagerStorageLib.layout().controller;
        if (_msgSender() != expected || expected == address(0)) revert UnauthorizedController(_msgSender());
        _;
    }

    modifier onlyVault() {
        if (msg.sender != getPlasmaVaultAddress()) revert InvalidVaultCaller(msg.sender);
        _;
    }

    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}

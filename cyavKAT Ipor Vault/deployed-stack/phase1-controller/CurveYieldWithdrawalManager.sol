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

interface ICurveYieldWithdrawalProfitCustody {
    function revenueShareBps() external view returns (uint16);
}

/// @notice IPOR WithdrawManager derivative with an enumerable expiry queue and exact request-fee escrow.
/// @dev The vault-facing withdrawal checks preserve the upstream manager's release semantics.
contract CurveYieldWithdrawalManager is Initializable, AccessManagedUpgradeable, ContextClient {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    mapping(address requester => uint256 shares) private _reservedShares;
    mapping(address requester => uint256 shares) private _escrowedEarnedFeeShares;
    mapping(address requester => uint256 shares) private _claimedFeeShares;
    uint256 private _totalReservedShares;
    uint256 private _totalEscrowedEarnedFeeShares;

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
    error InvalidRevenueShare(uint256 revenueShareBps);

    event ControllerSet(address indexed controller);
    event ManagerDependenciesUpdated(address indexed controller, address indexed burnRequestFeeFuse, address indexed requestFeeFuse);
    event RequestReplaced(address indexed requester, uint256 refundedFeeShares);
    event RequestExpired(address indexed requester, uint256 remainingShares);
    event ExpiredRequestFeeRefunded(address indexed requester, uint256 refundedFeeShares);
    event EarnedFeeSharesBurned(uint256 amount);
    event EarnedFeeBurnDeferred(uint256 amount);
    event ProfitCustodyUpdated(address indexed custody);
    event ProfitCustodyFeeTransferred(uint256 feeShares, uint256 custodyShares, uint256 custodyAssets);

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
            grossShares_, WithdrawManagerStorageLib.getRequestFee(), 1e18, Math.Rounding.Ceil
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
        uint256 balance = ERC4626(ERC4626(plasmaVault).asset()).balanceOf(plasmaVault);
        uint256 availableShares = ERC4626(plasmaVault).convertToShares(balance);
        uint256 releasedShares = WithdrawManagerStorageLib.getSharesToRelease();
        uint256 feeRate = WithdrawManagerStorageLib.getWithdrawFee();
        if (feeRate != 0) feeSharesToBurn = Math.mulDiv(shares_, feeRate, 1e18);
        address custody;
        uint256 custodyFeeShares;
        uint256 custodyAssets;
        if (feeSharesToBurn != 0) {
            (custody, custodyFeeShares, custodyAssets) = _quoteCustodyFee(feeSharesToBurn);
        }
        uint256 requestedShares = shares_ + custodyFeeShares;
        if (availableShares < releasedShares + requestedShares) {
            revert InvalidUnallocatedShares(releasedShares, requestedShares, availableShares);
        }
        if (feeSharesToBurn != 0) {
            _transferCustodyFee(custody, feeSharesToBurn, custodyFeeShares, custodyAssets);
        }
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

    function releaseActiveShares(uint256 timestamp_, uint256 shares_) external onlyController {
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
    }

    function releaseFor(address requester_, uint256 timestamp_, uint256 shares_) external onlyController {
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
    }

    function activeUnreleasedShares() public view returns (uint256) {
        return activeRequestedShares() - _totalReservedShares;
    }

    function reservedSharesOf(address requester_) external view returns (uint256) {
        return _reservedShares[requester_];
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
        _checkTemplatePermission(bytes4(keccak256("updateWithdrawFee(uint256)")));
        if (fee_ > 1e18) revert InvalidFee(fee_);
        WithdrawManagerStorageLib.setWithdrawFee(fee_);
    }

    function getWithdrawFee() external view returns (uint256) {
        return WithdrawManagerStorageLib.getWithdrawFee();
    }

    function updateRequestFee(uint256 fee_) external {
        _checkTemplatePermission(bytes4(keccak256("updateRequestFee(uint256)")));
        if (fee_ > 1e18) revert InvalidFee(fee_);
        WithdrawManagerStorageLib.setRequestFee(fee_);
    }

    function getRequestFee() external view returns (uint256) {
        return WithdrawManagerStorageLib.getRequestFee();
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
            _escrowedEarnedFeeShares[requester_] += newlyEarned;
            _totalEscrowedEarnedFeeShares += newlyEarned;
        }
    }

    function _matureClaimedFee(
        CurveYieldWithdrawalManagerStorageLib.Layout storage state,
        CurveYieldRequestAccounting storage request,
        address requester_
    ) private {
        if (request.initialNetShares == 0 || request.totalFeeShares == 0) return;
        uint256 consumed = uint256(request.initialNetShares) - uint256(request.remainingShares);
        uint256 targetClaimed = Math.mulDiv(
            request.totalFeeShares, consumed, request.initialNetShares, Math.Rounding.Ceil
        );
        uint256 newlyClaimed = targetClaimed - _claimedFeeShares[requester_];
        _claimedFeeShares[requester_] = targetClaimed;
        _escrowedEarnedFeeShares[requester_] -= newlyClaimed;
        _totalEscrowedEarnedFeeShares -= newlyClaimed;
        state.earnedFeeShares += newlyClaimed;
    }

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

    function _burnEarnedFeesIfAny(bool strict_) private {
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        uint256 amount = state.earnedFeeShares;
        address fuse = state.burnRequestFeeFuse;
        if (amount == 0) return;
        if (fuse == address(0)) {
            if (strict_) revert InvalidBurnRequestFeeFuse(fuse);
            return;
        }
        (address custody, uint256 custodyFeeShares, uint256 custodyAssets) = _quoteCustodyFee(amount);

        state.earnedFeeShares = 0;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse, abi.encodeWithSignature("enter((uint256))", amount));
        if (strict_) {
            IPlasmaVaultKatana(getPlasmaVaultAddress()).execute(actions);
            _transferCustodyFee(custody, amount, custodyFeeShares, custodyAssets);
            emit EarnedFeeSharesBurned(amount);
            return;
        }
        try IPlasmaVaultKatana(getPlasmaVaultAddress()).execute(actions) {
            _transferCustodyFee(custody, amount, custodyFeeShares, custodyAssets);
            emit EarnedFeeSharesBurned(amount);
        } catch {
            state.earnedFeeShares = amount;
            emit EarnedFeeBurnDeferred(amount);
        }
    }

    function _transferCustodyFee(uint256 feeSharesToBurn) private {
        if (feeSharesToBurn == 0) return;
        (address custody, uint256 custodyFeeShares, uint256 custodyAssets) =
            _quoteCustodyFee(feeSharesToBurn);
        _transferCustodyFee(custody, feeSharesToBurn, custodyFeeShares, custodyAssets);
    }

    function _quoteCustodyFee(uint256 feeSharesToBurn)
        private view returns (address custody, uint256 custodyFeeShares, uint256 custodyAssets)
    {
        CurveYieldWithdrawalManagerStorageLib.Layout storage state =
            CurveYieldWithdrawalManagerStorageLib.layout();
        custody = state.profitCustody;
        if (custody == address(0)) revert InvalidProfitCustody(custody);
        uint256 shareBps = ICurveYieldWithdrawalProfitCustody(custody).revenueShareBps();
        if (shareBps > 3_500) revert InvalidRevenueShare(shareBps);
        custodyFeeShares = Math.mulDiv(feeSharesToBurn, shareBps, 10_000);
        if (custodyFeeShares == 0) return (custody, 0, 0);
        address plasmaVault_ = getPlasmaVaultAddress();
        custodyAssets = ERC4626(plasmaVault_).convertToAssets(custodyFeeShares);
    }

    function _transferCustodyFee(
        address custody, uint256 feeSharesToBurn, uint256 custodyFeeShares, uint256 custodyAssets
    ) private {
        if (custodyAssets != 0) {
            address plasmaVault_ = getPlasmaVaultAddress();
            IERC20(ERC4626(plasmaVault_).asset()).safeTransferFrom(plasmaVault_, custody, custodyAssets);
        }
        emit ProfitCustodyFeeTransferred(feeSharesToBurn, custodyFeeShares, custodyAssets);
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

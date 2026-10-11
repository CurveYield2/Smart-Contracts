// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "contracts/interfaces/IPlasmaVaultBase.sol";

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

interface ICurveYieldCallerRewardFuseConfig {
    function CONTROLLER() external view returns (address);
    function sourceFuse(uint8 actionId) external view returns (address);
    function rewardConfig(uint8 actionId) external view returns (uint16 rewardBps, uint128 maxRewardAvkat);
    function extraWindupCallerRewardBps() external view returns (uint16);
    function WITHDRAW_MANAGER() external view returns (address);
    function quoteMorphoReward(uint8 actionId, uint256 basisAvkat, uint256 excessProfitAvkat)
        external view returns (uint256 amount);
}

interface ICurveYieldHarvestExecutor {
    function harvestActive() external view returns (bool);
}

/// @notice Owner-configured, action-sourced avKAT caller reward fuse with no accounting market.
contract CurveYieldCallerRewardFuse is Ownable2Step {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant MARKET_ID = 0;
    uint16 public constant MAX_REWARD_BPS = 300;
    uint256 public constant MAX_REWARD_CAP = 100 ether;
    uint16 public constant MAX_EXTRA_WINDUP_REWARD_BPS = 1_000;
    uint8 public constant ACTION_COUNT = 4;
    uint8 public constant ACTION_DEPLOY_ASSETS = 0;
    uint8 public constant ACTION_HARVEST = 1;
    uint8 public constant ACTION_FULFILL_ALL = 2;
    uint8 public constant ACTION_EMERGENCY_REPAY = 3;
    bytes32 private constant CONSUMED = bytes32(type(uint256).max);

    address public immutable VERSION;
    address public immutable VAULT;
    address public immutable AVKAT;

    address public CONTROLLER;
    address public WITHDRAW_MANAGER;
    mapping(uint8 actionId => address source) public sourceFuse;
    mapping(uint8 actionId => RewardConfig config) public rewardConfig;
    uint16 public extraWindupCallerRewardBps = 500;

    struct RewardConfig {
        uint16 rewardBps;
        uint128 maxRewardAvkat;
    }

    error InvalidAddress();
    error WrongImplementationContext();
    error WrongVaultContext();
    error UnauthorizedCaller(address caller);
    error InvalidActionId(uint8 actionId);
    error RewardConfigTooHigh(uint256 rewardBps, uint256 rewardCap);
    error ExtraRewardTooHigh(uint256 rewardBps);
    error InvalidSourceOutput();
    error RewardExceedsLimit(uint256 reward, uint256 limit);
    error RewardAmountMismatch(uint256 supplied, uint256 expected);
    error InvalidRecipient(address recipient);
    error InsufficientBalance(uint256 available, uint256 requested);
    error UnexpectedBalanceDelta();
    error HarvestInactive();
    error InvalidFeeMovement(address from, address to);

    event CallerRewardConfigUpdated(uint8 indexed actionId, uint16 rewardBps, uint256 maxRewardAvkat);
    event ExtraWindupCallerRewardUpdated(uint16 rewardBps);
    event ControllerUpdated(address indexed controller);
    event SourceFuseUpdated(uint8 indexed actionId, address indexed source);
    event CallerRewardValidated(uint8 indexed actionId, address indexed source, address indexed recipient, uint256 amount);
    event CallerRewardPaid(uint8 indexed actionId, address indexed source, address indexed recipient, uint256 amount);
    event WithdrawManagerUpdated(address indexed manager);
    event RequestFeeSharesMoved(address indexed manager, address indexed from, address indexed to, uint256 amount);
    event ManagerAssetAllowanceConfigured(address indexed manager, address indexed previousManager);

    constructor(address owner_, address vault_, address avkat_) Ownable(owner_) {
        if (owner_ == address(0) || vault_ == address(0) || avkat_ == address(0)) {
            revert InvalidAddress();
        }
        VERSION = address(this);
        VAULT = vault_;
        AVKAT = avkat_;
        rewardConfig[ACTION_DEPLOY_ASSETS] = RewardConfig(20, uint128(10 ether));
        rewardConfig[ACTION_HARVEST] = RewardConfig(20, uint128(5 ether));
        rewardConfig[ACTION_FULFILL_ALL] = RewardConfig(20, uint128(10 ether));
        rewardConfig[ACTION_EMERGENCY_REPAY] = RewardConfig(20, uint128(10 ether));
    }

    function setController(address controller_) external onlyOwner {
        _requireImplementation();
        if (controller_ == address(0)) revert InvalidAddress();
        CONTROLLER = controller_;
        emit ControllerUpdated(controller_);
    }

    function setWithdrawManager(address manager_) external onlyOwner {
        _requireImplementation();
        if (manager_ == address(0)) revert InvalidAddress();
        WITHDRAW_MANAGER = manager_;
        emit WithdrawManagerUpdated(manager_);
    }

    function setSourceFuse(uint8 actionId_, address source_) external onlyOwner {
        _requireImplementation();
        _requireAction(actionId_);
        if (source_ == address(0)) revert InvalidAddress();
        sourceFuse[actionId_] = source_;
        emit SourceFuseUpdated(actionId_, source_);
    }

    function setCallerRewardConfig(uint8 actionId_, uint16 rewardBps_, uint256 maxRewardAvkat_) external onlyOwner {
        _requireImplementation();
        _requireAction(actionId_);
        if (rewardBps_ > MAX_REWARD_BPS || maxRewardAvkat_ > MAX_REWARD_CAP) {
            revert RewardConfigTooHigh(rewardBps_, maxRewardAvkat_);
        }
        rewardConfig[actionId_] = RewardConfig(rewardBps_, uint128(maxRewardAvkat_));
        emit CallerRewardConfigUpdated(actionId_, rewardBps_, maxRewardAvkat_);
    }

    function setExtraWindupCallerRewardBps(uint16 rewardBps_) external onlyOwner {
        _requireImplementation();
        if (rewardBps_ > MAX_EXTRA_WINDUP_REWARD_BPS) revert ExtraRewardTooHigh(rewardBps_);
        extraWindupCallerRewardBps = rewardBps_;
        emit ExtraWindupCallerRewardUpdated(rewardBps_);
    }

    /// @notice Returns the exact caller reward allowed for a Morpho strategy action.
    /// @dev All Morpho reward percentages and caps are owned and enforced by this fuse.
    function quoteMorphoReward(
        uint8 actionId_,
        uint256 basisAvkat_,
        uint256 excessProfitAvkat_
    ) public view returns (uint256 amount) {
        _requireAction(actionId_);
        if (actionId_ == ACTION_HARVEST ||
            (actionId_ != ACTION_DEPLOY_ASSETS && excessProfitAvkat_ != 0)) {
            revert InvalidSourceOutput();
        }
        if (actionId_ == ACTION_DEPLOY_ASSETS) {
            (amount,,) = quoteDeployRewardSplit(basisAvkat_, 0, excessProfitAvkat_);
            return amount;
        }
        RewardConfig memory config = rewardConfig[actionId_];
        amount = basisAvkat_ * config.rewardBps / 10_000;
        uint256 hardPercentageCap = basisAvkat_ * MAX_REWARD_BPS / 10_000;
        if (amount > hardPercentageCap) amount = hardPercentageCap;
        if (amount > config.maxRewardAvkat) amount = config.maxRewardAvkat;
    }

    /// @notice Applies the single deploy-action cap once, then allocates it pro rata to its two funding sources.
    function quoteDeployRewardSplit(uint256 morphoBasisAvkat_, uint256 vkatBasisAvkat_, uint256 excessProfitAvkat_)
        public view returns (uint256 total_, uint256 morpho_, uint256 vkat_)
    {
        RewardConfig memory config = rewardConfig[ACTION_DEPLOY_ASSETS];
        uint256 rawMorpho = morphoBasisAvkat_ * config.rewardBps / 10_000 +
            excessProfitAvkat_ * extraWindupCallerRewardBps / 10_000;
        uint256 rawVkat = vkatBasisAvkat_ * config.rewardBps / 10_000;
        uint256 rawTotal = rawMorpho + rawVkat;
        if (rawTotal == 0) return (0, 0, 0);
        total_ = rawTotal;
        uint256 hardPercentageCap = (morphoBasisAvkat_ + vkatBasisAvkat_) * MAX_REWARD_BPS / 10_000;
        if (total_ > hardPercentageCap) total_ = hardPercentageCap;
        if (total_ > config.maxRewardAvkat) total_ = config.maxRewardAvkat;
        morpho_ = Math.mulDiv(rawMorpho, total_, rawTotal);
        vkat_ = total_ - morpho_;
    }

    /// @notice Validates and consumes a reward already funded by the bound action fuse.
    function enter(uint8 actionId_, address recipient_) external returns (uint256 amount) {
        if (address(this) != VAULT) revert WrongVaultContext();
        _requireAction(actionId_);
        ICurveYieldCallerRewardFuseConfig config = ICurveYieldCallerRewardFuseConfig(VERSION);
        if (msg.sender != config.CONTROLLER()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (recipient_ == address(0) || recipient_ == VAULT) revert InvalidRecipient(recipient_);

        address source = config.sourceFuse(actionId_);
        if (source == address(0)) revert InvalidSourceOutput();
        bytes32[] memory result = TransientStorageLib.getOutputs(source);
        if (result.length != 4 || result[0] != bytes32(uint256(actionId_))) revert InvalidSourceOutput();
        uint256 basis = uint256(result[1]);
        uint256 excessProfit = uint256(result[2]);
        amount = uint256(result[3]);
        if (actionId_ != ACTION_DEPLOY_ASSETS && excessProfit != 0) revert InvalidSourceOutput();
        uint256 expected = ICurveYieldCallerRewardFuseConfig(VERSION).quoteMorphoReward(
            actionId_, basis, excessProfit
        );
        if (amount != expected) revert RewardAmountMismatch(amount, expected);

        result[0] = CONSUMED;
        TransientStorageLib.setOutputs(source, result);
        emit CallerRewardValidated(actionId_, source, recipient_, amount);
    }

    /// @notice Forwards only the configured harvest reward already received from the swap fuse.
    /// @dev The vault invokes this during a live executor harvest; the executor pays its own caller.
    function forwardHarvestReward(uint256 basisAvkat_, uint256 amount_) external {
        _requireImplementation();
        if (msg.sender != VAULT) revert UnauthorizedCaller(msg.sender);
        if (amount_ > basisAvkat_) revert InvalidSourceOutput();
        address controller = CONTROLLER;
        address source = sourceFuse[ACTION_HARVEST];
        if (controller == address(0) || source == address(0)) revert InvalidSourceOutput();
        if (!ICurveYieldHarvestExecutor(controller).harvestActive()) revert HarvestInactive();
        RewardConfig memory config = rewardConfig[ACTION_HARVEST];
        uint256 maximum = basisAvkat_ * config.rewardBps / 10_000;
        if (maximum > config.maxRewardAvkat) maximum = config.maxRewardAvkat;
        if (amount_ > maximum) revert RewardExceedsLimit(amount_, maximum);
        if (amount_ == 0) return;

        IERC20 token = IERC20(AVKAT);
        uint256 sourceBefore = token.balanceOf(address(this));
        if (sourceBefore < amount_) revert InsufficientBalance(sourceBefore, amount_);
        uint256 destinationBefore = token.balanceOf(controller);
        token.safeTransfer(controller, amount_);
        if (sourceBefore - token.balanceOf(address(this)) != amount_ ||
            token.balanceOf(controller) - destinationBefore != amount_) revert UnexpectedBalanceDelta();
        emit CallerRewardPaid(ACTION_HARVEST, source, controller, amount_);
    }

    /// @notice Moves only request-fee shares to or from the configured manager in vault context.
    function moveRequestFeeShares(address from_, address to_, uint256 amount_) external {
        address manager = _requireWithdrawalManagerContext();
        if (amount_ == 0) return;
        if (from_ != manager && to_ != manager) revert InvalidFeeMovement(from_, to_);
        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, from_, to_, amount_)
        );
        emit RequestFeeSharesMoved(manager, from_, to_, amount_);
    }

    /// @notice Rotates the vault-asset allowance used for the manager's atomic custody transfers.
    function configureManagerAssetAllowance(address previousManager_) external {
        address manager = _requireWithdrawalManagerContext();
        IERC20 token = IERC20(AVKAT);
        if (previousManager_ != address(0) && previousManager_ != manager) {
            token.forceApprove(previousManager_, 0);
        }
        token.forceApprove(manager, type(uint256).max);
        emit ManagerAssetAllowanceConfigured(manager, previousManager_);
    }

    function _requireImplementation() private view {
        if (address(this) != VERSION) revert WrongImplementationContext();
    }

    function _requireAction(uint8 actionId_) private pure {
        if (actionId_ >= ACTION_COUNT) revert InvalidActionId(actionId_);
    }

    function _requireWithdrawalManagerContext() private view returns (address manager) {
        if (address(this) != VAULT) revert WrongVaultContext();
        manager = ICurveYieldCallerRewardFuseConfig(VERSION).WITHDRAW_MANAGER();
        if (manager == address(0) || msg.sender != manager) revert UnauthorizedCaller(msg.sender);
    }
}

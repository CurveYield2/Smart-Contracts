// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {VkatFuseStorageLib} from "../../contracts/VkatFuseStorageLib.sol";

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

interface ICurveYieldVkatErc20 {
    function balanceOf(address account_) external view returns (uint256);
    function transfer(address recipient_, uint256 amount_) external returns (bool);
}

interface ICurveYieldVkatAvkat is ICurveYieldVkatErc20 {
    function previewRedeem(uint256 shares_) external view returns (uint256 assets_);
    function previewMint(uint256 shares_) external view returns (uint256 assets_);
    function convertToShares(uint256 assets_) external view returns (uint256 shares_);
    function depositTokenId(uint256 tokenId_, address receiver_) external returns (uint256 shares_);
    function withdrawTokenId(uint256 assets_, address receiver_, address owner_) external returns (uint256 tokenId_);
}

interface ICurveYieldVkatEscrow {
    function minDeposit() external view returns (uint256);
    function canSplit(address account_) external view returns (bool);
    function locked(uint256 tokenId_) external view returns (uint256 amount_, uint256 start_);
    function ownedTokens(address owner_) external view returns (uint256[] memory tokenIds_);
    function split(uint256 tokenId_, uint256 amount_) external returns (uint256 splitTokenId_);
    function merge(uint256 fromTokenId_, uint256 toTokenId_) external;
}

interface ICurveYieldVkatNft {
    function ownerOf(uint256 tokenId_) external view returns (address owner_);
    function approve(address spender_, uint256 tokenId_) external;
}

interface ICurveYieldVkatEpochClock {
    function elapsedInEpoch() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function epochVoteEndsIn() external view returns (uint256);
}

interface ICurveYieldVkatDelegationAdapter {
    function delegate(address delegatee_) external;
    function delegates(address account_) external view returns (address);
}

interface ICurveYieldVkatGaugeVoter {
    struct GaugeVote {
        uint256 weight;
        address gauge;
    }

    function votingActive() external view returns (bool);
    function vote(GaugeVote[] calldata votes_) external;
    function reset() external;
    function gaugeExists(address gauge_) external view returns (bool);
    function isActive(address gauge_) external view returns (bool);
}

interface ICurveYieldVkatRewardQuote {
    function quoteMorphoReward(uint8 actionId_, uint256 basisAvkat_, uint256 excessProfitAvkat_)
        external view returns (uint256 amount_);
    function quoteDeployRewardSplit(uint256 morphoBasisAvkat_, uint256 vkatBasisAvkat_, uint256 excessProfitAvkat_)
        external view returns (uint256 total_, uint256 morpho_, uint256 vkat_);
}

interface ICurveYieldVkatMorphoStrategy {
    function morphoAllocationBps() external view returns (uint16);
    function totalManagedAvkat() external view returns (uint256);
}

struct CurveYieldVkatStrategyDependencies {
    address morphoStrategyFuse;
    address callerRewardFuse;
}

interface ICurveYieldVkatStrategyConfig {
    function CONTROLLER() external view returns (address);
    function vkatAllocationBps() external view returns (uint16);
    function dependencies() external view returns (CurveYieldVkatStrategyDependencies memory);
    function voteTargets() external view returns (address[] memory gauges_, uint256[] memory weights_);
}

/// @notice Window-aware vKAT lifecycle coordinator which delegates protocol operations to registered fuses.
contract CurveYieldVkatStrategyFuse is IFuseCommon, Ownable2Step {
    uint256 public constant MARKET_ID = 0;
    uint16 public constant MAX_VKAT_ALLOCATION_BPS = 9_000;
    uint16 public constant MAX_COMBINED_ALLOCATION_BPS = 9_000;
    uint256 public constant VKAT_DEPLOY_WINDOW = 3 days;
    uint8 private constant ACTION_DEPLOY_ASSETS = 0;
    uint256 private constant VKAT_SUBSTRATE_MARKET_ID = 54;

    address public immutable VAULT;
    address public constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    ICurveYieldVkatNft public constant VKAT =
        ICurveYieldVkatNft(0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d);
    ICurveYieldVkatEscrow public constant ESCROW =
        ICurveYieldVkatEscrow(0x4d6fC15Ca6258b168225D283262743C623c13Ead);
    ICurveYieldVkatEpochClock public constant EPOCH_CLOCK =
        ICurveYieldVkatEpochClock(0x17049d374A2bcdA70F8939C21ad92bcF6B2A95ab);
    ICurveYieldVkatDelegationAdapter public constant DELEGATION_ADAPTER =
        ICurveYieldVkatDelegationAdapter(0xB67Ac05e2C1d8592692a90BF61712274b988f25A);
    ICurveYieldVkatGaugeVoter public constant GAUGE_VOTER =
        ICurveYieldVkatGaugeVoter(0x5e755A3C5dc81A79DE7a7cEF192FFA60964c9352);

    address public immutable VERSION;
    address public CONTROLLER;
    uint16 public vkatAllocationBps = 3_000;

    CurveYieldVkatStrategyDependencies private _dependencies;
    address[] private _gauges;
    uint256[] private _weights;

    error InvalidAddress();
    error InvalidDependencies();
    error WrongImplementationContext();
    error WrongVaultContext();
    error UnauthorizedCaller(address caller_);
    error VkatAllocationTooHigh(uint256 allocationBps_);
    error CombinedAllocationTooHigh(uint256 morphoBps_, uint256 vkatBps_);
    error InvalidVoteTargets();
    error InvalidMorphoResult();
    error InvalidDeployPlan();
    error InsufficientRewardReserve(uint256 available_, uint256 required_);
    error InvalidInstantWithdrawalParams();
    error InvalidConversionAmount();
    error WrongNftOwner(uint256 tokenId_);
    error InvalidSplitToken(uint256 tokenId_);
    error ShareReturnMismatch(uint256 returned_, uint256 observed_);
    error SharesReceivedTooLow(uint256 received_, uint256 minimum_);
    error InvalidTemporaryToken(uint256 tokenId_);
    error MergeAmountMismatch(uint256 observed_, uint256 expected_);
    error SharesSpentTooHigh(uint256 spent_, uint256 maximum_);
    error NoTrackedVkat();
    error NotSelfDelegated();
    error GaugeNotGranted(address gauge_);
    error GaugeNotActive(address gauge_);

    event ControllerUpdated(address indexed controller_);
    event DependenciesUpdated(CurveYieldVkatStrategyDependencies dependencies_);
    event VkatAllocationUpdated(uint16 allocationBps_);
    event VoteTargetsUpdated(address[] gauges_, uint256[] weights_);
    event DeployRewardPublished(uint256 morphoBasis_, uint256 vkatBasis_, uint256 excessProfit_, uint256 reward_);
    event VkatDeployFinalized(uint256 avkatConverted_, bool voteDispatched_);
    event VkatPartiallyConverted(
        uint256 indexed originalTokenId_, uint256 indexed splitTokenId_, uint256 katAmount_, uint256 sharesReceived_
    );
    event VkatFullyConverted(uint256 indexed tokenId_, uint256 katAmount_, uint256 sharesReceived_);
    event AvKatMergedIntoVkat(
        uint256 indexed temporaryTokenId_, uint256 indexed destinationTokenId_, uint256 katAssets_, uint256 sharesSpent_
    );

    constructor(
        address owner_,
        address controller_,
        address vault_,
        CurveYieldVkatStrategyDependencies memory dependencies_,
        address[] memory gauges_,
        uint256[] memory weights_
    ) Ownable(owner_) {
        if (owner_ == address(0) || controller_ == address(0) || vault_ == address(0)) revert InvalidAddress();
        VERSION = address(this);
        CONTROLLER = controller_;
        VAULT = vault_;
        _setDependencies(dependencies_);
        _setVoteTargets(gauges_, weights_);
    }

    function setController(address controller_) external onlyOwner {
        _requireImplementation();
        if (controller_ == address(0)) revert InvalidAddress();
        CONTROLLER = controller_;
        emit ControllerUpdated(controller_);
    }

    function setDependencies(CurveYieldVkatStrategyDependencies calldata dependencies_) external onlyOwner {
        _requireImplementation();
        _setDependencies(dependencies_);
    }

    function setVkatAllocationBps(uint16 allocationBps_) external onlyOwner {
        _requireImplementation();
        if (allocationBps_ > MAX_VKAT_ALLOCATION_BPS) revert VkatAllocationTooHigh(allocationBps_);
        uint16 morphoBps = ICurveYieldVkatMorphoStrategy(_dependencies.morphoStrategyFuse).morphoAllocationBps();
        if (uint256(morphoBps) + allocationBps_ > MAX_COMBINED_ALLOCATION_BPS) {
            revert CombinedAllocationTooHigh(morphoBps, allocationBps_);
        }
        vkatAllocationBps = allocationBps_;
        emit VkatAllocationUpdated(allocationBps_);
    }

    function setVoteTargets(address[] calldata gauges_, uint256[] calldata weights_) external onlyOwner {
        _requireImplementation();
        _setVoteTargets(gauges_, weights_);
    }

    function dependencies() external view returns (CurveYieldVkatStrategyDependencies memory) {
        return _dependencies;
    }

    function voteTargets() external view returns (address[] memory gauges_, uint256[] memory weights_) {
        return (_gauges, _weights);
    }

    function vkatAllocationActive() public view returns (bool) {
        return GAUGE_VOTER.votingActive() && EPOCH_CLOCK.epochVoteEndsIn() <= VKAT_DEPLOY_WINDOW;
    }

    /// @notice vKAT can be returned to avKAT only during the first half of the live two-week epoch.
    function vkatConversionAvailable() public view returns (bool) {
        return EPOCH_CLOCK.elapsedInEpoch() < EPOCH_CLOCK.epochDuration() / 2 && ESCROW.canSplit(VAULT);
    }

    function convertibleVkatAvkat() external view returns (uint256) {
        return vkatConversionAvailable() ? _vkatBalanceAvkat() : 0;
    }

    /// @notice Makes an exact amount of avKAT available using the same partial-vKAT path as instant withdrawal.
    function convertNeeded(uint256 requestedShares_) external returns (uint256 sharesReceived_) {
        _requireVaultExecution();
        sharesReceived_ = _convertNeededShares(requestedShares_);
    }

    function exit(uint256 tokenId_, uint256 requestedKat_, uint256 minSharesReceived_)
        external returns (uint256 sharesReceived_)
    {
        _requireVaultExecution();
        sharesReceived_ = _exit(tokenId_, requestedKat_, minSharesReceived_);
    }

    function exitWhole(uint256 tokenId_, uint256 minSharesReceived_) external returns (uint256 sharesReceived_) {
        _requireVaultExecution();
        _validateTrackedOwner(tokenId_);
        (uint256 lockedKat,) = ESCROW.locked(tokenId_);
        sharesReceived_ = _exitWhole(tokenId_, lockedKat, minSharesReceived_);
    }

    /// @notice Supplies the remaining avKAT requested by IPOR's instant-withdrawal flow.
    function instantWithdraw(bytes32[] calldata params_) external {
        if (address(this) != VAULT) revert WrongVaultContext();
        if (params_.length == 0) revert InvalidInstantWithdrawalParams();
        _convertNeededShares(uint256(params_[0]));
    }

    /// @notice Aggregates Morpho work with planned avKAT-to-vKAT work and publishes one exact reward result.
    function publishDeployReward() external {
        _requireActionContext();
        CurveYieldVkatStrategyDependencies memory deps = _deps();
        bytes32[] memory morphoResult = TransientStorageLib.getOutputs(deps.morphoStrategyFuse);
        if (morphoResult.length != 4 || uint256(morphoResult[0]) != ACTION_DEPLOY_ASSETS) {
            revert InvalidMorphoResult();
        }

        uint256 morphoBasis = uint256(morphoResult[1]);
        uint256 excessProfit = uint256(morphoResult[2]);
        uint256 idle = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        (bool allocationActive, uint256 vkatBasis, uint256 reward, uint256 morphoReward, uint256 vkatReward) =
            _planVkatDeployment(deps, morphoBasis, excessProfit, idle);

        bytes32[] memory plan = new bytes32[](4);
        plan[0] = bytes32(vkatBasis);
        plan[1] = bytes32(morphoReward);
        plan[2] = bytes32(vkatReward);
        plan[3] = bytes32(uint256(allocationActive ? 1 : 0));
        TransientStorageLib.setInputs(VERSION, plan);

        bytes32[] memory output = new bytes32[](4);
        output[0] = bytes32(uint256(ACTION_DEPLOY_ASSETS));
        output[1] = bytes32(morphoBasis + vkatBasis);
        output[2] = bytes32(excessProfit);
        output[3] = bytes32(reward);
        TransientStorageLib.setOutputs(VERSION, output);

        emit DeployRewardPublished(morphoBasis, vkatBasis, excessProfit, reward);
    }

    /// @notice After the reward payment, converts only the cap-limited plan and refreshes the configured vote.
    function finalizeDeploy() external {
        _requireActionContext();
        bytes32[] memory plan = TransientStorageLib.getInputs(VERSION);
        if (plan.length != 4) revert InvalidDeployPlan();
        bool allocationActive = uint256(plan[3]) == 1;
        TransientStorageLib.clearInputs(VERSION);
        uint256 vkatReward = uint256(plan[2]);
        _fundController(vkatReward);
        if (!allocationActive) {
            emit VkatDeployFinalized(0, false);
            return;
        }

        uint256 idle = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        uint256 gross = uint256(plan[0]);
        if (gross < vkatReward) revert InvalidDeployPlan();
        uint256 planned = gross - vkatReward;
        if (idle < planned) revert InvalidDeployPlan();

        VkatFuseStorageLib.TokenIds storage ids = VkatFuseStorageLib.tokenIds();
        bool converts = planned != 0;
        bool hasPosition = ids.values.length != 0;
        bool dispatchVote = GAUGE_VOTER.votingActive() && (hasPosition || converts);
        if (converts && hasPosition) _mergeIntoPosition(ids.values[ids.values.length - 1], planned);
        if (converts && !hasPosition) _createPosition(planned);
        if (!converts && !dispatchVote) {
            emit VkatDeployFinalized(0, false);
            return;
        }
        if (dispatchVote) _refreshVote();
        emit VkatDeployFinalized(planned, dispatchVote);
    }

    function _vkatBalanceAvkat() private view returns (uint256 balance_) {
        uint256[] memory tokenIds = ESCROW.ownedTokens(VAULT);
        for (uint256 i; i < tokenIds.length; ++i) {
            (uint256 lockedKat,) = ESCROW.locked(tokenIds[i]);
            balance_ += ICurveYieldVkatAvkat(AVKAT).convertToShares(lockedKat);
        }
    }

    function _planVkatDeployment(
        CurveYieldVkatStrategyDependencies memory deps_, uint256 morphoBasis_, uint256 excessProfit_, uint256 idle_
    ) private view returns (
        bool allocationActive_, uint256 vkatBasis_, uint256 reward_, uint256 morphoReward_, uint256 vkatReward_
    ) {
        allocationActive_ = vkatAllocationActive();
        (uint256 reserve, uint256 capacity) = _vkatDeploymentBounds(deps_.morphoStrategyFuse);
        if (allocationActive_ && idle_ != 0) {
            uint256 available = idle_ > reserve ? idle_ - reserve : 0;
            vkatBasis_ = available < capacity ? available : capacity;
            for (uint256 i; i < 8; ++i) {
                (reward_, morphoReward_, vkatReward_) = ICurveYieldVkatRewardQuote(deps_.callerRewardFuse)
                    .quoteDeployRewardSplit(morphoBasis_, vkatBasis_, excessProfit_);
                uint256 protected = reserve + morphoReward_;
                uint256 deployable = idle_ > protected ? idle_ - protected : 0;
                uint256 nextBasis = deployable < capacity ? deployable : capacity;
                if (nextBasis == vkatBasis_) break;
                vkatBasis_ = nextBasis;
            }
            uint256 netVkat = vkatBasis_ > vkatReward_ ? vkatBasis_ - vkatReward_ : 0;
            if (netVkat == 0 || ICurveYieldVkatAvkat(AVKAT).previewRedeem(netVkat) < ESCROW.minDeposit()) {
                vkatBasis_ = 0;
            }
        }
        (reward_, morphoReward_, vkatReward_) = ICurveYieldVkatRewardQuote(deps_.callerRewardFuse)
            .quoteDeployRewardSplit(morphoBasis_, vkatBasis_, excessProfit_);
        if (idle_ < reserve + morphoReward_ + vkatBasis_) revert InsufficientRewardReserve(idle_, reward_);
    }

    function _vkatDeploymentBounds(address morphoStrategyFuse_)
        private view returns (uint256 reserve_, uint256 capacity_)
    {
        ICurveYieldVkatMorphoStrategy morpho = ICurveYieldVkatMorphoStrategy(morphoStrategyFuse_);
        uint256 managed = morpho.totalManagedAvkat();
        uint16 morphoBps = morpho.morphoAllocationBps();
        uint16 vkatBps = ICurveYieldVkatStrategyConfig(VERSION).vkatAllocationBps();
        if (uint256(morphoBps) + vkatBps > MAX_COMBINED_ALLOCATION_BPS) {
            revert CombinedAllocationTooHigh(morphoBps, vkatBps);
        }
        reserve_ = managed * (10_000 - morphoBps - vkatBps) / 10_000;
        uint256 limit = managed * vkatBps / 10_000;
        uint256 current = _vkatBalanceAvkat();
        capacity_ = limit > current ? limit - current : 0;
    }

    function _setDependencies(CurveYieldVkatStrategyDependencies memory dependencies_) private {
        if (
            dependencies_.morphoStrategyFuse == address(0) || dependencies_.callerRewardFuse == address(0)
        ) revert InvalidDependencies();
        _dependencies = dependencies_;
        emit DependenciesUpdated(dependencies_);
    }

    function _setVoteTargets(address[] memory gauges_, uint256[] memory weights_) private {
        if (gauges_.length == 0 || gauges_.length != weights_.length) revert InvalidVoteTargets();
        delete _gauges;
        delete _weights;
        for (uint256 i; i < gauges_.length; ++i) {
            if (gauges_[i] == address(0) || weights_[i] == 0) revert InvalidVoteTargets();
            _gauges.push(gauges_[i]);
            _weights.push(weights_[i]);
        }
        emit VoteTargetsUpdated(gauges_, weights_);
    }

    function _deps() private view returns (CurveYieldVkatStrategyDependencies memory) {
        return ICurveYieldVkatStrategyConfig(VERSION).dependencies();
    }

    function _convertNeededShares(uint256 requestedShares_) private returns (uint256 sharesReceived_) {
        if (requestedShares_ == 0 || !vkatConversionAvailable()) return 0;
        uint256 beforeBalance = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        uint256 remaining = requestedShares_;
        VkatFuseStorageLib.TokenIds storage ids = VkatFuseStorageLib.tokenIds();
        while (ids.values.length != 0 && remaining != 0) {
            uint256 tokenId = ids.values[ids.values.length - 1];
            (uint256 lockedKat,) = ESCROW.locked(tokenId);
            uint256 wholeShares = ICurveYieldVkatAvkat(AVKAT).convertToShares(lockedKat);
            uint256 received;
            if (wholeShares <= remaining) {
                received = _exitWhole(tokenId, lockedKat, 0);
            } else {
                uint256 requestedKat = ICurveYieldVkatAvkat(AVKAT).previewMint(remaining);
                uint256 minimum = ESCROW.minDeposit();
                if (requestedKat < minimum) break;
                if (lockedKat - requestedKat < minimum) {
                    received = _exitWhole(tokenId, lockedKat, 0);
                } else {
                    received = _exit(tokenId, requestedKat, 0);
                }
            }
            remaining = received >= remaining ? 0 : remaining - received;
        }
        sharesReceived_ = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT) - beforeBalance;
    }

    function _exit(uint256 tokenId_, uint256 requestedKat_, uint256 minSharesReceived_)
        private returns (uint256 sharesReceived_)
    {
        _validateTrackedOwner(tokenId_);
        (uint256 lockedKat,) = ESCROW.locked(tokenId_);
        if (requestedKat_ == 0 || requestedKat_ > lockedKat) revert InvalidConversionAmount();
        if (requestedKat_ == lockedKat) return _exitWhole(tokenId_, lockedKat, minSharesReceived_);
        uint256 minimum = ESCROW.minDeposit();
        if (requestedKat_ < minimum || lockedKat - requestedKat_ < minimum) revert InvalidConversionAmount();
        uint256 splitTokenId = ESCROW.split(tokenId_, requestedKat_);
        if (splitTokenId == tokenId_ || VKAT.ownerOf(splitTokenId) != VAULT) revert InvalidSplitToken(splitTokenId);
        (uint256 splitLockedKat,) = ESCROW.locked(splitTokenId);
        if (splitLockedKat != requestedKat_) revert InvalidSplitToken(splitTokenId);
        sharesReceived_ = _depositNft(splitTokenId, minSharesReceived_);
        emit VkatPartiallyConverted(tokenId_, splitTokenId, requestedKat_, sharesReceived_);
    }

    function _exitWhole(uint256 tokenId_, uint256 lockedKat_, uint256 minSharesReceived_)
        private returns (uint256 sharesReceived_)
    {
        _validateTrackedOwner(tokenId_);
        sharesReceived_ = _depositNft(tokenId_, minSharesReceived_);
        VkatFuseStorageLib.remove(tokenId_);
        emit VkatFullyConverted(tokenId_, lockedKat_, sharesReceived_);
    }

    function _depositNft(uint256 tokenId_, uint256 minSharesReceived_) private returns (uint256 sharesReceived_) {
        uint256 beforeBalance = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        VKAT.approve(AVKAT, tokenId_);
        uint256 returned = ICurveYieldVkatAvkat(AVKAT).depositTokenId(tokenId_, VAULT);
        sharesReceived_ = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT) - beforeBalance;
        if (returned != sharesReceived_) revert ShareReturnMismatch(returned, sharesReceived_);
        if (sharesReceived_ < minSharesReceived_) revert SharesReceivedTooLow(sharesReceived_, minSharesReceived_);
    }

    function _mergeIntoPosition(uint256 destinationTokenId_, uint256 maximumShares_) private {
        _validateTrackedOwner(destinationTokenId_);
        uint256 sharesBefore = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        if (maximumShares_ == 0 || sharesBefore < maximumShares_) revert InvalidConversionAmount();
        uint256 katAssets = ICurveYieldVkatAvkat(AVKAT).previewRedeem(maximumShares_);
        (uint256 destinationBefore,) = ESCROW.locked(destinationTokenId_);
        uint256 temporaryTokenId = ICurveYieldVkatAvkat(AVKAT).withdrawTokenId(katAssets, VAULT, VAULT);
        if (temporaryTokenId == destinationTokenId_ || VKAT.ownerOf(temporaryTokenId) != VAULT) {
            revert InvalidTemporaryToken(temporaryTokenId);
        }
        (uint256 temporaryAmount,) = ESCROW.locked(temporaryTokenId);
        if (temporaryAmount < katAssets) revert MergeAmountMismatch(temporaryAmount, katAssets);
        uint256 sharesSpent = sharesBefore - ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        if (sharesSpent == 0 || sharesSpent > maximumShares_) revert SharesSpentTooHigh(sharesSpent, maximumShares_);
        ESCROW.merge(temporaryTokenId, destinationTokenId_);
        (uint256 destinationAfter,) = ESCROW.locked(destinationTokenId_);
        uint256 expected = destinationBefore + temporaryAmount;
        if (destinationAfter != expected) revert MergeAmountMismatch(destinationAfter, expected);
        emit AvKatMergedIntoVkat(temporaryTokenId, destinationTokenId_, temporaryAmount, sharesSpent);
    }

    function _createPosition(uint256 maximumShares_) private {
        uint256 sharesBefore = ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        if (maximumShares_ == 0 || sharesBefore < maximumShares_) revert InvalidConversionAmount();
        uint256 katAssets = ICurveYieldVkatAvkat(AVKAT).previewRedeem(maximumShares_);
        uint256 tokenId = ICurveYieldVkatAvkat(AVKAT).withdrawTokenId(katAssets, VAULT, VAULT);
        uint256 sharesSpent = sharesBefore - ICurveYieldVkatErc20(AVKAT).balanceOf(VAULT);
        if (sharesSpent == 0 || sharesSpent > maximumShares_) revert SharesSpentTooHigh(sharesSpent, maximumShares_);
        if (VKAT.ownerOf(tokenId) != VAULT) revert WrongNftOwner(tokenId);
        (uint256 lockedKat,) = ESCROW.locked(tokenId);
        if (lockedKat < katAssets) revert InvalidConversionAmount();
        VkatFuseStorageLib.add(tokenId);
    }

    function _refreshVote() private {
        VkatFuseStorageLib.TokenIds storage ids = VkatFuseStorageLib.tokenIds();
        if (ids.values.length == 0) revert NoTrackedVkat();
        if (DELEGATION_ADAPTER.delegates(VAULT) != VAULT) DELEGATION_ADAPTER.delegate(VAULT);
        if (DELEGATION_ADAPTER.delegates(VAULT) != VAULT) revert NotSelfDelegated();
        (address[] memory gauges, uint256[] memory weights) = ICurveYieldVkatStrategyConfig(VERSION).voteTargets();
        ICurveYieldVkatGaugeVoter.GaugeVote[] memory votes =
            new ICurveYieldVkatGaugeVoter.GaugeVote[](gauges.length);
        for (uint256 i; i < gauges.length; ++i) {
            address gauge = gauges[i];
            if (!VkatFuseStorageLib.isGaugeGranted(VKAT_SUBSTRATE_MARKET_ID, gauge)) {
                revert GaugeNotGranted(gauge);
            }
            if (!GAUGE_VOTER.gaugeExists(gauge) || !GAUGE_VOTER.isActive(gauge)) revert GaugeNotActive(gauge);
            votes[i] = ICurveYieldVkatGaugeVoter.GaugeVote(weights[i], gauge);
        }
        GAUGE_VOTER.vote(votes);
    }

    function _fundController(uint256 amount_) private {
        if (amount_ == 0) return;
        ICurveYieldVkatErc20 token = ICurveYieldVkatErc20(AVKAT);
        address controller = ICurveYieldVkatStrategyConfig(VERSION).CONTROLLER();
        uint256 vaultBefore = token.balanceOf(VAULT);
        uint256 controllerBefore = token.balanceOf(controller);
        if (vaultBefore < amount_ || !token.transfer(controller, amount_)) revert InvalidDeployPlan();
        if (vaultBefore - token.balanceOf(VAULT) != amount_ || token.balanceOf(controller) - controllerBefore != amount_) {
            revert InvalidDeployPlan();
        }
    }

    function _validateTrackedOwner(uint256 tokenId_) private view {
        if (!VkatFuseStorageLib.contains(tokenId_)) revert VkatFuseStorageLib.TokenNotTracked(tokenId_);
        if (VKAT.ownerOf(tokenId_) != VAULT) revert WrongNftOwner(tokenId_);
    }

    function _requireVaultExecution() private view {
        if (address(this) != VAULT || !PlasmaVaultLib.isExecutionStarted()) revert WrongVaultContext();
    }

    function _requireImplementation() private view {
        if (address(this) != VERSION) revert WrongImplementationContext();
    }

    function _requireActionContext() private view {
        if (address(this) != VAULT) revert WrongVaultContext();
        address controller = ICurveYieldVkatStrategyConfig(VERSION).CONTROLLER();
        if (msg.sender != controller) revert UnauthorizedCaller(msg.sender);
        if (!PlasmaVaultLib.isExecutionStarted()) revert WrongVaultContext();
    }
}

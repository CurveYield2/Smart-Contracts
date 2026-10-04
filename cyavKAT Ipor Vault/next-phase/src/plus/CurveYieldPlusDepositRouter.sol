// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICyPlusDepositVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

interface ICySettleSplit {
    function settleSplit() external returns (uint256);
}

interface ICyRewardsClaimManager {
    function updateBalance() external;
}

/// @title CurveYieldPlusDepositRouter (#20)
/// @notice The only depositor of cyavKAT+ (the vault is private: IPOR WHITELIST role 800 is granted to this router only),
/// so the deposit fee is taken from the depositor's cyavKAT — never minted as extra shares, which would dilute existing
/// holders (IPOR's own deposit fee is set to 0). Per deposit:
///   - whitelisted depositors (contributors, the contributors reward fuse, partners): no fee
///   - everyone else: `depositFeeBps` (35%) of the cyavKAT, split 20% admin / 25% cyavKAT+ RewardsClaimManager (vests
///     into the vault: holder profit) / 25% special reward distribution / 30% cyavKAT+ yield booster
///   - the rest is deposited into cyavKAT+ for `receiver_`
/// Fee rate, split, admin receiver and whitelist are fee settings: fee authority only (governance gate).
contract CurveYieldPlusDepositRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_DEPOSIT_FEE_BPS = 5_000;

    IERC20 public immutable CYAVKAT;
    address public immutable PLUS_VAULT;

    uint256 public depositFeeBps = 3_500;
    uint16[4] public splitBps = [2_000, 2_500, 2_500, 3_000]; // admin, rewards manager, special rewards, booster
    address public adminReceiver;
    address public rewardsManager; // cyavKAT+ RewardsClaimManager
    address public specialRewards;
    address public booster;
    mapping(address => bool) public isWhitelisted;
    address public withdrawManager; // cyavKAT+ WM v2: its owed fee split is settled before each deposit

    event Deposited(address indexed sender, address indexed receiver, uint256 cyIn, uint256 fee, uint256 shares);
    event WhitelistSet(address indexed account, bool whitelisted);

    error InvalidAddress();
    error BadFee();

    constructor(address owner_, address cyavkat_, address plusVault_) Ownable(owner_) {
        if (cyavkat_ == address(0) || plusVault_ == address(0)) revert InvalidAddress();
        CYAVKAT = IERC20(cyavkat_);
        PLUS_VAULT = plusVault_;
    }

    // ---------------------------------------------------------------- fee settings (protected by the gate)

    function setDepositFee(uint256 bps_, uint16[4] calldata split_) external onlyOwner {
        if (bps_ > MAX_DEPOSIT_FEE_BPS || uint256(split_[0]) + split_[1] + split_[2] + split_[3] != BPS) revert BadFee();
        depositFeeBps = bps_;
        splitBps = split_;
    }

    function setAdminReceiver(address admin_) external onlyOwner {
        adminReceiver = admin_;
    }

    function setWhitelisted(address account_, bool whitelisted_) external onlyOwner {
        isWhitelisted[account_] = whitelisted_;
        emit WhitelistSet(account_, whitelisted_);
    }

    function setWithdrawManager(address withdrawManager_) external onlyOwner {
        withdrawManager = withdrawManager_;
    }

    function setDestinations(address rewardsManager_, address specialRewards_, address booster_) external onlyOwner {
        (rewardsManager, specialRewards, booster) = (rewardsManager_, specialRewards_, booster_);
    }

    // ---------------------------------------------------------------- deposit

    function deposit(uint256 cyAmount_, address receiver_) external nonReentrant returns (uint256 shares_) {
        if (receiver_ == address(0)) revert InvalidAddress();
        if (withdrawManager != address(0)) ICySettleSplit(withdrawManager).settleSplit();
        CYAVKAT.safeTransferFrom(msg.sender, address(this), cyAmount_);
        uint256 fee = isWhitelisted[msg.sender] ? 0 : cyAmount_ * depositFeeBps / BPS;
        if (fee != 0) _splitFee(fee);
        uint256 net = cyAmount_ - fee;
        CYAVKAT.forceApprove(PLUS_VAULT, net);
        shares_ = ICyPlusDepositVault(PLUS_VAULT).deposit(net, receiver_);
        emit Deposited(msg.sender, receiver_, cyAmount_, fee, shares_);
    }

    /// @notice Quote for a deposit of `cyAmount_` by `sender_`: the fee and the cyavKAT that reaches the vault.
    function quote(address sender_, uint256 cyAmount_) external view returns (uint256 fee_, uint256 net_) {
        fee_ = isWhitelisted[sender_] ? 0 : cyAmount_ * depositFeeBps / BPS;
        net_ = cyAmount_ - fee_;
    }

    function _splitFee(uint256 fee_) private {
        address[4] memory to = [adminReceiver, rewardsManager, specialRewards, booster];
        uint256 sent;
        for (uint256 i; i < 4; ++i) {
            uint256 part = i == 3 ? fee_ - sent : fee_ * splitBps[i] / BPS;
            sent += part;
            if (part == 0) continue;
            if (to[i] == address(0)) revert InvalidAddress();
            CYAVKAT.safeTransfer(to[i], part);
        }
        // start vesting the holder share into the vault (the router holds UPDATE_REWARDS_BALANCE on the RCM)
        if (splitBps[1] != 0) ICyRewardsClaimManager(rewardsManager).updateBalance();
    }
}

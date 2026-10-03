// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20GatewayCyvbWBTCV1 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC4626GatewayCyvbWBTCV1 {
    function asset() external view returns (address);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}

/// @title CyvbWbtcInstantExitGateway_v1
/// @notice Mandatory public gateway for cyvbWBTC instant withdrawals and redemptions.
/// @dev Direct PlasmaVault withdraw/redeem is blocked by CyvbWbtcInstantExitGatePreHook_v1.
///      This gateway charges the requested 0.35% fee directly in vbWBTC and routes it to
///      the CurveYield fee receiver, while scheduled IPOR request withdrawals remain separate.
contract CyvbWbtcInstantExitGateway_v1 {
    uint256 public constant BPS = 10_000;
    uint256 public constant INSTANT_EXIT_FEE_BPS = 35;

    address public immutable VAULT;
    address public immutable ASSET;
    address public immutable FEE_RECEIVER;

    error InvalidAddress();
    error TokenTransferFailed(address to, uint256 amount);

    event InstantWithdraw(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 netAssets,
        uint256 feeAssets,
        uint256 sharesBurned
    );

    event InstantRedeem(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        uint256 netAssets,
        uint256 feeAssets
    );

    constructor(address vault_, address feeReceiver_) {
        if (vault_ == address(0) || feeReceiver_ == address(0) || vault_.code.length == 0) {
            revert InvalidAddress();
        }

        address asset_ = IERC4626GatewayCyvbWBTCV1(vault_).asset();
        if (asset_ == address(0) || asset_.code.length == 0) revert InvalidAddress();

        VAULT = vault_;
        ASSET = asset_;
        FEE_RECEIVER = feeReceiver_;
    }

    /// @notice Withdraw an exact NET amount to receiver; owner pays the 0.35% fee in addition.
    /// @dev Owner must approve this gateway to spend sufficient cyvbWBTC shares when caller != owner.
    function withdraw(
        uint256 netAssets_,
        address receiver_,
        address owner_
    ) external returns (uint256 sharesBurned) {
        if (receiver_ == address(0) || owner_ == address(0)) revert InvalidAddress();

        uint256 grossAssets = _grossFromNet(netAssets_);
        uint256 feeAssets = grossAssets - netAssets_;

        sharesBurned = IERC4626GatewayCyvbWBTCV1(VAULT).withdraw(
            grossAssets,
            address(this),
            owner_
        );

        _safeTransfer(receiver_, netAssets_);
        _safeTransfer(FEE_RECEIVER, feeAssets);

        emit InstantWithdraw(msg.sender, owner_, receiver_, netAssets_, feeAssets, sharesBurned);
    }

    /// @notice Redeem exact cyvbWBTC shares; 0.35% of received vbWBTC goes to the fee receiver.
    /// @dev Owner must approve this gateway to spend shares when caller != owner.
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) external returns (uint256 netAssets) {
        if (receiver_ == address(0) || owner_ == address(0)) revert InvalidAddress();

        uint256 grossAssets = IERC4626GatewayCyvbWBTCV1(VAULT).redeem(
            shares_,
            address(this),
            owner_
        );

        uint256 feeAssets = (grossAssets * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets - feeAssets;

        _safeTransfer(receiver_, netAssets);
        if (feeAssets != 0) _safeTransfer(FEE_RECEIVER, feeAssets);

        emit InstantRedeem(msg.sender, owner_, receiver_, shares_, netAssets, feeAssets);
    }

    function previewWithdraw(uint256 netAssets_) external view returns (uint256 sharesBurned) {
        return IERC4626GatewayCyvbWBTCV1(VAULT).previewWithdraw(_grossFromNet(netAssets_));
    }

    function previewRedeem(uint256 shares_) external view returns (uint256 netAssets) {
        uint256 grossAssets = IERC4626GatewayCyvbWBTCV1(VAULT).previewRedeem(shares_);
        return grossAssets - ((grossAssets * INSTANT_EXIT_FEE_BPS) / BPS);
    }

    function _grossFromNet(uint256 netAssets_) private pure returns (uint256) {
        if (netAssets_ == 0) return 0;
        uint256 denominator = BPS - INSTANT_EXIT_FEE_BPS;
        return (netAssets_ * BPS + denominator - 1) / denominator;
    }

    function _safeTransfer(address to_, uint256 amount_) private {
        if (amount_ == 0) return;
        (bool success, bytes memory data) =
            ASSET.call(abi.encodeWithSelector(IERC20GatewayCyvbWBTCV1.transfer.selector, to_, amount_));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TokenTransferFailed(to_, amount_);
        }
    }
}

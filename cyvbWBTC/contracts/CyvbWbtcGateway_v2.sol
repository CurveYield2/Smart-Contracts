// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20GatewayCyvbWBTCV2 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC4626GatewayCyvbWBTCV2 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}

/// @title CyvbWbtcGateway_v2
/// @notice Mandatory user entry/instant-exit gateway for CurveYield vbWBTC.
/// @dev Direct PlasmaVault deposit/mint/depositWithPermit/withdraw/redeem is blocked by
///      CyvbWbtcGatewayGatePreHook_v2. Scheduled redeemFromRequest remains an IPOR-native path.
contract CyvbWbtcGateway_v2 {
    uint256 public constant BPS = 10_000;
    uint256 public constant ONBOARDING_FEE_BPS = 55; // 0.55% of deposited vbWBTC.
    uint256 public constant INSTANT_EXIT_FEE_BPS = 35; // 0.35% of gross instant-exit vbWBTC.

    address public immutable VAULT;
    address public immutable ASSET;
    address public immutable FEE_RECEIVER;

    uint256 private _locked = 1;

    error InvalidAddress();
    error WrongVaultAsset();
    error ZeroAmount();
    error MinimumSharesNotMet(uint256 actual, uint256 minimum);
    error MaximumSharesExceeded(uint256 actual, uint256 maximum);
    error MinimumAssetsNotMet(uint256 actual, uint256 minimum);
    error TokenOperationFailed();
    error Reentrancy();

    event DepositedWithOnboardingFee(
        address indexed caller,
        address indexed receiver,
        uint256 grossAssets,
        uint256 feeAssets,
        uint256 netAssets,
        uint256 shares
    );

    event InstantWithdrawalWithFee(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 grossAssets,
        uint256 feeAssets,
        uint256 netAssets,
        uint256 sharesBurned
    );

    constructor(address vault_, address asset_, address feeReceiver_) {
        if (vault_ == address(0) || asset_ == address(0) || feeReceiver_ == address(0)) revert InvalidAddress();
        if (vault_.code.length == 0 || asset_.code.length == 0) revert InvalidAddress();
        if (IERC4626GatewayCyvbWBTCV2(vault_).asset() != asset_) revert WrongVaultAsset();

        VAULT = vault_;
        ASSET = asset_;
        FEE_RECEIVER = feeReceiver_;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @notice Deposit a gross vbWBTC amount. 0.55% is sent directly to the CurveYield fee receiver.
    function deposit(
        uint256 grossAssets_,
        address receiver_,
        uint256 minShares_
    ) external nonReentrant returns (uint256 shares) {
        if (grossAssets_ == 0) revert ZeroAmount();
        if (receiver_ == address(0)) revert InvalidAddress();

        (uint256 feeAssets, uint256 netAssets) = _onboardingSplit(grossAssets_);

        _safeTransferFrom(ASSET, msg.sender, address(this), grossAssets_);
        if (feeAssets != 0) _safeTransfer(ASSET, FEE_RECEIVER, feeAssets);

        _forceApprove(ASSET, VAULT, netAssets);
        shares = IERC4626GatewayCyvbWBTCV2(VAULT).deposit(netAssets, receiver_);
        _forceApprove(ASSET, VAULT, 0);

        if (shares < minShares_) revert MinimumSharesNotMet(shares, minShares_);

        emit DepositedWithOnboardingFee(msg.sender, receiver_, grossAssets_, feeAssets, netAssets, shares);
    }

    /// @notice Withdraw a GROSS amount from the vault. User receives gross less the 0.35% instant-exit fee.
    function withdraw(
        uint256 grossAssets_,
        address receiver_,
        address owner_,
        uint256 maxShares_
    ) external nonReentrant returns (uint256 sharesBurned, uint256 netAssets) {
        if (grossAssets_ == 0) revert ZeroAmount();
        if (receiver_ == address(0) || owner_ == address(0)) revert InvalidAddress();

        sharesBurned = IERC4626GatewayCyvbWBTCV2(VAULT).withdraw(grossAssets_, address(this), owner_);
        if (sharesBurned > maxShares_) revert MaximumSharesExceeded(sharesBurned, maxShares_);

        netAssets = _distributeExit(grossAssets_, receiver_);

        emit InstantWithdrawalWithFee(
            msg.sender,
            owner_,
            receiver_,
            grossAssets_,
            grossAssets_ - netAssets,
            netAssets,
            sharesBurned
        );
    }

    /// @notice Redeem exact cyvbWBTC shares. User receives gross vbWBTC less the 0.35% instant-exit fee.
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_,
        uint256 minNetAssets_
    ) external nonReentrant returns (uint256 grossAssets, uint256 netAssets) {
        if (shares_ == 0) revert ZeroAmount();
        if (receiver_ == address(0) || owner_ == address(0)) revert InvalidAddress();

        grossAssets = IERC4626GatewayCyvbWBTCV2(VAULT).redeem(shares_, address(this), owner_);
        netAssets = _distributeExit(grossAssets, receiver_);

        if (netAssets < minNetAssets_) revert MinimumAssetsNotMet(netAssets, minNetAssets_);

        emit InstantWithdrawalWithFee(
            msg.sender,
            owner_,
            receiver_,
            grossAssets,
            grossAssets - netAssets,
            netAssets,
            shares_
        );
    }

    function previewDeposit(
        uint256 grossAssets_
    ) external view returns (uint256 feeAssets, uint256 netAssets, uint256 estimatedShares) {
        (feeAssets, netAssets) = _onboardingSplit(grossAssets_);
        estimatedShares = IERC4626GatewayCyvbWBTCV2(VAULT).previewDeposit(netAssets);
    }

    function previewWithdraw(
        uint256 grossAssets_
    ) external view returns (uint256 shares, uint256 feeAssets, uint256 netAssets) {
        shares = IERC4626GatewayCyvbWBTCV2(VAULT).previewWithdraw(grossAssets_);
        feeAssets = (grossAssets_ * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets_ - feeAssets;
    }

    function previewRedeem(
        uint256 shares_
    ) external view returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets) {
        grossAssets = IERC4626GatewayCyvbWBTCV2(VAULT).previewRedeem(shares_);
        feeAssets = (grossAssets * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets - feeAssets;
    }

    function _onboardingSplit(uint256 grossAssets_) private pure returns (uint256 feeAssets, uint256 netAssets) {
        feeAssets = (grossAssets_ * ONBOARDING_FEE_BPS) / BPS;
        netAssets = grossAssets_ - feeAssets;
    }

    function _distributeExit(uint256 grossAssets_, address receiver_) private returns (uint256 netAssets) {
        uint256 feeAssets = (grossAssets_ * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets_ - feeAssets;

        if (feeAssets != 0) _safeTransfer(ASSET, FEE_RECEIVER, feeAssets);
        _safeTransfer(ASSET, receiver_, netAssets);
    }

    function _safeTransfer(address token_, address to_, uint256 amount_) private {
        (bool success, bytes memory data) =
            token_.call(abi.encodeWithSelector(IERC20GatewayCyvbWBTCV2.transfer.selector, to_, amount_));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenOperationFailed();
    }

    function _safeTransferFrom(address token_, address from_, address to_, uint256 amount_) private {
        (bool success, bytes memory data) = token_.call(
            abi.encodeWithSelector(IERC20GatewayCyvbWBTCV2.transferFrom.selector, from_, to_, amount_)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenOperationFailed();
    }

    function _forceApprove(address token_, address spender_, uint256 amount_) private {
        bytes memory callData = abi.encodeWithSelector(IERC20GatewayCyvbWBTCV2.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, callData)) {
            _callOptionalReturn(token_, abi.encodeWithSelector(IERC20GatewayCyvbWBTCV2.approve.selector, spender_, 0));
            _callOptionalReturn(token_, callData);
        }
    }

    function _callOptionalReturn(address token_, bytes memory data_) private {
        (bool success, bytes memory returndata) = token_.call(data_);
        if (!success || (returndata.length != 0 && !abi.decode(returndata, (bool)))) {
            revert TokenOperationFailed();
        }
    }

    function _callOptionalReturnBool(address token_, bytes memory data_) private returns (bool) {
        (bool success, bytes memory returndata) = token_.call(data_);
        return success && (returndata.length == 0 || (returndata.length >= 32 && abi.decode(returndata, (bool))));
    }
}

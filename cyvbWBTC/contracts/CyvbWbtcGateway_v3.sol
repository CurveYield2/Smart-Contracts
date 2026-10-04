// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20GatewayCyvbWBTCV3 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC20PermitGatewayCyvbWBTCV3 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IERC4626GatewayCyvbWBTCV3 {
    function asset() external view returns (address);
    function totalSupply() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}

/// @title CyvbWbtcGateway_v3
/// @notice Mandatory user entry/instant-exit gateway for CurveYield vbWBTC.
/// @dev The 0.55% onboarding and 0.35% instant-exit fees are never admin revenue.
///      While shares remain outstanding, fee assets are donated directly to the vault without
///      minting matching shares, making them PPS-accretive. If no shareholder can receive the
///      benefit (first deposit before shares exist, or final full exit after supply reaches zero),
///      the fee is sent to an irrecoverable burn sink so no orphan assets can be captured later.
///
///      Direct PlasmaVault deposit/mint/depositWithPermit/withdraw/redeem is blocked by
///      CyvbWbtcGatewayGatePreHook_v2. Scheduled redeemFromRequest remains an IPOR-native path.
contract CyvbWbtcGateway_v3 {
    uint256 public constant BPS = 10_000;
    uint256 public constant ONBOARDING_FEE_BPS = 55; // 0.55%
    uint256 public constant INSTANT_EXIT_FEE_BPS = 35; // 0.35%
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    address public immutable VAULT;
    address public immutable ASSET;

    mapping(address owner => mapping(address operator => bool approved)) public isOperator;

    uint256 private _locked = 1;

    error InvalidAddress();
    error WrongVaultAsset();
    error ZeroAmount();
    error UnauthorizedCaller(address caller, address owner);
    error MinimumSharesNotMet(uint256 actual, uint256 minimum);
    error MaximumSharesExceeded(uint256 actual, uint256 maximum);
    error MaximumAssetsExceeded(uint256 actual, uint256 maximum);
    error MinimumAssetsNotMet(uint256 actual, uint256 minimum);
    error TokenOperationFailed();
    error Reentrancy();

    event OperatorApproval(address indexed owner, address indexed operator, bool approved);

    event DepositedWithOnboardingFee(
        address indexed caller,
        address indexed receiver,
        uint256 grossAssets,
        uint256 feeAssets,
        uint256 netAssets,
        uint256 shares,
        address feeDestination
    );

    event MintedWithOnboardingFee(
        address indexed caller,
        address indexed receiver,
        uint256 shares,
        uint256 grossAssets,
        uint256 feeAssets,
        uint256 netAssets,
        address feeDestination
    );

    event InstantWithdrawalWithFee(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 grossAssets,
        uint256 feeAssets,
        uint256 netAssets,
        uint256 sharesBurned,
        address feeDestination
    );

    constructor(address vault_, address asset_) {
        if (vault_ == address(0) || asset_ == address(0)) revert InvalidAddress();
        if (vault_.code.length == 0 || asset_.code.length == 0) revert InvalidAddress();
        if (IERC4626GatewayCyvbWBTCV3(vault_).asset() != asset_) revert WrongVaultAsset();

        VAULT = vault_;
        ASSET = asset_;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @notice Allows an operator to use this owner's already-approved gateway share allowance.
    /// @dev This prevents an arbitrary caller from consuming another owner's approval to the gateway.
    function setOperator(address operator_, bool approved_) external {
        if (operator_ == address(0)) revert InvalidAddress();
        isOperator[msg.sender][operator_] = approved_;
        emit OperatorApproval(msg.sender, operator_, approved_);
    }

    /// @notice Deposit a gross vbWBTC amount. Shares are minted only against the net 99.45%.
    function deposit(
        uint256 grossAssets_,
        address receiver_,
        uint256 minShares_
    ) external nonReentrant returns (uint256 shares) {
        shares = _depositFrom(msg.sender, grossAssets_, receiver_, minShares_);
    }

    /// @notice Same as deposit, using EIP-2612 permit on vbWBTC for the gateway allowance.
    function depositWithPermit(
        uint256 grossAssets_,
        address receiver_,
        uint256 minShares_,
        uint256 permitDeadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external nonReentrant returns (uint256 shares) {
        IERC20PermitGatewayCyvbWBTCV3(ASSET).permit(
            msg.sender,
            address(this),
            grossAssets_,
            permitDeadline_,
            v_,
            r_,
            s_
        );
        shares = _depositFrom(msg.sender, grossAssets_, receiver_, minShares_);
    }

    /// @notice Mint an exact number of cyvbWBTC shares while charging the 0.55% onboarding fee.
    function mint(
        uint256 shares_,
        address receiver_,
        uint256 maxGrossAssets_
    ) external nonReentrant returns (uint256 grossAssets) {
        if (shares_ == 0) revert ZeroAmount();
        if (receiver_ == address(0)) revert InvalidAddress();

        uint256 supplyBefore = IERC4626GatewayCyvbWBTCV3(VAULT).totalSupply();
        uint256 netAssetsQuoted = IERC4626GatewayCyvbWBTCV3(VAULT).previewMint(shares_);
        grossAssets = _grossForNet(netAssetsQuoted, ONBOARDING_FEE_BPS);
        if (grossAssets > maxGrossAssets_) revert MaximumAssetsExceeded(grossAssets, maxGrossAssets_);

        _safeTransferFrom(ASSET, msg.sender, address(this), grossAssets);

        _forceApprove(ASSET, VAULT, netAssetsQuoted);
        uint256 netAssetsUsed = IERC4626GatewayCyvbWBTCV3(VAULT).mint(shares_, receiver_);
        _forceApprove(ASSET, VAULT, 0);

        // previewMint is specified to round up; a compliant vault must not require more than quoted
        // in the same transaction before any external PPS mutation by this gateway.
        if (netAssetsUsed > netAssetsQuoted) revert MaximumAssetsExceeded(netAssetsUsed, netAssetsQuoted);

        uint256 feeAssets = grossAssets - netAssetsUsed;
        address feeDestination = _entryFeeDestination(supplyBefore);
        _accrueFee(feeAssets, feeDestination);

        emit MintedWithOnboardingFee(
            msg.sender,
            receiver_,
            shares_,
            grossAssets,
            feeAssets,
            netAssetsUsed,
            feeDestination
        );
    }

    /// @notice Withdraw a gross vbWBTC amount. User receives gross less the 0.35% instant-exit fee.
    function withdraw(
        uint256 grossAssets_,
        address receiver_,
        address owner_,
        uint256 maxShares_
    ) external nonReentrant returns (uint256 sharesBurned, uint256 netAssets) {
        if (grossAssets_ == 0) revert ZeroAmount();
        if (receiver_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        _requireAuthorized(owner_);

        sharesBurned = IERC4626GatewayCyvbWBTCV3(VAULT).withdraw(grossAssets_, address(this), owner_);
        if (sharesBurned > maxShares_) revert MaximumSharesExceeded(sharesBurned, maxShares_);

        uint256 feeAssets = (grossAssets_ * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets_ - feeAssets;
        address feeDestination = _exitFeeDestination();

        _accrueFee(feeAssets, feeDestination);
        _safeTransfer(ASSET, receiver_, netAssets);

        emit InstantWithdrawalWithFee(
            msg.sender,
            owner_,
            receiver_,
            grossAssets_,
            feeAssets,
            netAssets,
            sharesBurned,
            feeDestination
        );
    }

    /// @notice Redeem exact cyvbWBTC shares. User receives gross vbWBTC less the 0.35% fee.
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_,
        uint256 minNetAssets_
    ) external nonReentrant returns (uint256 grossAssets, uint256 netAssets) {
        if (shares_ == 0) revert ZeroAmount();
        if (receiver_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        _requireAuthorized(owner_);

        grossAssets = IERC4626GatewayCyvbWBTCV3(VAULT).redeem(shares_, address(this), owner_);

        uint256 feeAssets = (grossAssets * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets - feeAssets;
        if (netAssets < minNetAssets_) revert MinimumAssetsNotMet(netAssets, minNetAssets_);

        address feeDestination = _exitFeeDestination();
        _accrueFee(feeAssets, feeDestination);
        _safeTransfer(ASSET, receiver_, netAssets);

        emit InstantWithdrawalWithFee(
            msg.sender,
            owner_,
            receiver_,
            grossAssets,
            feeAssets,
            netAssets,
            shares_,
            feeDestination
        );
    }

    function previewDeposit(
        uint256 grossAssets_
    ) external view returns (uint256 feeAssets, uint256 netAssets, uint256 estimatedShares) {
        (feeAssets, netAssets) = _onboardingSplit(grossAssets_);
        estimatedShares = IERC4626GatewayCyvbWBTCV3(VAULT).previewDeposit(netAssets);
    }

    function previewMint(
        uint256 shares_
    ) external view returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets) {
        netAssets = IERC4626GatewayCyvbWBTCV3(VAULT).previewMint(shares_);
        grossAssets = _grossForNet(netAssets, ONBOARDING_FEE_BPS);
        feeAssets = grossAssets - netAssets;
    }

    function previewWithdraw(
        uint256 grossAssets_
    ) external view returns (uint256 shares, uint256 feeAssets, uint256 netAssets) {
        shares = IERC4626GatewayCyvbWBTCV3(VAULT).previewWithdraw(grossAssets_);
        feeAssets = (grossAssets_ * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets_ - feeAssets;
    }

    function previewRedeem(
        uint256 shares_
    ) external view returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets) {
        grossAssets = IERC4626GatewayCyvbWBTCV3(VAULT).previewRedeem(shares_);
        feeAssets = (grossAssets * INSTANT_EXIT_FEE_BPS) / BPS;
        netAssets = grossAssets - feeAssets;
    }

    function _depositFrom(
        address payer_,
        uint256 grossAssets_,
        address receiver_,
        uint256 minShares_
    ) private returns (uint256 shares) {
        if (grossAssets_ == 0) revert ZeroAmount();
        if (receiver_ == address(0)) revert InvalidAddress();

        uint256 supplyBefore = IERC4626GatewayCyvbWBTCV3(VAULT).totalSupply();
        (uint256 feeAssets, uint256 netAssets) = _onboardingSplit(grossAssets_);

        _safeTransferFrom(ASSET, payer_, address(this), grossAssets_);

        _forceApprove(ASSET, VAULT, netAssets);
        shares = IERC4626GatewayCyvbWBTCV3(VAULT).deposit(netAssets, receiver_);
        _forceApprove(ASSET, VAULT, 0);

        if (shares < minShares_) revert MinimumSharesNotMet(shares, minShares_);

        address feeDestination = _entryFeeDestination(supplyBefore);
        _accrueFee(feeAssets, feeDestination);

        emit DepositedWithOnboardingFee(
            payer_,
            receiver_,
            grossAssets_,
            feeAssets,
            netAssets,
            shares,
            feeDestination
        );
    }

    function _onboardingSplit(uint256 grossAssets_) private pure returns (uint256 feeAssets, uint256 netAssets) {
        feeAssets = (grossAssets_ * ONBOARDING_FEE_BPS) / BPS;
        netAssets = grossAssets_ - feeAssets;
    }

    function _entryFeeDestination(uint256 supplyBefore_) private view returns (address) {
        return supplyBefore_ == 0 ? BURN_SINK : VAULT;
    }

    function _exitFeeDestination() private view returns (address) {
        return IERC4626GatewayCyvbWBTCV3(VAULT).totalSupply() == 0 ? BURN_SINK : VAULT;
    }

    function _requireAuthorized(address owner_) private view {
        if (msg.sender != owner_ && !isOperator[owner_][msg.sender]) {
            revert UnauthorizedCaller(msg.sender, owner_);
        }
    }

    function _accrueFee(uint256 feeAssets_, address destination_) private {
        if (feeAssets_ != 0) _safeTransfer(ASSET, destination_, feeAssets_);
    }

    function _grossForNet(uint256 netAssets_, uint256 feeBps_) private pure returns (uint256) {
        if (netAssets_ == 0) return 0;
        return _ceilDiv(netAssets_ * BPS, BPS - feeBps_);
    }

    function _ceilDiv(uint256 a_, uint256 b_) private pure returns (uint256) {
        if (a_ == 0) return 0;
        return ((a_ - 1) / b_) + 1;
    }

    function _safeTransfer(address token_, address to_, uint256 amount_) private {
        (bool success, bytes memory data) =
            token_.call(abi.encodeWithSelector(IERC20GatewayCyvbWBTCV3.transfer.selector, to_, amount_));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenOperationFailed();
    }

    function _safeTransferFrom(address token_, address from_, address to_, uint256 amount_) private {
        (bool success, bytes memory data) = token_.call(
            abi.encodeWithSelector(IERC20GatewayCyvbWBTCV3.transferFrom.selector, from_, to_, amount_)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenOperationFailed();
    }

    function _forceApprove(address token_, address spender_, uint256 amount_) private {
        bytes memory callData = abi.encodeWithSelector(IERC20GatewayCyvbWBTCV3.approve.selector, spender_, amount_);
        if (!_callOptionalReturnBool(token_, callData)) {
            _callOptionalReturn(token_, abi.encodeWithSelector(IERC20GatewayCyvbWBTCV3.approve.selector, spender_, 0));
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

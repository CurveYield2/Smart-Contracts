// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20CyvbEthMorphoV1 {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC4626CyvbEthMorphoV1 {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IPlasmaVaultBaseCyvbEthMorphoV1 {
    function PLASMA_VAULT_BASE() external view returns (address);
}

interface IWithdrawManagerCyvbEthMorphoV1 {
    function getSharesToRelease() external view returns (uint256);
}

interface IMorphoSupplyFuseCyvbEthV1 {
    function MARKET_ID() external view returns (uint256);
    function MORPHO() external view returns (address);
}

interface IMorphoCoreCyvbEthV1 {
    function idToMarketParams(bytes32 id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
}

struct CyvbEthMorphoDataV1 {
    bytes32 morphoMarketId;
    uint256 amount;
}

/// @title CyvbEthMorphoAllocatorFuse_v1
/// @notice Keeper-facing cyvbETH allocator that delegates to IPOR's official Katana Morpho SupplyFuse.
/// @dev The official supply fuse is intentionally not exposed directly as a vault fuse. This wrapper preserves the
///      same onboarding-fee-share burn used by the f(x) strategy before newly deposited vbETH can be allocated.
contract CyvbEthMorphoAllocatorFuse_v1 {
    bytes32 private constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    address public immutable VERSION;
    address public immutable VAULT;
    address public immutable VBETH;
    address public immutable IPOR_MORPHO_SUPPLY_FUSE;
    address public immutable MORPHO;
    uint256 public immutable MORPHO_IPOR_MARKET_ID;
    bytes32 public immutable MORPHO_MARKET_ID;

    error InvalidAddress();
    error WrongVaultContext();
    error ProtocolTopologyMismatch();
    error NoCapital();
    error FeeBurnFailed(bytes reason);
    error MorphoDelegateCallFailed(bytes reason);
    error MorphoResultMismatch();

    event MorphoCapitalDeployed(address indexed version, bytes32 indexed market, uint256 vbEthSupplied);
    event MorphoCapitalWithdrawn(address indexed version, bytes32 indexed market, uint256 vbEthWithdrawn);

    constructor(
        address vault_,
        address vbEth_,
        address iporMorphoSupplyFuse_,
        uint256 morphoIporMarketId_,
        bytes32 morphoMarketId_
    ) {
        if (
            vault_.code.length == 0 || vbEth_.code.length == 0 ||
            iporMorphoSupplyFuse_.code.length == 0 || morphoMarketId_ == bytes32(0)
        ) revert InvalidAddress();

        address morpho = IMorphoSupplyFuseCyvbEthV1(iporMorphoSupplyFuse_).MORPHO();
        if (
            morpho.code.length == 0 ||
            IMorphoSupplyFuseCyvbEthV1(iporMorphoSupplyFuse_).MARKET_ID() != morphoIporMarketId_
        ) revert ProtocolTopologyMismatch();

        (address loanToken,,,,) = IMorphoCoreCyvbEthV1(morpho).idToMarketParams(morphoMarketId_);
        if (loanToken != vbEth_) revert ProtocolTopologyMismatch();

        VERSION = address(this);
        VAULT = vault_;
        VBETH = vbEth_;
        IPOR_MORPHO_SUPPLY_FUSE = iporMorphoSupplyFuse_;
        MORPHO = morpho;
        MORPHO_IPOR_MARKET_ID = morphoIporMarketId_;
        MORPHO_MARKET_ID = morphoMarketId_;
    }

    /// @notice Deploy a keeper-selected amount of currently deployable idle vbETH to the approved Morpho market.
    /// @param amount_ Amount to deploy; zero means all currently deployable idle vbETH.
    function deployToMorpho(uint256 amount_) external returns (uint256 supplied) {
        _requireVaultContext();

        uint256 deployable = _deployableIdle();
        if (deployable == 0) revert NoCapital();
        uint256 amount = amount_ == 0 || amount_ > deployable ? deployable : amount_;

        _burnManagerFeeShares(amount, deployable);

        bytes memory result = _delegateMorpho(
            abi.encodeWithSignature(
                "enter((bytes32,uint256))",
                CyvbEthMorphoDataV1({morphoMarketId: MORPHO_MARKET_ID, amount: amount})
            )
        );
        (address asset, bytes32 market, uint256 actual) = abi.decode(result, (address, bytes32, uint256));
        if (asset != VBETH || market != MORPHO_MARKET_ID || actual != amount) revert MorphoResultMismatch();

        supplied = actual;
        emit MorphoCapitalDeployed(VERSION, MORPHO_MARKET_ID, actual);
    }

    /// @notice Move a keeper-selected amount of supplied vbETH back to idle vault balance.
    function withdrawFromMorpho(uint256 amount_) external returns (uint256 withdrawn) {
        _requireVaultContext();
        bytes memory result = _delegateMorpho(
            abi.encodeWithSignature(
                "exit((bytes32,uint256))",
                CyvbEthMorphoDataV1({morphoMarketId: MORPHO_MARKET_ID, amount: amount_})
            )
        );
        (address asset, bytes32 market, uint256 actual) = abi.decode(result, (address, bytes32, uint256));
        if (actual != 0 && (asset != VBETH || market != MORPHO_MARKET_ID)) revert MorphoResultMismatch();
        withdrawn = actual;
        emit MorphoCapitalWithdrawn(VERSION, MORPHO_MARKET_ID, actual);
    }

    /// @notice IPOR instant-withdraw entry point. PlasmaVault replaces params_[0] with remaining vbETH required.
    /// @dev Delegates to IPOR's official Morpho fuse, whose instant path catches Morpho liquidity failures so the
    ///      next configured instant-withdraw fuse (the f(x) strategy) can continue satisfying the withdrawal.
    function instantWithdraw(bytes32[] calldata params_) external {
        _requireVaultContext();
        uint256 requested = params_.length == 0 ? 0 : uint256(params_[0]);
        if (requested == 0) return;

        bytes32[] memory nested = new bytes32[](2);
        nested[0] = bytes32(requested);
        nested[1] = MORPHO_MARKET_ID;
        _delegateMorpho(abi.encodeWithSignature("instantWithdraw(bytes32[])", nested));
    }

    function _delegateMorpho(bytes memory data_) private returns (bytes memory result) {
        (bool ok, bytes memory returned) = IPOR_MORPHO_SUPPLY_FUSE.delegatecall(data_);
        if (!ok) revert MorphoDelegateCallFailed(returned);
        return returned;
    }

    function _deployableIdle() private view returns (uint256) {
        uint256 idle = IERC20CyvbEthMorphoV1(VBETH).balanceOf(address(this));
        address wm = _withdrawManager();
        if (wm == address(0)) return idle;
        uint256 reserved = IERC4626CyvbEthMorphoV1(address(this)).convertToAssets(
            IWithdrawManagerCyvbEthMorphoV1(wm).getSharesToRelease()
        );
        return idle > reserved ? idle - reserved : 0;
    }

    function _burnManagerFeeShares(uint256 num_, uint256 den_) private {
        address wm = _withdrawManager();
        if (wm == address(0)) return;
        uint256 shares =
            (IERC4626CyvbEthMorphoV1(address(this)).balanceOf(wm) * num_) / den_;
        if (shares == 0) return;

        address base = IPlasmaVaultBaseCyvbEthMorphoV1(address(this)).PLASMA_VAULT_BASE();
        (bool ok, bytes memory reason) = base.delegatecall(
            abi.encodeWithSignature("updateInternal(address,address,uint256)", wm, address(0), shares)
        );
        if (!ok) revert FeeBurnFailed(reason);
    }

    function _withdrawManager() private view returns (address wm_) {
        bytes32 slot = WITHDRAW_MANAGER_SLOT;
        assembly {
            wm_ := sload(slot)
        }
    }

    function _requireVaultContext() private view {
        if (address(this) != VAULT) revert WrongVaultContext();
    }
}

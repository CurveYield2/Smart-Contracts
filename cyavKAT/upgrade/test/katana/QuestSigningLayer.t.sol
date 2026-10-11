// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FuseAction} from "../../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {CurveYieldVaultBase1271} from "../../src/katana/CurveYieldVaultBase1271.sol";
import {CurveYieldSignatureFuse} from "../../src/katana/CurveYieldSignatureFuse.sol";
import {CurveYieldQuestSignerConfigFuse} from "../../src/katana/CurveYieldQuestSignerConfigFuse.sol";

contract MockIporFactoryBase {
    function factoryBaseProof() external pure returns (bytes32) {
        return keccak256("unchanged IPOR factory base");
    }

    function delegatedCaller() external view returns (address) {
        return msg.sender;
    }
}

contract MockIporFactoryVault {
    address public immutable OWNER;
    mapping(address => bool) public fuseSupported;

    error NotOwner();
    error FuseNotSupported(address fuse);

    constructor(address base_) {
        OWNER = msg.sender;
        PlasmaVaultStorageLib.setPlasmaVaultBase(base_);
    }

    function base() external view returns (address) {
        return PlasmaVaultStorageLib.getPlasmaVaultBase();
    }

    function addFuses(address[] calldata fuses) external {
        if (msg.sender != OWNER) revert NotOwner();
        for (uint256 i; i < fuses.length; ++i) fuseSupported[fuses[i]] = true;
    }

    function removeFuses(address[] calldata fuses) external {
        if (msg.sender != OWNER) revert NotOwner();
        for (uint256 i; i < fuses.length; ++i) fuseSupported[fuses[i]] = false;
    }

    function execute(FuseAction[] calldata calls) external {
        if (msg.sender != OWNER) revert NotOwner();
        for (uint256 i; i < calls.length; ++i) {
            if (!fuseSupported[calls[i].fuse]) revert FuseNotSupported(calls[i].fuse);
            (bool ok, bytes memory data) = calls[i].fuse.delegatecall(calls[i].data);
            if (!ok) assembly { revert(add(data, 32), mload(data)) }
        }
    }

    /// @dev Mirrors IPOR PlasmaVault's non-execution fallback route through PLASMA_VAULT_BASE.
    fallback(bytes calldata) external returns (bytes memory) {
        address activeBase = PlasmaVaultStorageLib.getPlasmaVaultBase();
        (bool ok, bytes memory result) = activeBase.delegatecall(msg.data);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
        return result;
    }
}

/// @notice RPC-independent regression tests. These do not replace a fork check of the live IPOR permissions.
contract QuestSigningLayerTest is Test {
    uint256 constant SIGNER_PK = 0xA11CE5;
    uint256 constant SECOND_PK = 0xB0B5;
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;

    MockIporFactoryBase original;
    MockIporFactoryVault vault;
    CurveYieldVaultBase1271 wrapper;
    CurveYieldSignatureFuse installer;
    CurveYieldQuestSignerConfigFuse config;
    address signer;
    address secondSigner;
    bytes prefix;

    function setUp() public {
        original = new MockIporFactoryBase();
        vault = new MockIporFactoryVault(address(original));
        wrapper = new CurveYieldVaultBase1271(address(original));
        installer = new CurveYieldSignatureFuse(7, address(vault), address(wrapper));
        config = new CurveYieldQuestSignerConfigFuse(7, address(vault), address(wrapper));
        signer = vm.addr(SIGNER_PK);
        secondSigner = vm.addr(SECOND_PK);
        prefix = bytes(string.concat("app.katana.network wants you to sign in with your Ethereum account:\n", vm.toString(address(vault)), "\n"));

        address[] memory a = new address[](2);
        a[0] = address(installer);
        a[1] = address(config);
        vault.addFuses(a);
        FuseAction[] memory calls = new FuseAction[](3);
        calls[0] = FuseAction(address(installer), abi.encodeCall(CurveYieldSignatureFuse.install, ()));
        calls[1] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setPrefix, (prefix)));
        calls[2] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setSigner, (signer, true)));
        vault.execute(calls);
    }

    function test_revisedQuestSigningVersionAndImmutables() public {
        assertEq(config.QUEST_SIGNING_LAYER_VERSION(), 2, "V2 must not accept old config contracts");
        assertEq(config.VAULT(), address(vault), "config is bound to the factory vault");
        assertEq(config.BASE_1271(), address(wrapper), "config must use the active signing wrapper");
        assertEq(config.ORIGINAL_BASE(), address(original), "original IPOR base must remain in use");
    }

    function test_factoryBaseDelegationPreservedAfterRemovingInstaller() public {
        _detach();
        assertEq(vault.base(), address(wrapper), "wrapper must remain active");
        assertEq(wrapper.ORIGINAL_BASE(), address(original), "original factory base address changed");
        assertGt(address(original).code.length, 0, "original factory base code missing");
        assertEq(MockIporFactoryBase(address(vault)).factoryBaseProof(), keccak256("unchanged IPOR factory base"));
        assertEq(MockIporFactoryBase(address(vault)).delegatedCaller(), address(this), "msg.sender lost through delegation");
        assertFalse(vault.fuseSupported(address(installer)), "installer must be removed");
        assertTrue(vault.fuseSupported(address(config)), "config must remain enabled");
        assertEq(_validate(SIGNER_PK, "a"), MAGIC, "signing lost after installer removed");
    }

    function test_signerCanBeRevokedAndRotatedWithoutInstallationFuse() public {
        _detach();
        _configureSigner(signer, false);
        _configureSigner(secondSigner, true);
        assertEq(_validate(SIGNER_PK, "b"), INVALID, "revoked signer accepted");
        assertEq(_validate(SECOND_PK, "b"), MAGIC, "new signer cannot sign");
        assertEq(vault.base(), address(wrapper), "base changed during signer rotation");
    }

    function test_prefixCanBeChangedWithoutInstallationFuse() public {
        _detach();
        bytes memory newPrefix = bytes("different restricted login prefix:\n");
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setPrefix, (newPrefix)));
        vault.execute(a);
        assertEq(_validate(SIGNER_PK, "c"), INVALID, "old domain accepted after prefix changed");
        assertEq(vault.base(), address(wrapper), "base modified by config");
    }

    function test_installFuseCannotBeUsedAfterDetachingButCanBeReaddedForRollback() public {
        _detach();
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(installer), abi.encodeCall(CurveYieldSignatureFuse.uninstall, ()));
        vm.expectRevert(abi.encodeWithSelector(MockIporFactoryVault.FuseNotSupported.selector, address(installer)));
        vault.execute(a);

        address[] memory again = new address[](1);
        again[0] = address(installer);
        vault.addFuses(again);
        vault.execute(a);
        assertEq(vault.base(), address(original), "emergency rollback must restore exact original");
        bytes memory message = abi.encode(bytes("x"), new bytes(65));
        (bool ok, bytes memory result) = address(vault).staticcall(
            abi.encodeWithSelector(0x1626ba7e, bytes32(0), message)
        );
        if (ok && result.length >= 32) {
            assertTrue(abi.decode(result, (bytes4)) != MAGIC, "old base still claims ERC-1271");
        }
    }

    function test_directCallsAndUnauthorizedCallersCannotConfigureVault() public {
        vm.expectRevert(CurveYieldQuestSignerConfigFuse.WrongContext.selector);
        config.setSigner(secondSigner, true);
        vm.expectRevert(CurveYieldQuestSignerConfigFuse.WrongContext.selector);
        config.setPrefix(prefix);

        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setSigner, (secondSigner, true)));
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(MockIporFactoryVault.NotOwner.selector);
        vault.execute(a);
    }

    function test_configNotUsableOnceWrapperRemoved() public {
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(installer), abi.encodeCall(CurveYieldSignatureFuse.uninstall, ()));
        vault.execute(a);
        a[0] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setSigner, (secondSigner, true)));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldQuestSignerConfigFuse.UnexpectedBase.selector, address(original)));
        vault.execute(a);
    }

    function _detach() internal {
        address[] memory rm = new address[](1);
        rm[0] = address(installer);
        vault.removeFuses(rm);
    }

    function _configureSigner(address who, bool on) internal {
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setSigner, (who, on)));
        vault.execute(a);
    }

    function _validate(uint256 key, string memory nonce) internal returns (bytes4) {
        bytes memory message = bytes(string.concat(string(prefix), "nonce:", nonce));
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        bytes memory signature = abi.encode(message, abi.encodePacked(r, s, v));
        return CurveYieldVaultBase1271(address(vault)).isValidSignature(hash, signature);
    }
}

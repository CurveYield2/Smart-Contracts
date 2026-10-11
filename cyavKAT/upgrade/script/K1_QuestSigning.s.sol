// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldVaultBase1271} from "../src/katana/CurveYieldVaultBase1271.sol";
import {CurveYieldSignatureFuse} from "../src/katana/CurveYieldSignatureFuse.sol";
import {CurveYieldQuestSignerConfigFuse} from "../src/katana/CurveYieldQuestSignerConfigFuse.sol";

interface IVaultK1 {
    function execute(FuseAction[] calldata calls) external;
    function addFuses(address[] calldata fuses) external;
    function removeFuses(address[] calldata fuses) external;
    function isFuseSupported(address fuse) external view returns (bool);
    function PLASMA_VAULT_BASE() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getAccessManagerAddress() external view returns (address);
}

interface IVault1271K1 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
    function isQuestSigner(address signer) external view returns (bool);
    function questSignPrefix() external view returns (bytes memory);
}

interface IAmK1 {
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
}

/// @notice Katana Quests login-signing layer for factory-deployed cyavKAT.
/// The *unchanged* original PlasmaVaultBase always handles all ordinary base functionality through the wrapper.
/// The wrapper MUST remain the active PLASMA_VAULT_BASE for vault-address ERC-1271 signing to work.
/// A separate config-only fuse manages the authorized signer/prefix after the temporary install fuse is removed.
///
/// Modes (set only one at a time):
///   default                       fresh install + configure + remove temporary installation fuse
///   QUEST_DETACH_INSTALL=true     migrate an already-live wrapper: install persistent config fuse, remove old installer
///   QUEST_FINISH=true             finish interrupted legacy initial install, then detach installer
///   QUEST_SET_SIGNER=true         update QUEST_SIGNER using QUEST_SIGNER_ENABLED (default true)
///   QUEST_SET_PREFIX=true         set QUEST_PREFIX; empty disables signing (does not alter the base)
///   QUEST_UNINSTALL=true          explicit rollback: restores original base, DISABLING vault-address ERC-1271
/// All modes read/write deployments/katana-quests.json. ALPHA executes fuses, FUSE_MANAGER adds/removes them;
/// neither action requires IPOR DAO approval if the vault-local roles are held.
contract K1_QuestSigning is Phase2Base {
    function _questsPath() private view returns (string memory) {
        return vm.envOr("QUEST_DEPLOYMENTS", string("deployments/katana-quests.json"));
    }
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultK1 vault = IVaultK1(VAULT);
        IAmK1 am = IAmK1(vault.getAccessManagerAddress());
        (bool alpha,) = am.hasRole(200, DEPLOYER);
        (bool fuseManager,) = am.hasRole(300, DEPLOYER);
        require(alpha, "deployer needs vault-local ALPHA (200)");
        uint256 modes = (vm.envOr("QUEST_SET_SIGNER", false) ? 1 : 0)
            + (vm.envOr("QUEST_SET_PREFIX", false) ? 1 : 0)
            + (vm.envOr("QUEST_UNINSTALL", false) ? 1 : 0)
            + (vm.envOr("QUEST_DETACH_INSTALL", false) ? 1 : 0)
            + (vm.envOr("QUEST_FINISH", false) ? 1 : 0);
        require(modes <= 1, "select only ONE Quest mode");

        if (vm.envOr("QUEST_SET_SIGNER", false)) return _setSigner(vault);
        if (vm.envOr("QUEST_SET_PREFIX", false)) return _setPrefix(vault);
        require(fuseManager, "deployer needs vault-local FUSE_MANAGER (300)");
        if (vm.envOr("QUEST_UNINSTALL", false)) return _uninstall(vault);
        if (vm.envOr("QUEST_DETACH_INSTALL", false)) return _detachInstaller(vault);
        if (vm.envOr("QUEST_FINISH", false)) return _finish(vault);

        address signer = vm.envOr("QUEST_SIGNER", DEPLOYER);
        require(signer != address(0), "zero quest signer");
        address originalBase = vault.PLASMA_VAULT_BASE();
        require(originalBase.code.length != 0, "missing original base code");
        // An already-installed signing wrapper must not be wrapped again.
        try CurveYieldVaultBase1271(originalBase).ORIGINAL_BASE() returns (address wrappedOriginal) {
            require(wrappedOriginal == address(0), "base already wrapped: use QUEST_DETACH_INSTALL");
        } catch { /* original IPOR base does not expose ORIGINAL_BASE() */ }
        bytes memory prefix = _katanaPrefix();
        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        _start();
        CurveYieldVaultBase1271 base = new CurveYieldVaultBase1271(originalBase);
        CurveYieldSignatureFuse installer = new CurveYieldSignatureFuse(MARKET_ERC20, VAULT, address(base));
        CurveYieldQuestSignerConfigFuse config = new CurveYieldQuestSignerConfigFuse(MARKET_ERC20, VAULT, address(base));
        require(config.QUEST_SIGNING_LAYER_VERSION() == 2, "revised signer config required");
        address[] memory add = new address[](2);
        add[0] = address(installer);
        add[1] = address(config);
        vault.addFuses(add);
        FuseAction[] memory a = new FuseAction[](3);
        a[0] = FuseAction(address(installer), abi.encodeCall(CurveYieldSignatureFuse.install, ()));
        a[1] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setPrefix, (prefix)));
        a[2] = FuseAction(address(config), abi.encodeCall(CurveYieldQuestSignerConfigFuse.setSigner, (signer, true)));
        vault.execute(a);
        _verify(vault, address(base), signer, prefix);
        address[] memory rm = new address[](1);
        rm[0] = address(installer);
        vault.removeFuses(rm);
        _stop();

        require(!vault.isFuseSupported(address(installer)) && vault.isFuseSupported(address(config)), "fuse separation failed");
        _verify(vault, address(base), signer, prefix);
        // Balance and supply safety checks retained from the original deployment script.
        uint256 assetsAfter = vault.totalAssets();
        require(assetsAfter * 10_000 >= assetsBefore * 9_995 && assetsAfter * 10_000 <= assetsBefore * 10_005, "share-price step");
        require(vault.totalSupply() * 10_000 <= supplyBefore * 10_001, "supply moved");
        _save(originalBase, address(base), address(installer), address(config), signer);
        console2.log("factory IPOR base (unchanged)", originalBase);
        console2.log("active 1271 wrapper", address(base));
        console2.log("persistent signer config fuse", address(config));
        console2.log("temporary install fuse REMOVED", address(installer));
    }

    /// @notice Convert an already-installed live wrapper to a permanent signer-management layer.
    /// No base replacement and no original-IPOR contract modification occurs.
    function _detachInstaller(IVaultK1 vault) private {
        string memory json = vm.readFile(_questsPath());
        address installer = vm.parseJsonAddress(json, ".signatureFuse");
        address base = vm.parseJsonAddress(json, ".base1271");
        address original = vm.parseJsonAddress(json, ".originalBase");
        address signer = vm.parseJsonAddress(json, ".signer");
        _checkWrapper(vault, base, original);
        _checkInstaller(installer, base, original);
        address config = _optionalConfig(json);
        if (config != address(0)) {
            require(CurveYieldQuestSignerConfigFuse(config).VAULT() == VAULT, "config vault mismatch");
            require(CurveYieldQuestSignerConfigFuse(config).BASE_1271() == base, "config base mismatch");
            require(CurveYieldQuestSignerConfigFuse(config).ORIGINAL_BASE() == original, "config original mismatch");
        }
        address oldConfig = config;
        if (config != address(0) && !_isRevisedConfig(config)) config = address(0);
        bytes memory prefix = IVault1271K1(VAULT).questSignPrefix();
        bool wasAuthorized = IVault1271K1(VAULT).isQuestSigner(signer);
        _start();
        if (config == address(0)) {
            config = address(new CurveYieldQuestSignerConfigFuse(MARKET_ERC20, VAULT, base));
        }
        require(_isRevisedConfig(config), "new V2 config missing");
        if (!vault.isFuseSupported(config)) {
            address[] memory add = new address[](1);
            add[0] = config;
            vault.addFuses(add);
        }
        if (vault.isFuseSupported(installer)) {
            address[] memory rm = new address[](1);
            rm[0] = installer;
            vault.removeFuses(rm);
        }
        if (oldConfig != address(0) && oldConfig != config && vault.isFuseSupported(oldConfig)) {
            address[] memory rmOld = new address[](1);
            rmOld[0] = oldConfig;
            vault.removeFuses(rmOld);
        }
        _stop();
        require(vault.isFuseSupported(config) && !vault.isFuseSupported(installer), "installer removal failed");
        if (oldConfig != address(0) && oldConfig != config) {
            require(!vault.isFuseSupported(oldConfig), "old config fuse still registered");
        }
        require(_isRevisedConfig(config), "revised config fuse required");
        _checkWrapper(vault, base, original);
        require(IVault1271K1(VAULT).isQuestSigner(signer) == wasAuthorized, "signer changed");
        require(keccak256(IVault1271K1(VAULT).questSignPrefix()) == keccak256(prefix), "prefix changed");
        _save(original, base, installer, config, signer);
        console2.log("installer removed; ERC-1271 wrapper still live", base);
        console2.log("persistent signer config fuse", config);
    }

    /// @notice Recover a legacy deployment where the wrapper/fuse were deployed and added but install wasn't executed.
    function _finish(IVaultK1 vault) private {
        string memory json = vm.readFile(_questsPath());
        address installer = vm.parseJsonAddress(json, ".signatureFuse");
        address base = vm.parseJsonAddress(json, ".base1271");
        address signer = vm.parseJsonAddress(json, ".signer");
        address original = vm.parseJsonAddress(json, ".originalBase");
        require(vault.PLASMA_VAULT_BASE() == original, "unexpected base: do not replace a live wrapper");
        require(vault.isFuseSupported(installer), "installer not supported");
        require(CurveYieldSignatureFuse(installer).BASE_1271() == base, "installer mismatch");
        require(CurveYieldVaultBase1271(base).ORIGINAL_BASE() == original, "original base mismatch");
        address config = _optionalConfig(json);
        if (config != address(0)) {
            require(CurveYieldQuestSignerConfigFuse(config).VAULT() == VAULT, "config vault mismatch");
            require(CurveYieldQuestSignerConfigFuse(config).BASE_1271() == base, "config base mismatch");
            require(CurveYieldQuestSignerConfigFuse(config).ORIGINAL_BASE() == original, "config original mismatch");
        }
        require(config == address(0) || _isRevisedConfig(config),
            "old config fuse: migrate to revised V2 config first");
        bytes memory prefix = _katanaPrefix();
        _start();
        if (config == address(0)) config = address(new CurveYieldQuestSignerConfigFuse(MARKET_ERC20, VAULT, base));
        require(_isRevisedConfig(config), "revised V2 config required");
        if (!vault.isFuseSupported(config)) {
            address[] memory add = new address[](1);
            add[0] = config;
            vault.addFuses(add);
        }
        FuseAction[] memory a = new FuseAction[](3);
        a[0] = FuseAction(installer, abi.encodeCall(CurveYieldSignatureFuse.install, ()));
        a[1] = FuseAction(config, abi.encodeCall(CurveYieldQuestSignerConfigFuse.setPrefix, (prefix)));
        a[2] = FuseAction(config, abi.encodeCall(CurveYieldQuestSignerConfigFuse.setSigner, (signer, true)));
        vault.execute(a);
        _verify(vault, base, signer, prefix);
        address[] memory rm = new address[](1);
        rm[0] = installer;
        vault.removeFuses(rm);
        _stop();
        require(!vault.isFuseSupported(installer) && vault.isFuseSupported(config), "fuse separation failed");
        _verify(vault, base, signer, prefix);
        _save(original, base, installer, config, signer);
    }

    function _setSigner(IVaultK1 vault) private {
        string memory json = vm.readFile(_questsPath());
        address base = vm.parseJsonAddress(json, ".base1271");
        _checkWrapper(vault, base, vm.parseJsonAddress(json, ".originalBase"));
        address config = _requiredConfig(vault, json);
        address signer = vm.envAddress("QUEST_SIGNER");
        require(signer != address(0), "zero quest signer");
        bool enabled = vm.envOr("QUEST_SIGNER_ENABLED", true);
        _start();
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(config, abi.encodeCall(CurveYieldQuestSignerConfigFuse.setSigner, (signer, enabled)));
        vault.execute(a);
        _stop();
        require(IVault1271K1(VAULT).isQuestSigner(signer) == enabled, "signer update failed");
        console2.log("quest signer updated", signer);
        console2.log("enabled", enabled);
    }

    function _setPrefix(IVaultK1 vault) private {
        string memory json = vm.readFile(_questsPath());
        address base = vm.parseJsonAddress(json, ".base1271");
        _checkWrapper(vault, base, vm.parseJsonAddress(json, ".originalBase"));
        address config = _requiredConfig(vault, json);
        bytes memory prefix = bytes(vm.envString("QUEST_PREFIX"));
        _start();
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(config, abi.encodeCall(CurveYieldQuestSignerConfigFuse.setPrefix, (prefix)));
        vault.execute(a);
        _stop();
        require(keccak256(IVault1271K1(VAULT).questSignPrefix()) == keccak256(prefix), "prefix update failed");
        console2.log("quest sign prefix updated (bytes)", prefix.length);
    }

    /// @notice Explicit emergency rollback, NOT the normal detach. Vault-address ERC-1271 stops working afterward.
    function _uninstall(IVaultK1 vault) private {
        string memory json = vm.readFile(_questsPath());
        address installer = vm.parseJsonAddress(json, ".signatureFuse");
        address base = vm.parseJsonAddress(json, ".base1271");
        address original = vm.parseJsonAddress(json, ".originalBase");
        address signer = vm.parseJsonAddress(json, ".signer");
        _checkWrapper(vault, base, original);
        _checkInstaller(installer, base, original);
        address config = _optionalConfig(json);
        _start();
        if (!vault.isFuseSupported(installer)) {
            address[] memory add = new address[](1);
            add[0] = installer;
            vault.addFuses(add);
        }
        FuseAction[] memory a = new FuseAction[](3);
        a[0] = FuseAction(installer, abi.encodeCall(CurveYieldSignatureFuse.setSigner, (signer, false)));
        a[1] = FuseAction(installer, abi.encodeCall(CurveYieldSignatureFuse.setPrefix, (bytes(""))));
        a[2] = FuseAction(installer, abi.encodeCall(CurveYieldSignatureFuse.uninstall, ()));
        vault.execute(a);
        address[] memory rm = new address[](config != address(0) && vault.isFuseSupported(config) ? 2 : 1);
        rm[0] = installer;
        if (rm.length == 2) rm[1] = config;
        vault.removeFuses(rm);
        _stop();
        require(vault.PLASMA_VAULT_BASE() == original && !vault.isFuseSupported(installer), "rollback failed");
        if (config != address(0)) require(!vault.isFuseSupported(config), "config fuse still installed");
        console2.log("original IPOR base restored; vault-address ERC-1271 DISABLED", original);
    }

    function _checkInstaller(address installer, address base, address original) private view {
        require(installer.code.length != 0, "installer has no code");
        require(CurveYieldSignatureFuse(installer).VAULT() == VAULT, "installer vault mismatch");
        require(CurveYieldSignatureFuse(installer).BASE_1271() == base, "installer wrapper mismatch");
        require(CurveYieldSignatureFuse(installer).ORIGINAL_BASE() == original, "installer original mismatch");
    }

    function _requiredConfig(IVaultK1 vault, string memory json) private view returns (address config) {
        config = _optionalConfig(json);
        require(config != address(0) && vault.isFuseSupported(config), "run QUEST_DETACH_INSTALL first");
        require(_isRevisedConfig(config), "old signer config: run QUEST_DETACH_INSTALL");
        require(CurveYieldQuestSignerConfigFuse(config).VAULT() == VAULT, "config vault mismatch");
        require(CurveYieldQuestSignerConfigFuse(config).BASE_1271() == vm.parseJsonAddress(json, ".base1271"), "config base mismatch");
    }

    function _isRevisedConfig(address config) private view returns (bool) {
        if (config.code.length == 0) return false;
        try CurveYieldQuestSignerConfigFuse(config).QUEST_SIGNING_LAYER_VERSION() returns (uint256 version) {
            return version == 2;
        } catch { return false; }
    }

    function _optionalConfig(string memory json) private view returns (address config) {
        try vm.parseJsonAddress(json, ".configFuse") returns (address a) { config = a; }
        catch { config = address(0); } // Older deployed JSON has no configFuse field.
    }

    function _checkWrapper(IVaultK1 vault, address base, address original) private view {
        require(vault.PLASMA_VAULT_BASE() == base, "1271 wrapper not active");
        require(base.code.length != 0 && original.code.length != 0, "missing contract code");
        require(CurveYieldVaultBase1271(base).ORIGINAL_BASE() == original, "wrong original IPOR base");
    }

    function _verify(IVaultK1 vault, address base, address signer, bytes memory prefix) private view {
        require(vault.PLASMA_VAULT_BASE() == base, "base not installed");
        IVault1271K1 v = IVault1271K1(VAULT);
        require(v.isQuestSigner(signer), "signer not configured");
        require(keccak256(v.questSignPrefix()) == keccak256(prefix), "prefix not configured");
        bytes memory junk = abi.encode(bytes("x"), new bytes(65));
        require(v.isValidSignature(bytes32(0), junk) != MAGIC, "invalid signature accepted");
    }

    function _katanaPrefix() private view returns (bytes memory) {
        return bytes(string.concat(
            "app.katana.network wants you to sign in with your Ethereum account:\n", vm.toString(VAULT), "\n"
        ));
    }

    function _save(address original, address base, address installer, address config, address signer) private {
        string memory o = "quests";
        vm.serializeAddress(o, "originalBase", original);
        vm.serializeAddress(o, "base1271", base);
        vm.serializeAddress(o, "signer", signer);
        vm.serializeAddress(o, "signatureFuse", installer);
        string memory out = vm.serializeAddress(o, "configFuse", config);
        vm.writeJson(out, _questsPath());
    }
}

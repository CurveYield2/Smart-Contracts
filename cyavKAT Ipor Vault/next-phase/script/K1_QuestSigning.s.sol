// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldVaultBase1271} from "../src/katana/CurveYieldVaultBase1271.sol";
import {CurveYieldSignatureFuse} from "../src/katana/CurveYieldSignatureFuse.sol";

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

/// Katana Quests: lets cyavKAT sign in (SIWE / EIP-4361) as itself, so the vault address can verify, earn XP and buy
/// Krates. Deploys CurveYieldVaultBase1271 (wraps the vault's current PlasmaVaultBase) + CurveYieldSignatureFuse, then
/// in ONE execute: install (base -> wrapper), setPrefix (Katana log-in text for THIS vault), setSigner (QUEST_SIGNER).
/// Only Katana log-in messages signed (personal_sign) by QUEST_SIGNER are valid for the vault: no permits, no approvals.
///   QUEST_SIGNER   wallet that signs log-ins for the vault (default: the deployer)
///   QUEST_UNINSTALL=true  rollback: base back to the original, signer removed, fuse removed (reads deployments/katana-quests.json)
/// Needs the deployer's ALPHA (200) and FUSE_MANAGER (300) on cyavKAT.
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/K1_QuestSigning.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract K1_QuestSigning is Phase2Base {
    string internal constant QUESTS_PATH = "deployments/katana-quests.json";
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultK1 vault = IVaultK1(VAULT);
        IAmK1 am = IAmK1(vault.getAccessManagerAddress());
        (bool alpha,) = am.hasRole(200, DEPLOYER);
        (bool fuseManager,) = am.hasRole(300, DEPLOYER);
        require(alpha && fuseManager, "deployer needs ALPHA (200) + FUSE_MANAGER (300) on cyavKAT");
        if (vm.envOr("QUEST_UNINSTALL", false)) return _uninstall(vault);
        if (vm.envOr("QUEST_FINISH", false)) return _finish(vault);

        address signer = vm.envOr("QUEST_SIGNER", DEPLOYER);
        address originalBase = vault.PLASMA_VAULT_BASE();
        bytes memory prefix = bytes(string.concat(
            "app.katana.network wants you to sign in with your Ethereum account:\n", vm.toString(VAULT), "\n"
        ));
        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        _start();
        CurveYieldVaultBase1271 base = new CurveYieldVaultBase1271(originalBase);
        CurveYieldSignatureFuse fuse = new CurveYieldSignatureFuse(MARKET_ERC20, VAULT, address(base));
        address[] memory add = new address[](1);
        add[0] = address(fuse);
        vault.addFuses(add);
        FuseAction[] memory a = new FuseAction[](3);
        a[0] = FuseAction(address(fuse), abi.encodeCall(CurveYieldSignatureFuse.install, ()));
        a[1] = FuseAction(address(fuse), abi.encodeCall(CurveYieldSignatureFuse.setPrefix, (prefix)));
        a[2] = FuseAction(address(fuse), abi.encodeCall(CurveYieldSignatureFuse.setSigner, (signer, true)));
        vault.execute(a);
        _stop();

        IVault1271K1 v = IVault1271K1(VAULT);
        require(vault.PLASMA_VAULT_BASE() == address(base), "base not installed");
        require(v.isQuestSigner(signer), "signer");
        require(keccak256(v.questSignPrefix()) == keccak256(prefix), "prefix");
        // routing check: a junk signature is answered (rejected), not reverted
        bytes memory junk = abi.encode(bytes("x"), new bytes(65));
        require(v.isValidSignature(bytes32(0), junk) != MAGIC, "junk accepted");
        // execute refreshes market 7 (fresh balances): allow the usual tiny drift, never a share-price step
        uint256 assetsAfter = vault.totalAssets();
        console2.log("totalAssets before / after", assetsBefore, assetsAfter);
        require(assetsAfter * 10_000 >= assetsBefore * 9_995 && assetsAfter * 10_000 <= assetsBefore * 10_005, "share-price step");
        // execute also realizes the pending management fee (small mint)
        require(vault.totalSupply() * 10_000 <= supplyBefore * 10_001, "supply moved");
        console2.log("original base", originalBase);
        console2.log("1271 base", address(base));
        console2.log("signature fuse", address(fuse));
        console2.log("quest signer", signer);

        string memory o = "quests";
        vm.serializeAddress(o, "originalBase", originalBase);
        vm.serializeAddress(o, "base1271", address(base));
        vm.serializeAddress(o, "signer", signer);
        string memory out = vm.serializeAddress(o, "signatureFuse", address(fuse));
        vm.writeJson(out, QUESTS_PATH);
    }

    /// @dev QUEST_FINISH=true: the contracts are deployed and the fuse added (deployments/katana-quests.json), only the
    /// install execute is missing (e.g. the broadcast stopped before its last transaction).
    function _finish(IVaultK1 vault) private {
        string memory json = vm.readFile(QUESTS_PATH);
        address fuse = vm.parseJsonAddress(json, ".signatureFuse");
        address base = vm.parseJsonAddress(json, ".base1271");
        address signer = vm.parseJsonAddress(json, ".signer");
        require(vault.isFuseSupported(fuse), "fuse not added");
        require(CurveYieldSignatureFuse(fuse).BASE_1271() == base && vault.PLASMA_VAULT_BASE() == CurveYieldSignatureFuse(fuse).ORIGINAL_BASE(), "state");
        bytes memory prefix = bytes(string.concat(
            "app.katana.network wants you to sign in with your Ethereum account:\n", vm.toString(VAULT), "\n"
        ));
        _start();
        FuseAction[] memory a = new FuseAction[](3);
        a[0] = FuseAction(fuse, abi.encodeCall(CurveYieldSignatureFuse.install, ()));
        a[1] = FuseAction(fuse, abi.encodeCall(CurveYieldSignatureFuse.setPrefix, (prefix)));
        a[2] = FuseAction(fuse, abi.encodeCall(CurveYieldSignatureFuse.setSigner, (signer, true)));
        vault.execute(a);
        _stop();
        IVault1271K1 v = IVault1271K1(VAULT);
        require(vault.PLASMA_VAULT_BASE() == base && v.isQuestSigner(signer), "not installed");
        require(keccak256(v.questSignPrefix()) == keccak256(prefix), "prefix");
        console2.log("quest signing live; base", base, "signer", signer);
    }

    function _uninstall(IVaultK1 vault) private {
        string memory json = vm.readFile(QUESTS_PATH);
        address fuse = vm.parseJsonAddress(json, ".signatureFuse");
        address signer = vm.parseJsonAddress(json, ".signer");
        address originalBase = vm.parseJsonAddress(json, ".originalBase");
        _start();
        FuseAction[] memory a = new FuseAction[](2);
        a[0] = FuseAction(fuse, abi.encodeCall(CurveYieldSignatureFuse.setSigner, (signer, false)));
        a[1] = FuseAction(fuse, abi.encodeCall(CurveYieldSignatureFuse.uninstall, ()));
        vault.execute(a);
        address[] memory rm = new address[](1);
        rm[0] = fuse;
        vault.removeFuses(rm);
        _stop();
        require(vault.PLASMA_VAULT_BASE() == originalBase && !vault.isFuseSupported(fuse), "rollback");
        console2.log("quest signing removed; base restored", originalBase);
    }
}

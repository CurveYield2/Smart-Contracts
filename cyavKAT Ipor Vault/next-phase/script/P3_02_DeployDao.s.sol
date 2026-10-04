// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

// ---------------------------------------------------------------- minimal external interfaces (ABI-identical)

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners, uint256 threshold, address to, bytes calldata data, address fallbackHandler,
        address paymentToken, uint256 payment, address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function VERSION() external view returns (string memory);
}

struct AragonTag {
    uint8 release;
    uint16 build;
}

struct AragonVersion {
    AragonTag tag;
    address pluginSetup;
    bytes buildMetadata;
}

interface IAragonPluginRepo {
    function latestRelease() external view returns (uint8);
    function getLatestVersion(uint8 release) external view returns (AragonVersion memory);
}

struct AragonDaoSettings {
    address trustedForwarder;
    string daoURI;
    string subdomain;
    bytes metadata;
}

struct AragonPluginSetupRef {
    AragonTag versionTag;
    address pluginSetupRepo;
}

struct AragonPluginSettings {
    AragonPluginSetupRef pluginSetupRef;
    bytes data;
}

/// @dev DAOFactory returns each installed plugin with its PreparedSetupData (helpers + the permissions applied).
struct AragonMultiTargetPermission {
    uint8 operation;
    address where;
    address who;
    address condition;
    bytes32 permissionId;
}

struct AragonPreparedSetupData {
    address[] helpers;
    AragonMultiTargetPermission[] permissions;
}

struct AragonInstalledPlugin {
    address plugin;
    AragonPreparedSetupData preparedSetupData;
}

interface IAragonDaoFactory {
    function createDao(AragonDaoSettings calldata settings, AragonPluginSettings[] calldata plugins)
        external returns (address createdDao, AragonInstalledPlugin[] memory installedPlugins);
}

struct DaoAction {
    address to;
    uint256 value;
    bytes data;
}

interface IAragonDao {
    function hasPermission(address where, address who, bytes32 permissionId, bytes memory data) external view returns (bool);
    function grant(address where, address who, bytes32 permissionId) external;
    function revoke(address where, address who, bytes32 permissionId) external;
}

interface IAragonAdminPlugin {
    function executeProposal(bytes calldata metadata, DaoAction[] calldata actions, uint256 allowFailureMap)
        external returns (uint256);
    function dao() external view returns (address);
}

struct TvVotingSettings {
    uint8 votingMode;
    uint32 supportThreshold;
    uint32 minParticipation;
    uint64 minDuration;
    uint256 minProposerVotingPower;
}

struct TvTokenSettings {
    address addr;
    string name;
    string symbol;
}

struct TvMintSettings {
    address[] receivers;
    uint256[] amounts;
    bool ensureDelegationOnMint;
}

struct TvTargetConfig {
    address target;
    uint8 operation;
}

interface IAragonTokenVotingPlugin {
    function getVotingToken() external view returns (address);
    function votingMode() external view returns (uint8);
    function supportThreshold() external view returns (uint32);
    function minParticipation() external view returns (uint32);
    function minDuration() external view returns (uint64);
    function minProposerVotingPower() external view returns (uint256);
    function dao() external view returns (address);
}

/// Phase 3 step 2: the Safe (2-of-3) and the Aragon DAO with TokenVoting (the existing voting lock as its token) and the
/// Admin plugin. Reads deployments/katana-phase3.json (PHASE3_DEPLOYMENTS overrides) written by P3_01 and adds:
///   safe, dao, tokenVoting, adminPlugin   (existing keys are kept)
///
/// 1. Safe v1.4.1 via the canonical SafeProxyFactory + singleton, owners SAFE_OWNER_USER (default 0x9f2B...E288),
///    SAFE_OWNER_BOT1, SAFE_OWNER_BOT2 (required), threshold 2, the canonical CompatibilityFallbackHandler.
/// 2. Aragon DAO through the DAOFactory with two plugins, latest builds of their repos:
///    - TokenVoting: token = the voting lock (no new token, no wrapping, no minting), Standard mode (no early
///      execution), support 66%, participation 10%, 7-day minimum duration, proposer voting power 0, target = the DAO.
///    - Admin: admin = the deployer. The second admin is added below.
/// 3. Through the Admin plugin (executed by the deployer, the initial admin), in one proposal:
///    - revoke CREATE_PROPOSAL_PERMISSION from ANY_ADDR (TokenVotingSetup installs it for anyone that passes a voting-power
///      condition; with a minimum of 0 that is everyone)
///    - grant CREATE_PROPOSAL_PERMISSION on TokenVoting to the Safe only
///    - grant the Admin plugin's EXECUTE_PROPOSAL_PERMISSION to the second admin (0x9f2B...E288)
///    HARD RULE: the Admin plugin is never revoked, uninstalled or weakened here.
///
///   SAFE_OWNER_BOT1=0x... SAFE_OWNER_BOT2=0x... forge script "$P2/script/P3_02_DeployDao.s.sol" --root $P2 --rpc-url katana
///     --skip test --skip "*/test/**"    (add --broadcast ...)
contract P3_02_DeployDao is Phase2Base {
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant DEFAULT_SAFE_OWNER_USER = 0x9f2B20A772246960810045905B7daccf960eE288;
    address internal constant DAO_FACTORY = 0xd59D2bEF6465cC71efEc40afd2D72901470Dd835;
    address internal constant TOKEN_VOTING_REPO = 0xBAFF9A7c3Bf3e791B3E601fFe5A05C7759f30E5b;
    address internal constant ADMIN_REPO = 0x95d1ACA58E631774bDE4d1bC67DD784f01cCDAeC;
    address internal constant ANY_ADDR = address(type(uint160).max);

    bytes32 internal constant CREATE_PROPOSAL_PERMISSION_ID = keccak256("CREATE_PROPOSAL_PERMISSION");
    bytes32 internal constant EXECUTE_PROPOSAL_PERMISSION_ID = keccak256("EXECUTE_PROPOSAL_PERMISSION");

    uint32 internal constant SUPPORT_THRESHOLD = 660_000; // 66% (ratio base 1e6)
    uint32 internal constant MIN_PARTICIPATION = 100_000; // 10%
    uint64 internal constant MIN_DURATION = 7 days;

    struct Result {
        address safe;
        address dao;
        address tokenVoting;
        address adminPlugin;
    }

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory path = _phase3Path();
        string memory existing = vm.readFile(path);
        address lock = vm.parseJsonAddress(existing, ".votingLock");
        require(lock.code.length != 0, "voting lock not deployed (run P3_01)");

        address user = vm.envOr("SAFE_OWNER_USER", DEFAULT_SAFE_OWNER_USER);
        address bot1 = vm.envAddress("SAFE_OWNER_BOT1");
        address bot2 = vm.envAddress("SAFE_OWNER_BOT2");
        require(user != address(0) && bot1 != address(0) && bot2 != address(0), "zero owner");
        require(user != bot1 && user != bot2 && bot1 != bot2, "duplicate owner");
        require(SAFE_PROXY_FACTORY.code.length != 0 && SAFE_SINGLETON.code.length != 0, "Safe contracts missing");
        require(SAFE_FALLBACK_HANDLER.code.length != 0, "Safe fallback handler missing");
        require(DAO_FACTORY.code.length != 0, "DAOFactory missing");

        Result memory r;
        _start();
        r.safe = _deploySafe(user, bot1, bot2);
        (r.dao, r.tokenVoting, r.adminPlugin) = _createDao(lock);
        _fixPermissions(r, user);
        _stop();

        _checks(r, lock, user, bot1, bot2);
        _write(existing, path, r);
        console2.log("safe", r.safe);
        console2.log("dao", r.dao);
        console2.log("tokenVoting", r.tokenVoting);
        console2.log("adminPlugin", r.adminPlugin);
    }

    // ---------------------------------------------------------------- steps

    function _deploySafe(address user_, address bot1_, address bot2_) internal returns (address safe_) {
        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (user_, bot1_, bot2_);
        bytes memory init = abi.encodeCall(
            ISafe.setup,
            (owners, 2, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        uint256 salt = uint256(keccak256(abi.encode("curveyield.dao.safe", owners)));
        safe_ = ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, init, salt);
    }

    function _createDao(address lock_) internal returns (address dao_, address tokenVoting_, address admin_) {
        AragonPluginSettings[] memory plugins = new AragonPluginSettings[](2);
        plugins[0] = AragonPluginSettings(_ref(TOKEN_VOTING_REPO), _tokenVotingInstallData(lock_));
        // Admin plugin installation data: (admin, targetConfig); the deployer is the initial admin
        plugins[1] = AragonPluginSettings(_ref(ADMIN_REPO), abi.encode(DEPLOYER, TvTargetConfig(address(0), 0)));
        (address created, AragonInstalledPlugin[] memory installed) = IAragonDaoFactory(DAO_FACTORY).createDao(
            AragonDaoSettings({trustedForwarder: address(0), daoURI: "", subdomain: "", metadata: ""}), plugins
        );
        require(installed.length == 2, "plugins not installed");
        require(IAragonAdminPlugin(installed[1].plugin).dao() == created, "plugin dao");
        return (created, installed[0].plugin, installed[1].plugin);
    }

    function _ref(address repo_) internal view returns (AragonPluginSetupRef memory) {
        IAragonPluginRepo repo = IAragonPluginRepo(repo_);
        AragonVersion memory v = repo.getLatestVersion(repo.latestRelease());
        return AragonPluginSetupRef(v.tag, repo_);
    }

    function _tokenVotingInstallData(address lock_) internal pure returns (bytes memory) {
        return abi.encode(
            TvVotingSettings({
                votingMode: 0, // Standard: no early execution, no vote replacement
                supportThreshold: SUPPORT_THRESHOLD,
                minParticipation: MIN_PARTICIPATION,
                minDuration: MIN_DURATION,
                minProposerVotingPower: 0
            }),
            TvTokenSettings({addr: lock_, name: "", symbol: ""}), // an existing IVotes token is used as is
            TvMintSettings({receivers: new address[](0), amounts: new uint256[](0), ensureDelegationOnMint: false}),
            TvTargetConfig({target: address(0), operation: 0}), // zero target = the DAO itself, plain call
            uint256(0), // minApprovals
            bytes(""), // plugin metadata
            new address[](0) // excluded accounts
        );
    }

    /// @dev One Admin plugin proposal, executed by the deployer: only the Safe can create proposals, and the second
    /// admin joins. The Admin plugin itself is untouched.
    function _fixPermissions(Result memory r_, address secondAdmin_) internal {
        DaoAction[] memory a = new DaoAction[](3);
        a[0] = DaoAction(
            r_.dao, 0, abi.encodeCall(IAragonDao.revoke, (r_.tokenVoting, ANY_ADDR, CREATE_PROPOSAL_PERMISSION_ID))
        );
        a[1] = DaoAction(
            r_.dao, 0, abi.encodeCall(IAragonDao.grant, (r_.tokenVoting, r_.safe, CREATE_PROPOSAL_PERMISSION_ID))
        );
        a[2] = DaoAction(
            r_.dao, 0, abi.encodeCall(IAragonDao.grant, (r_.adminPlugin, secondAdmin_, EXECUTE_PROPOSAL_PERMISSION_ID))
        );
        IAragonAdminPlugin(r_.adminPlugin).executeProposal("", a, 0);
    }

    // ---------------------------------------------------------------- checks and output

    function _checks(Result memory r_, address lock_, address user_, address bot1_, address bot2_) internal view {
        IAragonDao dao = IAragonDao(r_.dao);
        IAragonTokenVotingPlugin tv = IAragonTokenVotingPlugin(r_.tokenVoting);
        // both plugins belong to the DAO
        require(tv.dao() == r_.dao && IAragonAdminPlugin(r_.adminPlugin).dao() == r_.dao, "plugin dao");
        // TokenVoting: the existing lock as its token, and the requested settings
        require(tv.getVotingToken() == lock_, "voting token is not the lock");
        require(tv.votingMode() == 0, "voting mode");
        require(tv.supportThreshold() == SUPPORT_THRESHOLD, "support threshold");
        require(tv.minParticipation() == MIN_PARTICIPATION, "min participation");
        require(tv.minDuration() == MIN_DURATION, "min duration");
        require(tv.minProposerVotingPower() == 0, "min proposer voting power");
        // proposals: the Safe only
        require(dao.hasPermission(r_.tokenVoting, r_.safe, CREATE_PROPOSAL_PERMISSION_ID, ""), "safe cannot create proposals");
        require(!dao.hasPermission(r_.tokenVoting, address(0xBEEF), CREATE_PROPOSAL_PERMISSION_ID, ""), "random address can create proposals");
        require(!dao.hasPermission(r_.tokenVoting, DEPLOYER, CREATE_PROPOSAL_PERMISSION_ID, ""), "deployer can create proposals");
        require(!dao.hasPermission(r_.tokenVoting, ANY_ADDR, CREATE_PROPOSAL_PERMISSION_ID, ""), "anyone can create proposals");
        // Admin plugin: both admins, still installed
        require(dao.hasPermission(r_.adminPlugin, DEPLOYER, EXECUTE_PROPOSAL_PERMISSION_ID, ""), "deployer is not an admin");
        require(dao.hasPermission(r_.adminPlugin, user_, EXECUTE_PROPOSAL_PERMISSION_ID, ""), "second admin missing");
        require(!dao.hasPermission(r_.adminPlugin, address(0xBEEF), EXECUTE_PROPOSAL_PERMISSION_ID, ""), "random admin");
        // Safe: owners and threshold
        ISafe safe = ISafe(r_.safe);
        address[] memory owners = safe.getOwners();
        require(owners.length == 3 && safe.getThreshold() == 2, "safe owners / threshold");
        bool okUser;
        bool okBot1;
        bool okBot2;
        for (uint256 i; i < 3; ++i) {
            if (owners[i] == user_) okUser = true;
            if (owners[i] == bot1_) okBot1 = true;
            if (owners[i] == bot2_) okBot2 = true;
        }
        require(okUser && okBot1 && okBot2, "safe owners");
        require(keccak256(bytes(safe.VERSION())) == keccak256("1.4.1"), "safe version");
    }

    function _write(string memory existing_, string memory path_, Result memory r_) internal {
        string memory o = "p3";
        string[] memory keys = vm.parseJsonKeys(existing_, "$");
        for (uint256 i; i < keys.length; ++i) {
            string memory k = keys[i];
            if (
                _eq(k, "safe") || _eq(k, "dao") || _eq(k, "tokenVoting") || _eq(k, "adminPlugin")
            ) continue; // rewritten below (re-runs replace them)
            vm.serializeString(o, k, vm.parseJsonString(existing_, string.concat(".", k)));
        }
        vm.serializeAddress(o, "safe", r_.safe);
        vm.serializeAddress(o, "dao", r_.dao);
        vm.serializeAddress(o, "tokenVoting", r_.tokenVoting);
        string memory json = vm.serializeAddress(o, "adminPlugin", r_.adminPlugin);
        vm.writeJson(json, path_);
    }

    function _eq(string memory a_, string memory b_) private pure returns (bool) {
        return keccak256(bytes(a_)) == keccak256(bytes(b_));
    }

    function _phase3Path() internal view returns (string memory) {
        return vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json"));
    }
}

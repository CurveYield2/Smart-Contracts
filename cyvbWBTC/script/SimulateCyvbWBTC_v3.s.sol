// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import "./DeployCyvbWBTC_v6.s.sol";
import "../contracts/CyvbWbtcGateway_v5.sol";
import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/FxMintCyvbWbtcFuse_v4.sol";

interface IERC20CyvbWbtcSimulationV3 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPlasmaVaultCyvbWbtcSimulationV3 {
    function execute(FuseActionCyvbWbtcSimulationV3[] calldata calls_) external;
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFxLongPoolCyvbWbtcSimulationV3 {
    function getPositionDebtRatio(uint256 tokenId) external view returns (uint256);
}

struct FuseActionCyvbWbtcSimulationV3 {
    address fuse;
    bytes data;
}

/// @notice Minimal ERC-4626-compatible nested vault used only on the isolated Anvil fork.
///         It deliberately keeps 1 asset unit == 1 share unit so the cyvbWBTC strategy
///         exercises the real live f(x) and CurveYield swap paths without depending on
///         a production cyvbUSDC deployment that does not exist yet.
contract MockCyvbUsdcSimulation_v3 {
    address public immutable asset;
    string public constant symbol = "cyvbUSDC";

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        require(IERC20CyvbWbtcSimulationV3(asset).transferFrom(msg.sender, address(this), assets), "transferFrom");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(msg.sender == owner, "owner");
        shares = assets;
        require(balanceOf[owner] >= shares, "shares");
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(IERC20CyvbWbtcSimulationV3(asset).transfer(receiver, assets), "transfer");
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "owner");
        require(balanceOf[owner] >= shares, "shares");
        assets = shares;
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(IERC20CyvbWbtcSimulationV3(asset).transfer(receiver, assets), "transfer");
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

/// @title SimulateCyvbWBTC_v3
/// @notice End-to-end cyvbWBTC deployment + deposit + strategy + partial instant exit + full exit
///         against an externally launched live Katana Anvil fork.
contract SimulateCyvbWBTC_v3 is Script {
    address internal constant VBWBTC = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant FX_POOL = 0xE32B9b4C8f776687Ec54B4b6B62DbD9ce5fd4b99;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_INSTANT_LTV = 55e16;

    event CyvbWbtcAnvilSimulationComplete(
        address indexed vault,
        address indexed gateway,
        address indexed strategyFuse,
        uint256 depositAmount,
        uint256 initialLtv,
        uint256 postPartialExitLtv,
        uint256 finalSupply,
        uint256 finalAssets
    );

    struct SimulationStateV3 {
        uint256 privateKey;
        address user;
        uint256 depositAmount;
        address nested;
        address vault;
        address gateway;
        address strategyFuse;
        address config;
        uint256 position;
        uint256 initialLtv;
        uint256 postPartialExitLtv;
    }

    function run() external {
        require(block.chainid == 747474, "not Katana fork");

        SimulationStateV3 memory s;
        s.privateKey = vm.envUint("PRIVATE_KEY");
        s.user = vm.addr(s.privateKey);
        s.depositAmount = vm.envUint("SIM_DEPOSIT_AMOUNT");

        require(s.depositAmount != 0, "deposit=0");
        require(
            IERC20CyvbWbtcSimulationV3(VBWBTC).balanceOf(s.user) >= s.depositAmount,
            "user not funded"
        );

        _deployNestedAndVault(s);
        _depositAndDeployCapital(s);
        _exercisePartialInstantExit(s);
        (uint256 finalSupply, uint256 finalAssets) = _exerciseFullExit(s);

        emit CyvbWbtcAnvilSimulationComplete(
            s.vault,
            s.gateway,
            s.strategyFuse,
            s.depositAmount,
            s.initialLtv,
            s.postPartialExitLtv,
            finalSupply,
            finalAssets
        );
    }

    function _deployNestedAndVault(SimulationStateV3 memory s_) private {
        vm.startBroadcast(s_.privateKey);
        MockCyvbUsdcSimulation_v3 nested = new MockCyvbUsdcSimulation_v3(VBUSDC);
        vm.stopBroadcast();

        s_.nested = address(nested);

        vm.setEnv("CURVEYIELD_USDC_VAULT", vm.toString(s_.nested));
        vm.setEnv("KEEPER", vm.toString(s_.user));
        vm.setEnv("FINAL_OWNER", vm.toString(s_.user));

        vm.recordLogs();
        DeployCyvbWBTC_v6 deployment = new DeployCyvbWBTC_v6();
        FusionInstanceCyvbWBTCV1 memory instance = deployment.run();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        s_.vault = instance.plasmaVault;
        (s_.gateway, s_.strategyFuse, s_.config) =
            _deploymentComponents(entries, s_.vault);
    }

    function _depositAndDeployCapital(SimulationStateV3 memory s_) private {
        vm.startBroadcast(s_.privateKey);

        IERC20CyvbWbtcSimulationV3(VBWBTC).approve(s_.gateway, type(uint256).max);
        uint256 mintedShares =
            CyvbWbtcGateway_v5(s_.gateway).deposit(s_.depositAmount, s_.user, 0);
        require(mintedShares != 0, "no shares");

        FuseActionCyvbWbtcSimulationV3[] memory actions =
            new FuseActionCyvbWbtcSimulationV3[](1);
        actions[0] = FuseActionCyvbWbtcSimulationV3({
            fuse: s_.strategyFuse,
            data: abi.encodeWithSelector(
                FxMintCyvbWbtcFuse_v4.deployFreshCapital.selector,
                uint256(0),
                uint256(0),
                block.timestamp + 1 hours
            )
        });
        IPlasmaVaultCyvbWbtcSimulationV3(s_.vault).execute(actions);

        vm.stopBroadcast();

        s_.position = CyvbWbtcLtvConfig_v3(s_.config).positionId();
        require(s_.position != 0, "no f(x) position");

        s_.initialLtv =
            IFxLongPoolCyvbWbtcSimulationV3(FX_POOL).getPositionDebtRatio(s_.position);
        require(
            s_.initialLtv >= 48e16 && s_.initialLtv <= 52e16,
            "initial LTV outside tolerance"
        );
        require(
            MockCyvbUsdcSimulation_v3(s_.nested).balanceOf(s_.vault) != 0,
            "nested cyvbUSDC not funded"
        );
    }

    function _exercisePartialInstantExit(SimulationStateV3 memory s_) private {
        uint256 partialGross = s_.depositAmount / 5;
        require(partialGross != 0, "partial=0");

        vm.startBroadcast(s_.privateKey);
        IPlasmaVaultCyvbWbtcSimulationV3(s_.vault).approve(
            s_.gateway,
            type(uint256).max
        );
        CyvbWbtcGateway_v5(s_.gateway).withdraw(
            partialGross,
            s_.user,
            s_.user,
            type(uint256).max
        );
        vm.stopBroadcast();

        s_.postPartialExitLtv =
            IFxLongPoolCyvbWbtcSimulationV3(FX_POOL).getPositionDebtRatio(s_.position);
        require(
            s_.postPartialExitLtv <= MAX_INSTANT_LTV,
            "partial exit exceeds 55% LTV"
        );
    }

    function _exerciseFullExit(
        SimulationStateV3 memory s_
    ) private returns (uint256 finalSupply, uint256 finalAssets) {
        uint256 remainingShares =
            IPlasmaVaultCyvbWbtcSimulationV3(s_.vault).balanceOf(s_.user);
        require(remainingShares != 0, "no remaining shares");

        vm.startBroadcast(s_.privateKey);
        CyvbWbtcGateway_v5(s_.gateway).redeem(
            remainingShares,
            s_.user,
            s_.user,
            0
        );
        vm.stopBroadcast();

        finalSupply = IPlasmaVaultCyvbWbtcSimulationV3(s_.vault).totalSupply();
        finalAssets = IPlasmaVaultCyvbWbtcSimulationV3(s_.vault).totalAssets();

        require(finalSupply == 0, "final supply not zero");
        require(
            finalAssets <= s_.depositAmount / 10_000,
            "orphan assets after full exit"
        );
    }

    function _deploymentComponents(
        Vm.Log[] memory entries_,
        address expectedVault_
    ) private pure returns (address gateway, address strategyFuse, address config) {
        bytes32 signature = keccak256(
            "CyvbWbtcDeployed(address,address,address,address,address,address,address,address,address)"
        );

        for (uint256 i; i < entries_.length; ++i) {
            if (entries_[i].topics.length != 4 || entries_[i].topics[0] != signature) continue;

            address vault = address(uint160(uint256(entries_[i].topics[1])));
            if (vault != expectedVault_) continue;

            gateway = address(uint160(uint256(entries_[i].topics[2])));
            strategyFuse = address(uint160(uint256(entries_[i].topics[3])));

            (, config,,,,) = abi.decode(
                entries_[i].data,
                (address, address, address, address, address, address)
            );

            require(gateway != address(0) && strategyFuse != address(0) && config != address(0), "bad deployment event");
            return (gateway, strategyFuse, config);
        }

        revert("deployment event missing");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import "./DeployCyvbWBTC_v6.s.sol";
import "../contracts/CyvbWbtcGateway_v5.sol";
import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/FxMintCyvbWbtcFuse_v4.sol";

interface IERC20CyvbWbtcSimulationV2 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPlasmaVaultCyvbWbtcSimulationV2 {
    function execute(FuseActionCyvbWbtcSimulationV2[] calldata calls_) external;
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFxLongPoolCyvbWbtcSimulationV2 {
    function getPositionDebtRatio(uint256 tokenId) external view returns (uint256);
}

struct FuseActionCyvbWbtcSimulationV2 {
    address fuse;
    bytes data;
}

/// @notice Minimal ERC-4626-compatible nested vault used only on the isolated Anvil fork.
///         It deliberately keeps 1 asset unit == 1 share unit so the cyvbWBTC strategy
///         exercises the real live f(x) and CurveYield swap paths without depending on
///         a production cyvbUSDC deployment that does not exist yet.
contract MockCyvbUsdcSimulation_v2 {
    address public immutable asset;
    string public constant symbol = "cyvbUSDC";

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        require(IERC20CyvbWbtcSimulationV2(asset).transferFrom(msg.sender, address(this), assets), "transferFrom");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(msg.sender == owner, "owner");
        shares = assets;
        require(balanceOf[owner] >= shares, "shares");
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(IERC20CyvbWbtcSimulationV2(asset).transfer(receiver, assets), "transfer");
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "owner");
        require(balanceOf[owner] >= shares, "shares");
        assets = shares;
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(IERC20CyvbWbtcSimulationV2(asset).transfer(receiver, assets), "transfer");
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

/// @title SimulateCyvbWBTC_v2
/// @notice End-to-end cyvbWBTC deployment + deposit + strategy + partial instant exit + full exit
///         against an externally launched live Katana Anvil fork.
contract SimulateCyvbWBTC_v2 is Script {
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

    function run() external {
        require(block.chainid == 747474, "not Katana fork");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(privateKey);
        uint256 depositAmount = vm.envUint("SIM_DEPOSIT_AMOUNT");
        require(depositAmount != 0, "deposit=0");
        require(IERC20CyvbWbtcSimulationV2(VBWBTC).balanceOf(user) >= depositAmount, "user not funded");

        vm.startBroadcast(privateKey);
        MockCyvbUsdcSimulation_v2 nested = new MockCyvbUsdcSimulation_v2(VBUSDC);
        vm.stopBroadcast();

        vm.setEnv("CURVEYIELD_USDC_VAULT", vm.toString(address(nested)));
        vm.setEnv("KEEPER", vm.toString(user));
        vm.setEnv("FINAL_OWNER", vm.toString(user));

        vm.recordLogs();
        DeployCyvbWBTC_v6 deployment = new DeployCyvbWBTC_v6();
        FusionInstanceCyvbWBTCV1 memory instance = deployment.run();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (
            address gateway,
            address strategyFuse,
            address config
        ) = _deploymentComponents(entries, instance.plasmaVault);

        vm.startBroadcast(privateKey);

        IERC20CyvbWbtcSimulationV2(VBWBTC).approve(gateway, type(uint256).max);
        uint256 mintedShares = CyvbWbtcGateway_v5(gateway).deposit(depositAmount, user, 0);
        require(mintedShares != 0, "no shares");

        FuseActionCyvbWbtcSimulationV2[] memory actions =
            new FuseActionCyvbWbtcSimulationV2[](1);
        actions[0] = FuseActionCyvbWbtcSimulationV2({
            fuse: strategyFuse,
            data: abi.encodeWithSelector(
                FxMintCyvbWbtcFuse_v4.deployFreshCapital.selector,
                uint256(0),
                uint256(0),
                block.timestamp + 1 hours
            )
        });
        IPlasmaVaultCyvbWbtcSimulationV2(instance.plasmaVault).execute(actions);

        vm.stopBroadcast();

        uint256 position = CyvbWbtcLtvConfig_v3(config).positionId();
        require(position != 0, "no f(x) position");

        uint256 initialLtv = IFxLongPoolCyvbWbtcSimulationV2(FX_POOL).getPositionDebtRatio(position);
        require(initialLtv >= 48e16 && initialLtv <= 52e16, "initial LTV outside tolerance");
        require(nested.balanceOf(instance.plasmaVault) != 0, "nested cyvbUSDC not funded");

        uint256 partialGross = depositAmount / 5;
        require(partialGross != 0, "partial=0");

        vm.startBroadcast(privateKey);
        IPlasmaVaultCyvbWbtcSimulationV2(instance.plasmaVault).approve(gateway, type(uint256).max);
        CyvbWbtcGateway_v5(gateway).withdraw(
            partialGross,
            user,
            user,
            type(uint256).max
        );
        vm.stopBroadcast();

        uint256 postPartialExitLtv =
            IFxLongPoolCyvbWbtcSimulationV2(FX_POOL).getPositionDebtRatio(position);
        require(postPartialExitLtv <= MAX_INSTANT_LTV, "partial exit exceeds 55% LTV");

        uint256 remainingShares =
            IPlasmaVaultCyvbWbtcSimulationV2(instance.plasmaVault).balanceOf(user);
        require(remainingShares != 0, "no remaining shares");

        vm.startBroadcast(privateKey);
        CyvbWbtcGateway_v5(gateway).redeem(remainingShares, user, user, 0);
        vm.stopBroadcast();

        uint256 finalSupply = IPlasmaVaultCyvbWbtcSimulationV2(instance.plasmaVault).totalSupply();
        uint256 finalAssets = IPlasmaVaultCyvbWbtcSimulationV2(instance.plasmaVault).totalAssets();

        require(finalSupply == 0, "final supply not zero");
        // A fully redeemed zero-supply vault must not retain economically meaningful assets.
        require(finalAssets <= depositAmount / 10_000, "orphan assets after full exit");

        emit CyvbWbtcAnvilSimulationComplete(
            instance.plasmaVault,
            gateway,
            strategyFuse,
            depositAmount,
            initialLtv,
            postPartialExitLtv,
            finalSupply,
            finalAssets
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

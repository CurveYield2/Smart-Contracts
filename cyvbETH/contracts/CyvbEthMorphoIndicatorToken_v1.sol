// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./MorphoVbEthAccounting_v1.sol";

/// @title CyvbEthMorphoIndicatorToken_v1
/// @notice Non-transferable read-only indicator that exposes cyvbETH's accrued Morpho vbETH lender position
///         as an ERC20-shaped balance for IPOR's official market-7 ERC20 balance fuse.
/// @dev balanceOf(VAULT) uses Morpho's official expected-supply accounting, including interest accrued since
///      the market's last state-changing transaction. The indicator is priced with the same vbETH/ETH-USD
///      source as the vault underlying, so it contributes to NAV exactly as native vbETH does.
contract CyvbEthMorphoIndicatorToken_v1 {
    using MorphoVbEthAccounting_v1 for IMorphoCyvbEthV1;

    string public constant name = "Morpho vbETH Lending";
    string public constant symbol = "morpho-vbETH";
    uint8 public constant decimals = 18;

    address public immutable VAULT;
    IMorphoCyvbEthV1 public immutable MORPHO;
    bytes32 public immutable MORPHO_MARKET_ID;

    error NonTransferable();
    error InvalidTopology();

    constructor(address vault_, address morpho_, bytes32 morphoMarketId_, address vbEth_) {
        if (vault_ == address(0) || morpho_.code.length == 0 || vbEth_.code.length == 0) {
            revert InvalidTopology();
        }
        MorphoMarketParamsCyvbEthV1 memory params = IMorphoCyvbEthV1(morpho_).idToMarketParams(morphoMarketId_);
        if (params.loanToken != vbEth_) revert InvalidTopology();

        VAULT = vault_;
        MORPHO = IMorphoCyvbEthV1(morpho_);
        MORPHO_MARKET_ID = morphoMarketId_;
    }

    function totalSupply() external view returns (uint256) {
        return MORPHO.expectedSupplyAssets(MORPHO_MARKET_ID, VAULT);
    }

    function balanceOf(address account_) external view returns (uint256) {
        return account_ == VAULT ? MORPHO.expectedSupplyAssets(MORPHO_MARKET_ID, VAULT) : 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }
}

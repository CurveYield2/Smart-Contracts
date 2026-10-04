// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title CurveYieldSeasonPoints (#24)
/// @notice One per leaderboard season: non-transferable, non-decaying points, minted only by the leaderboard.
contract CurveYieldSeasonPoints {
    address public immutable LEADERBOARD;
    uint256 public immutable SEASON;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    error NotLeaderboard();
    error NonTransferable();

    constructor(uint256 season_, string memory name_, string memory symbol_) {
        LEADERBOARD = msg.sender;
        SEASON = season_;
        name = name_;
        symbol = symbol_;
    }

    function mint(address to_, uint256 amount_) external {
        if (msg.sender != LEADERBOARD) revert NotLeaderboard();
        balanceOf[to_] += amount_;
        totalSupply += amount_;
        emit Transfer(address(0), to_, amount_);
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

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

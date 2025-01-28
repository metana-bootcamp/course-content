// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

contract TwentyOneGame {
    address public player1;
    address public player2;
    uint256 public betAmount;
    bool public gameOver;

    struct GameState {
        uint8 seq;
        uint8 num;
        address payable whoseTurn;
    }
    GameState public state;

    uint256 public timeoutInterval;
    uint256 public timeout = 2**256 - 1;

    event GameStarted();
    event TimeoutStarted();
    event MoveMade(address player, uint8 seq, uint8 value);


    // Setup methods

    constructor(uint256 _timeoutInterval) public payable {
        player1 = msg.sender;
        betAmount = msg.value;
        timeoutInterval = _timeoutInterval;
    }

    function join() public payable {
        require(player2 == address(0), "Game has already started.");
        require(!gameOver, "Game was canceled.");
        require(msg.value == betAmount, "Wrong bet amount.");

        player2 = msg.sender;
        state.whoseTurn = payable(player1);

        emit GameStarted();
    }

    function cancel() public {
        require(msg.sender == player1, "Only first player may cancel.");
        require(player2 == address(0), "Game has already started.");

        gameOver = true;
        msg.sender.transfer(address(this).balance);
    }


    // Play methods

    function move(uint8 seq, uint8 value) public {
        require(!gameOver, "Game has ended.");
        require(msg.sender == state.whoseTurn, "Not your turn.");
        require(value >= 1 && value <= 3,
            "Move out of range. Must be between 1 and 3.");
        require(state.num + value <= 21, "Move would exceed 21.");
        require(state.seq == seq, "Incorrect sequence number.");

        state.num += value;
        state.whoseTurn = payable(opponentOf(msg.sender));
        state.seq += 1;

        // Clear timeout
        timeout = 2**256 - 1;

        if (state.num == 21) {
            gameOver = true;
            msg.sender.transfer(address(this).balance);
        }

        emit MoveMade(msg.sender, seq, value);
    }

    function moveFromState(uint8 seq, uint8 num, bytes memory sig, uint8 value) public {
        require(seq >= state.seq, "Sequence number cannot go backwards.");

        bytes32 message = prefixed(keccak256(abi.encodePacked(address(this), seq, num)));
        require(recoverSigner(message, sig) == opponentOf(msg.sender));

        state.seq = seq;
        state.num = num;
        state.whoseTurn = msg.sender;

        move(seq, value);
    }

    function opponentOf(address player) internal view returns (address) {
        require(player2 != address(0), "Game has not started.");

        if (player == player1) {
            return player2;
        } else if (player == player2) {
            return player1;
        } else {
            revert("Invalid player.");
        }
    }


    // Timeout methods

    function startTimeout() public {
        require(!gameOver, "Game has ended.");
        require(state.whoseTurn == opponentOf(msg.sender),
            "Cannot start a timeout on yourself.");

        timeout = now + timeoutInterval;
        emit TimeoutStarted();
    }

    function claimTimeout() public {
        require(!gameOver, "Game has ended.");
        require(now >= timeout);

        gameOver = true;
        payable(opponentOf(state.whoseTurn)).transfer(address(this).balance);
    }


    // Signature methods

    function splitSignature(bytes memory sig)
        internal
        pure
        returns (uint8, bytes32, bytes32)
    {
        require(sig.length == 65);

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }

        return (v, r, s);
    }

    function recoverSigner(bytes32 message, bytes memory sig)
        internal
        pure
        returns (address)
    {
        uint8 v;
        bytes32 r;
        bytes32 s;

        (v, r, s) = splitSignature(sig);

        return ecrecover(message, v, r, s);
    }

    // Builds a prefixed hash to mimic the behavior of eth_sign.
    function prefixed(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}
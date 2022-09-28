// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Import chainlink contracts
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

// Import this file to use console.log
import "hardhat/console.sol";

contract MultiLotto is VRFConsumerBaseV2, Ownable {
    // Use OpenZeppelin implementation of payable address
    // for sending eth more safely.
    using Address for address payable;

    // ChainLink VRF vars:

    VRFCoordinatorV2Interface COORDINATOR;
    // Your subscription ID.
    uint64 s_subscriptionId;

    // Rinkeby coordinator. For other networks,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    address vrfCoordinator = 0x6168499c0cFfCaCD319c818142124B7A15E857ab;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 s_keyHash =
        0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;
    // num random words to return from chain link VRF
    uint32 numWords = 1;

    // Cyrpto Lotto vars

    // needed for random sampling calc
    uint256 private constant MAX_INT = 2**256 - 1;
    //  the precent taken by the contract creators;
    uint256 public ownerFee = 2.0;
    // where the contract fee is to be sent upon
    // bet placement, by default will be the owner address
    // can be changed later by owner;
    address payable private feeAddress;

    // minimum deposit
    uint256 public defaultMinDeposit = 10**15; // in wei, 1 thousanth of an eth

    // All data needed to parameterized the lotto
    // and its execution
    struct Lotto {
        // lotto end time
        uint256 unlockTime;
        // array of participant addresses
        address[] participants;
        // mapping of participants to their amounts
        mapping(address => uint256) amounts;
        uint256 totalAmount;
        // we will store the random result here
        uint256 randomResult;
        // the winner's address
        address winner;
        // minimum deposit
        uint256 minDeposit;
        // is the lotto closed or is it open and accepting bets
        bool lottoClosed;
        // runningSum and runningIndex are
        // needed to compute winner safely in a partial manner,
        // without hitting a block
        // gas limit in the case of an extreme amount of participants;
        uint256 runningSum;
        uint256 runningIndex;
    }

    mapping(uint256 => Lotto) public lottos;

    // Lotto is not closed and no longer accepting bets
    event LottoClosed(uint256 lottoId);
    // Winner has been determined
    event WinnerSelected(uint256 lottoId, address winner, uint256 amount);
    // Winner has withdrawn their funds
    event Withdrawal(
        uint256 lottoId,
        address who,
        uint256 amount,
        uint256 when
    );
    // Someone has made a bet
    event Deposit(uint256 lottoId, address who, uint256 amount);
    // Random draw event
    event RandomDraw(uint256 lottoId, uint256 randNum);

    constructor() VRFConsumerBaseV2(vrfCoordinator) {
        feeAddress = payable(owner());
    }

    function getLottoData(uint256 _id) external view returns (Lotto) {
        return lottos[_id];
    }

    // Initializes the ChainLink VRF call
    function getRandomNumber() private returns (uint256 requestId) {
        return
            COORDINATOR.requestRandomWords(
                s_keyHash,
                s_subscriptionId,
                requestConfirmations,
                callbackGasLimit,
                numWords
            );
    }

    // fulfillRandomWords function called by ChainLink once the random 'word'
    // ready, note the random words is an array of uint256 integers
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        randomResult = randomWords[0] % MAX_INT;
        emit RandomDraw(randomResult);
    }

    // Allow anyone to call this function just in case owner
    // disappears
    function computeWinnerPartial(uint256 N) external {
        require(lottoClosed, "Lotto not yet closed.");
        require(winner == address(0), "Winner already selected");
        require(N > runningIndex, "N too small");

        uint256 upper = N < participants.length ? N : participants.length;

        for (uint256 i = runningIndex; i < upper; i++) {
            address participant = participants[i];
            runningSum += amounts[participant];
            if (randomResult <= (runningSum / totalAmount) * MAX_INT) {
                winner = participant;
                emit WinnerSelected(winner, address(this).balance);
                break;
            }
        }
        runningIndex = participants.length - 1;
    }

    // can be called by anyone to closed the lotto once the
    // unlockTime has passed
    function closeLotto() external {
        require(block.timestamp > unlockTime, "Still too early");
        // Close lotto
        lottoClosed = true;
        // else get the random number and find the winner.
        getRandomNumber();
        // Emit closed lotto event;
        emit LottoClosed();
    }

    // allows anyone to call this function and send winnings to the winner
    // Of course this will cost the caller gas, so presumably only the winner
    // or a realted entity will be incentivized to make the call;
    function withdrawWinnings() external {
        require(winner != address(0), "Winner is not yet determined.");
        uint256 balance = address(this).balance;
        payable(winner).sendValue(balance);
        emit Withdrawal(winner, balance, block.timestamp);
    }

    // Allows the contract owner to change the feeAddress
    function setFeeAddress(address payable newAddress) external onlyOwner {
        feeAddress = newAddress;
    }

    // Allows the contract owner to set the min deposit
    function setMinDeposit(uint256 newMinDeposit) external onlyOwner {
        minDeposit = newMinDeposit;
    }

    // Allows the anyone to view the fee address
    function getFeeAddress() external view returns (address) {
        return feeAddress;
    }

    // Here the contract receives bets, the lotto must be still open
    // and the amount sent must exceed the minDeposit amount;
    receive() external payable {
        require(msg.value > minDeposit, "Sent amount is less than minDeposit");
        require(!lottoClosed, "Lotto is closed, cannot receive funds");
        if (amounts[msg.sender] == 0) {
            participants[participants.length] = msg.sender;
        }
        amounts[msg.sender] = amounts[msg.sender] + msg.value;
        totalAmount += msg.value;
        // send fee to owner
        payable(feeAddress).sendValue((ownerFee * msg.value) / 100);
        require(
            participants.length > 0,
            "bug in code, participants.length cannot equal zero after deposit"
        );
        // Emit deposit event;
        emit Deposit(msg.sender, msg.value);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Import chainlink contracts
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
// Uniswap router needed for eth -> link exchanges
import "./IUniswapRouter.sol";

// Import this file to use console.log
import "hardhat/console.sol";

// needed for random sampling calc
uint256 constant MAX_INT = 2**256 - 1;

contract CryptoLotto is VRFConsumerBaseV2, Ownable {
    // Use OpenZeppelin implementation of payable address
    // for sending eth more safely.
    using Address for address payable;

    // ChainLink VRF vars:
    ERC20 linkToken;

    VRFCoordinatorV2Interface COORDINATOR;
    // Your subscription ID.
    uint64 s_subscriptionId;

    // Rinkeby coordinator. For other networks,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    address vrfCoordinator;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 s_keyHash;

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

    struct Lotto {
        uint256 id;
        // array of participant addresses
        address[] participants;
        // mapping of participants to their amounts
        mapping(address => uint256) amounts;
        // lotto end time
        uint256 unlockTime;
        uint256 totalAmount;
        uint256 balance;
        // we will store the random result here
        uint256 randomResult;
        // the winner's address
        address winner;
        // is the lotto closed or is it open and accepting bets
        bool lottoClosed;
        // runningSum and runningIndex are
        // needed to compute winner safely in a partial manner,
        // without hitting a block
        // gas limit in the case of an extreme amount of participants;
        uint256 runningSum;
        uint256 runningIndex;
    }

    // Cyrpto Lotto vars
    mapping(uint256 => Lotto) public lottos;
    mapping(uint256 => uint256) private _vrfRequests;

    IUniswapRouter ur; // uniswap router contract

    //  the precent taken by the contract creators;
    uint256 public ownerFee = 2.0;
    // where the contract fee is to be sent upon
    // bet placement, by default will be the owner address
    // can be changed later by owner;
    address payable private feeAddress;
    // minimum deposit
    uint256 public minDeposit = 10**15; // in wei, 0.001 ETH

    address wEthAddress;
    uint256 linkPremium;

    // LottoCreated
    event LottoCreated(uint256 _lottoID);
    // Lotto is not closed and no longer accepting bets
    event LottoClosed(uint256 _lottoID);
    // Winner has been determined
    event WinnerSelected(uint256 _lottoID, address _winner, uint256 amount);
    // Winner has withdrawn their funds
    event Withdrawal(
        uint256 _lottoID,
        address _address,
        uint256 amount,
        uint256 when
    );
    // Someone has made a bet
    event Deposit(uint256 lottoID, address _address, uint256 _amount);
    // Random draw event
    event RandomDraw(uint256 _lottoID, uint256 _randNum);

    constructor(
        address _linkTokenAddress,
        address _vrfCoordinator,
        bytes32 _s_keyHash,
        address _uniswapRouterAddress,
        address _wEth,
        uint256 _linkPremium
    ) VRFConsumerBaseV2(vrfCoordinator) {
        // init wEth address
        wEthAddress = _wEth;
        // init linkPremium (how much link needed per VRF call)
        linkPremium = _linkPremium;
        // init fee address
        feeAddress = payable(owner());
        // initialize chainlink token
        s_keyHash = _s_keyHash;
        linkToken = ERC20(_linkTokenAddress);
        // initialize the COORDINATOR
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        // Create a subscription with a new subscription ID, the owner of this subscription will
        // be this contract
        address[] memory consumers = new address[](1);
        consumers[0] = address(this);
        s_subscriptionId = COORDINATOR.createSubscription();
        // Add this contract as a consumer of its own subscription.
        COORDINATOR.addConsumer(s_subscriptionId, consumers[0]);
        // setup uniswap router
        ur = IUniswapRouter(_uniswapRouterAddress);
    }

    function setLinkPremium(uint256 _linkPremium) external onlyOwner {
        linkPremium = _linkPremium;
    }

    // return link balance, useful for monitoring;
    function linkBalance() external view returns (uint256 bal) {
        return linkToken.balanceOf(address(this));
    }

    // incase link token accumulates (should not) owner can withdraw
    // and correct the situation manually
    // TODO: remove after better testing
    function withdrawLink() external onlyOwner {
        linkToken.transfer(owner(), linkToken.balanceOf(address(this)));
    }

    modifier lottoExists(uint256 lottoID) {
        require(lottos[lottoID].id != 0, "Lotto does not exist");
        _;
    }

    uint256 public numLottos;

    function createLotto(uint256 unlockTime) external onlyOwner {
        Lotto storage lotto = lottos[numLottos + 1];
        lotto.unlockTime = unlockTime;
        numLottos += 1;
        emit LottoCreated(numLottos);
    }

    uint256 waitPeriod = 24 * 60 * 60 * 60; // 60 days;

    function deleteLotto(uint256 lottoID)
        external
        onlyOwner
        lottoExists(lottoID)
    {
        require(lottos[lottoID].lottoClosed, "Lotto is not closed");
        require(
            lottos[lottoID].unlockTime < block.timestamp + waitPeriod,
            "Wait period has not passed."
        );
        if (lottos[lottoID].balance > 0) {
            // send unclaimed balance to owner
            // TODO: implement recyling to reward users
            payable(feeAddress).sendValue(lottos[lottoID].balance);
        }
        delete lottos[lottoID];
    }

    function getWinner(uint256 lottoID) external view returns (address) {
        return lottos[lottoID].winner;
    }

    // Initializes the ChainLink VRF call
    function getRandomNumber(uint256 lottoID)
        private
        returns (uint256 requestId)
    {
        uint256 rID = COORDINATOR.requestRandomWords(
            s_keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        _vrfRequests[requestId] = lottoID;
        return rID;
    }

    // fulfillRandomWords function called by ChainLink once the random 'word'
    // ready, note the random words is an array of uint256 integers
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        uint256 lottoID = _vrfRequests[requestId];
        lottos[lottoID].randomResult = randomWords[0] % MAX_INT;
        emit RandomDraw(lottoID, lottos[lottoID].randomResult);
    }

    // Allow anyone to call this function just in case owner
    // disappears
    function computeWinnerPartial(uint256 lottoID, uint256 N) external {
        require(lottos[lottoID].lottoClosed, "Lotto not yet closed.");
        require(
            lottos[lottoID].winner == address(0),
            "Winner already selected"
        );
        require(N > lottos[lottoID].runningIndex, "N too small");

        uint256 upper = N < lottos[lottoID].participants.length
            ? N
            : lottos[lottoID].participants.length;

        for (uint256 i = lottos[lottoID].runningIndex; i < upper; i++) {
            address participant = lottos[lottoID].participants[i];
            lottos[lottoID].runningSum += lottos[lottoID].amounts[participant];
            if (
                lottos[lottoID].randomResult <=
                (lottos[lottoID].runningSum / lottos[lottoID].totalAmount) *
                    MAX_INT
            ) {
                lottos[lottoID].winner = participant;
                emit WinnerSelected(
                    lottoID,
                    lottos[lottoID].winner,
                    lottos[lottoID].balance
                );
                break;
            }
        }
        lottos[lottoID].runningIndex = lottos[lottoID].participants.length - 1;
    }

    // can be called by anyone to closed the lotto once the
    // unlockTime has passed
    function closeLotto(uint256 lottoID) external lottoExists(lottoID) {
        require(
            block.timestamp > lottos[lottoID].unlockTime,
            "Still too early"
        );
        // Close lotto
        lottos[lottoID].lottoClosed = true;
        // buy link and add to chainlink subscription
        buyNeededLink(lottoID);
        // else get the random number and find the winner.
        getRandomNumber(lottoID);
        // Emit closed lotto event;
        emit LottoClosed(lottoID);
    }

    // buys enough link for one VRF call
    function buyNeededLink(uint256 lottoID) private {
        address[] memory path = new address[](2);
        path[0] = wEthAddress;
        path[1] = address(linkToken);
        uint256[] memory amountOut = ur.getAmountsIn(linkPremium, path);
        require(
            lottos[lottoID].balance >= amountOut[0],
            "Lotto pool has insufficient balance to get link"
        );
        lottos[lottoID].balance -= amountOut[0];
        ur.swapExactETHForTokens{value: amountOut[0]}(
            linkPremium,
            path,
            address(this),
            block.timestamp + 10 * 60
        );
    }

    // allows anyone to call this function and send winnings to the winner
    // Of course this will cost the caller gas, so presumably only the winner
    // or a realted entity will be incentivized to make the call;
    function withdrawWinnings(uint256 lottoID) external lottoExists(lottoID) {
        require(
            lottos[lottoID].winner != address(0),
            "Winner is not yet determined."
        );
        payable(lottos[lottoID].winner).sendValue(lottos[lottoID].balance);
        emit Withdrawal(
            lottoID,
            lottos[lottoID].winner,
            lottos[lottoID].balance,
            block.timestamp
        );
    }

    // Allows the contract owner to change the feeAddress
    function setFeeAddress(address payable newAddress) external onlyOwner {
        feeAddress = newAddress;
    }

    // Allows the contract owner to set the min deposit in wei
    function setMinDeposit(uint256 newMinDeposit) external onlyOwner {
        minDeposit = newMinDeposit;
    }

    // Allows anyone to view the fee address
    function getFeeAddress() external view returns (address) {
        return feeAddress;
    }

    // Here the contract receives bets, the lotto must be still open
    // and the amount sent must exceed the minDeposit amount;
    function deposit(uint256 lottoID) external payable lottoExists(lottoID) {
        require(msg.value > minDeposit, "Sent amount is less than minDeposit");
        require(
            !lottos[lottoID].lottoClosed,
            "Lotto is closed, cannot receive funds"
        );
        if (lottos[lottoID].amounts[msg.sender] == 0) {
            lottos[lottoID].participants[
                lottos[lottoID].participants.length
            ] = msg.sender;
        }
        lottos[lottoID].amounts[msg.sender] =
            lottos[lottoID].amounts[msg.sender] +
            msg.value;
        lottos[lottoID].totalAmount += msg.value;
        // calcuate fee
        uint256 fee = (ownerFee * msg.value) / 100;
        // increment lotto pool balance by deposit minus fee
        lottos[lottoID].balance += msg.value - fee;
        // send fee to owner
        payable(feeAddress).sendValue(fee);
        require(
            lottos[lottoID].participants.length > 0,
            "Error, participants.length cannot equal zero after deposit"
        );
        // Emit deposit event;
        emit Deposit(lottoID, msg.sender, msg.value);
    }
}

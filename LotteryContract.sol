// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // Import SafeERC20
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title LotteryContract (WBNB Prize Version)
 * @dev Users enter LotteryToken (LTK) for a chance to win a WBNB prize. Uses Chainlink VRF.
 */
contract LotteryContract is VRFConsumerBaseV2, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20; // Use SafeERC20 for IERC20

    // --- State Variables ---
    IERC20 public immutable lotteryToken; // Address of the LTK token
    IERC20 public immutable wbnbToken;    // Address of the WBNB token (Prize Token)

    // VRF Variables
    VRFCoordinatorV2Interface COORDINATOR;
    LinkTokenInterface LINKTOKEN; // Optional: only needed if managing LINK balance explicitly
    uint64 s_subscriptionId;
    address vrfCoordinator;
    bytes32 keyHash; // Gas lane key hash
    uint32 callbackGasLimit = 200000; // INCREASED LIMIT - winner selection is intensive
    uint16 requestConfirmations = 3;
    uint32 numWords = 1;

    // Lottery Round Variables
    uint256 public currentLotteryId;
    uint256 public roundStartTime;
    uint256 public roundDuration;
    uint256 public currentPrizeWBNB; // Renamed variable
    bool public isRoundActive;

    // Entry tracking for the current round
    mapping(address => uint256) public currentEntries; // User => amount LTK entered in current round
    address[] public currentParticipants; // List of users who entered
    mapping(address => bool) public hasEnteredCurrentRound; // Optimization
    uint256 public totalLTKEnteredCurrentRound;

    // Storing results
    mapping(uint256 => uint256) public requestIdToLotteryId; // VRF request ID => Lottery ID
    mapping(uint256 => address) public lotteryIdToWinner; // Lottery ID => Winner address
    mapping(uint256 => uint256) public lotteryIdToPrize; // Lottery ID => Prize amount won (WBNB)
    mapping(uint256 => uint256) public lotteryIdToRandomWord; // Lottery ID => VRF Result

    // Events
    event RoundStarted(uint256 indexed lotteryId, uint256 endTime, uint256 prizeAmountWBNB); // Updated event param name
    event LotteryEntered(uint256 indexed lotteryId, address indexed user, uint256 amountLTK);
    event DrawRequested(uint256 indexed lotteryId, uint256 requestId);
    event WinnerSelected(uint256 indexed lotteryId, address indexed winner, uint256 prizeAmountWBNB, uint256 randomResult); // Updated event param name

    // --- Constructor ---
    constructor(
        address _lotteryTokenAddress,
        address _wbnbTokenAddress, // Added WBNB address parameter
        address _vrfCoordinator,
        address _linkAddress, // Address of LINK token
        uint64 _subscriptionId,
        bytes32 _keyHash
    ) VRFConsumerBaseV2(_vrfCoordinator) Ownable(msg.sender) {
        require(_lotteryTokenAddress != address(0), "LotteryContract: Invalid LTK address");
        require(_wbnbTokenAddress != address(0), "LotteryContract: Invalid WBNB address"); // Check WBNB address

        lotteryToken = IERC20(_lotteryTokenAddress);
        wbnbToken = IERC20(_wbnbTokenAddress); // Store WBNB token address

        vrfCoordinator = _vrfCoordinator;
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        LINKTOKEN = LinkTokenInterface(_linkAddress);
        s_subscriptionId = _subscriptionId;
        keyHash = _keyHash;
    }

    // --- Lottery Management (Owner) ---

    /**
     * @notice Starts a new lottery round.
     * @param _duration Duration of the round in seconds.
     * @param _prizeAmountWBNB The amount of WBNB to be awarded (in wei).
     * @dev The contract must hold enough WBNB balance BEFORE starting. Owner needs to transfer WBNB.
     */
    function startNewRound(uint256 _duration, uint256 _prizeAmountWBNB) external onlyOwner {
        require(!isRoundActive, "LotteryContract: Previous round still active");
        require(_duration > 0, "LotteryContract: Duration must be positive");
        // Check WBNB balance of this contract
        require(wbnbToken.balanceOf(address(this)) >= _prizeAmountWBNB, "LotteryContract: Insufficient WBNB balance for prize");

        currentLotteryId++;
        isRoundActive = true;
        roundStartTime = block.timestamp;
        roundDuration = _duration;
        currentPrizeWBNB = _prizeAmountWBNB; // Use renamed variable

        // Reset entries for the new round
        delete currentParticipants;
        totalLTKEnteredCurrentRound = 0;
        // Note: currentEntries mapping doesn't strictly need deletion if overwritten

        emit RoundStarted(currentLotteryId, roundStartTime + roundDuration, _prizeAmountWBNB); // Use renamed variable in event
    }

    /**
     * @notice Requests randomness to pick a winner for the completed round.
     * @dev Can only be called by owner after the round ends. Requires LINK funding.
     */
    function requestLotteryDraw() external onlyOwner {
        require(isRoundActive, "LotteryContract: No round currently active");
        require(block.timestamp >= roundStartTime + roundDuration, "LotteryContract: Round has not ended yet");
        require(totalLTKEnteredCurrentRound > 0, "LotteryContract: No entries in this round");

        isRoundActive = false; // Mark round as ended, awaiting VRF result

        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );

        requestIdToLotteryId[requestId] = currentLotteryId;
        emit DrawRequested(currentLotteryId, requestId);
    }


    // --- User Functions ---

    /**
     * @notice Enters the lottery by depositing/burning LTK.
     * @param _amountLTK Amount of LotteryToken to enter.
     */
    function enterLottery(uint256 _amountLTK) external nonReentrant {
        require(isRoundActive, "LotteryContract: Lottery round not active");
        require(_amountLTK > 0, "LotteryContract: Amount must be positive");

        // Transfer LTK (or burn if LotteryToken is Burnable and you prefer that)
        lotteryToken.safeTransferFrom(msg.sender, address(this), _amountLTK); // Assumes collecting LTK, change to burnFrom if needed

        // Track entry
        currentEntries[msg.sender] = currentEntries[msg.sender].add(_amountLTK);
        totalLTKEnteredCurrentRound = totalLTKEnteredCurrentRound.add(_amountLTK);

        if (!hasEnteredCurrentRound[msg.sender]) {
            currentParticipants.push(msg.sender);
            hasEnteredCurrentRound[msg.sender] = true;
        }
        emit LotteryEntered(currentLotteryId, msg.sender, _amountLTK);
    }


    // --- VRF Callback ---

    /**
     * @notice Callback function used by VRF Coordinator to return random word. SELECTS WINNER AND PAYS WBNB.
     * @param requestId The unique identifier for the VRF request.
     * @param randomWords Array of random words requested (we only need one).
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override nonReentrant {
        uint256 lotteryId = requestIdToLotteryId[requestId];
        require(lotteryId == currentLotteryId, "LotteryContract: Fulfilling for wrong/old lottery ID");
        require(lotteryIdToWinner[lotteryId] == address(0), "LotteryContract: Draw already fulfilled");

        uint256 randomWord = randomWords[0];
        lotteryIdToRandomWord[lotteryId] = randomWord;

        address winner = address(0);
        uint256 prizeAmountWBNB = currentPrizeWBNB; // Get prize amount set for this round

        if (currentParticipants.length > 0 && totalLTKEnteredCurrentRound > 0) {
            // Weighted Winner Selection (same logic as before)
            uint256 winningTicket = randomWord % totalLTKEnteredCurrentRound;
            uint256 cumulativeTickets = 0;
            for (uint i = 0; i < currentParticipants.length; i++) {
                address participant = currentParticipants[i];
                uint256 participantTickets = currentEntries[participant];
                if (participantTickets > 0) {
                     cumulativeTickets = cumulativeTickets.add(participantTickets);
                     if (winningTicket < cumulativeTickets) {
                         winner = participant;
                         break;
                     }
                }
                 // Resetting entry for next round
                 delete currentEntries[participant];
                 delete hasEnteredCurrentRound[participant];
            }
        }

        if (winner != address(0)) {
            lotteryIdToWinner[lotteryId] = winner;
            lotteryIdToPrize[lotteryId] = prizeAmountWBNB;

             // --- Send WBNB Prize ---
             // Ensure contract has sufficient WBNB balance (checked at start, but good practice)
             // require(wbnbToken.balanceOf(address(this)) >= prizeAmountWBNB, "LotteryContract: Internal Insufficient WBNB for prize");
             wbnbToken.safeTransfer(winner, prizeAmountWBNB); // Transfer WBNB prize

             emit WinnerSelected(lotteryId, winner, prizeAmountWBNB, randomWord); // Use renamed prize variable in event
        } else {
             emit WinnerSelected(lotteryId, address(0), 0, randomWord); // Indicate no winner
        }
         delete requestIdToLotteryId[requestId];
    }

    // --- View Functions --- (Unchanged, but keep them)
    function getRoundEndTime() external view returns (uint256) {
        if (!isRoundActive) return 0;
        return roundStartTime + roundDuration;
    }

    function getUserEntryAmount(address _user) external view returns (uint256) {
        return currentEntries[_user];
    }

    // --- Admin ---
    function withdrawLink(address _to, uint256 _amount) external onlyOwner {
       require(LINKTOKEN.transfer(_to, _amount), "LotteryContract: Unable to withdraw LINK");
    }

     /**
      * @notice Allow owner to withdraw stuck WBNB prize tokens. USE WITH CAUTION.
      * @param _to Address to send WBNB to.
      * @param _amount Amount of WBNB to withdraw.
      */
     function withdrawStuckWBNB(address _to, uint256 _amount) external onlyOwner {
         require(_to != address(0), "LotteryContract: Invalid recipient address");
         wbnbToken.safeTransfer(_to, _amount);
     }

     /**
      * @notice Allow owner to withdraw accidentally sent *other* ERC20 tokens.
      */
     function withdrawStuckERC20(address _tokenAddress, address _to, uint256 _amount) external onlyOwner {
         require(_tokenAddress != address(wbnbToken), "LotteryContract: Use withdrawStuckWBNB for WBNB");
         require(_tokenAddress != address(lotteryToken), "LotteryContract: Cannot withdraw LTK this way"); // Or allow if intended
         IERC20(_tokenAddress).safeTransfer(_to, _amount);
     }

     function setCallbackGasLimit(uint32 _limit) external onlyOwner {
         callbackGasLimit = _limit;
     }

    // --- Receive Function ---
    // REMOVED - No longer needed for BNB prize funding
    // receive() external payable {}
}

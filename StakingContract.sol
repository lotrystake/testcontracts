// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./LotteryToken.sol"; // Assuming LotteryToken.sol is in the same directory

/**
 * @title StakingContract
 * @dev Users stake an ERC20 token (e.g., WBNB) and earn LotteryToken (LTK).
 */
contract StakingContract is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public immutable stakeToken; // The token being staked (e.g., WBNB address)
    LotteryToken public immutable lotteryToken; // The LTK reward token address

    // Staking info
    mapping(address => uint256) public stakes; // User address => staked amount
    uint256 public totalStaked;

    // Reward info
    uint256 public rewardRate; // LTK rewards per second (e.g., 1e18 = 1 LTK/sec for ALL staked tokens combined)
    uint256 public lastUpdateTime; // Timestamp of the last reward calculation globally
    uint256 public rewardPerTokenStored; // Accumulated rewards per token staked globally

    mapping(address => uint256) public userRewardPerTokenPaid; // Tracks reward snapshot per user
    mapping(address => uint256) public rewards; // Tracks earned but unclaimed rewards per user

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateSet(uint256 newRate);

    constructor(address _stakeTokenAddress, address _lotteryTokenAddress) Ownable(msg.sender) {
        require(_stakeTokenAddress != address(0), "StakingContract: Invalid stake token address");
        require(_lotteryTokenAddress != address(0), "StakingContract: Invalid lottery token address");

        stakeToken = IERC20(_stakeTokenAddress);
        lotteryToken = LotteryToken(_lotteryTokenAddress); // Assumes LotteryToken type
        lastUpdateTime = block.timestamp;
    }

    // --- Modifiers ---

    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken(); // Update global reward accumulator
        lastUpdateTime = block.timestamp; // Update timestamp
        rewards[_account] = earned(_account); // Update user's claimable rewards
        userRewardPerTokenPaid[_account] = rewardPerTokenStored; // Record the user's reward snapshot
        _;
    }

    // --- Reward Calculation ---

    /**
     * @dev Calculates the reward multiplier accumulated since the last update.
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored; // No rewards if nothing is staked
        }
        uint256 timeElapsed = block.timestamp.sub(lastUpdateTime);
        // rewardRate is LTK per second for the *total* supply
        // rewardPerTokenStored increases by (time * rewardRate) / totalStaked
        return rewardPerTokenStored.add(
            timeElapsed.mul(rewardRate).mul(1e18).div(totalStaked) // Use 1e18 for precision
        );
    }

    /**
     * @dev Calculates the amount of rewards earned by an account but not yet claimed.
     */
    function earned(address _account) public view returns (uint256) {
        uint256 currentRewardPerToken = rewardPerToken();
        uint256 stakedAmount = stakes[_account];
        // Earned = stake * (globalRewardPerToken - userSnapshot) / precision + existingUnclaimed
        return stakedAmount
            .mul(currentRewardPerToken.sub(userRewardPerTokenPaid[_account]))
            .div(1e18) // Divide by precision factor
            .add(rewards[_account]);
    }

    // --- Staking Functions ---

    /**
     * @notice Stakes tokens into the contract.
     * @param _amount Amount of stakeToken to deposit.
     */
    function stake(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(_amount > 0, "StakingContract: Cannot stake 0");
        stakes[msg.sender] = stakes[msg.sender].add(_amount);
        totalStaked = totalStaked.add(_amount);
        stakeToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);
    }

    /**
     * @notice Withdraws staked tokens from the contract.
     * @param _amount Amount of stakeToken to withdraw.
     */
    function unstake(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(_amount > 0, "StakingContract: Cannot unstake 0");
        require(stakes[msg.sender] >= _amount, "StakingContract: Insufficient staked balance");
        stakes[msg.sender] = stakes[msg.sender].sub(_amount);
        totalStaked = totalStaked.sub(_amount);
        stakeToken.safeTransfer(msg.sender, _amount);
        emit Unstaked(msg.sender, _amount);
    }

    // --- Reward Function ---

    /**
     * @notice Claims earned LotteryToken (LTK) rewards.
     */
    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0; // Clear pending rewards before minting
            // Minting must be enabled for this contract address in LotteryToken
            lotteryToken.mint(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // --- Admin Functions ---

    /**
     * @notice Sets the LTK reward rate per second.
     * @param _newRate The new rate (e.g., 1e18 for 1 LTK/sec distributed across all stakers).
     * @dev MUST call updateReward on SOME address (e.g., owner) before changing rate.
     */
    function setRewardRate(uint256 _newRate) external onlyOwner updateReward(address(0)) { // Update global state
        rewardRate = _newRate;
        emit RewardRateSet(_newRate);
    }

     /**
      * @notice Emergency function to withdraw accidentally sent ERC20 tokens.
      * @param _tokenAddress The address of the ERC20 token.
      * @param _to The address to send the tokens to.
      * @param _amount The amount to withdraw.
      */
     function withdrawStuckERC20(address _tokenAddress, address _to, uint256 _amount) external onlyOwner {
         require(_tokenAddress != address(stakeToken), "StakingContract: Cannot withdraw stake token");
         require(_tokenAddress != address(lotteryToken), "StakingContract: Cannot withdraw reward token");
         IERC20(_tokenAddress).safeTransfer(_to, _amount);
     }
}

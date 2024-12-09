// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "https://github.com/hashgraph/hedera-smart-contracts/blob/main/contracts/system-contracts/hedera-token-service/HederaTokenService.sol";
import "https://github.com/hashgraph/hedera-smart-contracts/blob/main/contracts/system-contracts/HederaResponseCodes.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Time-Locked Staking Contract on Hedera
 * @notice Conceptual demonstration. Not for production use without further testing and audits.
 */
contract hashhold is HederaTokenService {
    // HTS token for staking
    address public stakingToken;      // HTS token address for staking
    address public rewardToken;       // HTS token address for reward distribution
    mapping(address => uint256) public totalStaked;
    uint256 public penaltyRate = 10;       
    uint256 public totalHBARRewards; 
    uint256 public epochId = 0;   
    IPyth pyth;
    bytes32 hbarUsdPriceId;
    uint constant ONE_MONTH = 30 days;
    uint constant ONE_YEAR = 365 days; 

    struct Stake {
        address tokenId;
        uint256 amount;    
        uint256 startTime;  
        uint256 endTime;
        uint256 epochId;
        uint256 rewardShares;
    }

    struct Epoch {
        uint256 startTime;
        uint256 endTime;
        uint256 totalReward;
        uint256 totalRewardShares;
        uint256 rewardPerShare;
        bool finalized;
    }

    mapping(address => Stake[]) public userStakes;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public epochClaimed;

    // Events
    event Staked(address indexed user, uint256 amount, uint256 startTime, uint256 endTime, uint256 epochId);
    event Withdrawn(address indexed user, uint256 stakeIndex, uint256 amount, bool early, uint256 penalty);
    event RewardsDistributed(uint256 epochId, uint256 totalHBARDistributed, uint256 totalRewardTokenDistributed);
    event BoostUsed(address indexed user, uint256 stakeIndex, uint256 boostAmount, uint256 newRewardPercent);

    // Since we're on Hedera, we rely on contract having proper associations and keys.
    constructor(address _pyth, bytes32 _hbarUsdPriceId) {
        pyth = IPyth(_pyth);
        hbarUsdPriceId = _hbarUsdPriceId;
    }

    modifier onlyAfterEpochFinalized(uint256 _epochId) {
        require(epochs[_epochId].finalized, "Epoch not finalized");
        _;
    }

    function startNewEpoch(uint256 _endTime) external {
        require(_endTime > block.timestamp, "End time must be future");
        if (epochId > 0) {
            require(epochs[epochId].finalized, "Previous epoch not finalized");
        }
        epochId += 1;
        epochs[epochId] = Epoch({
            startTime: block.timestamp,
            endTime: _endTime,
            totalReward: 0,
            totalRewardShares: 0,
            rewardPerShare: 0,
            finalized: false
        });
    }

    /**
     * @notice Stake tokens into the current epoch.
     * @param amount Amount of tokens to stake (must be pre-approved to contract)
     * @param boostTokenAmount Amount of reward tokens to burn for a reward boost
     */
    function stake(address tokenId, uint256 amount,uint256 duration, uint256 boostTokenAmount,bytes[] calldata priceUpdate) external payable {
        require(epochId > 0, "No active epoch");
        Epoch storage ep = epochs[epochId];
        require(block.timestamp < ep.endTime, "Epoch ended");
        require(amount > 0, "Stake amount must be > 0");
        require(duration >= ONE_MONTH && duration <= ONE_YEAR, "Wrong stake duration");

        if (tokenId == address(0)) {
            require(msg.value == amount, "Incorrect HBAR amount sent");
        } else {
        int responseCode = HederaTokenService.transferToken(tokenId, msg.sender, address(this), int64(int256(amount)));
            require(responseCode == HederaResponseCodes.SUCCESS, "Token transfer to exchange failed");
        }
        
        uint256 boostMultiplier = 0;
        if (boostTokenAmount > 0) {
            boostMultiplier = calculateBoost(boostTokenAmount); 
        }
        uint fee = pyth.getUpdateFee(priceUpdate);
        pyth.updatePriceFeeds{ value: fee }(priceUpdate);
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(
            hbarUsdPriceId,
            60
        );
        uint256 rewardShares = uint256(uint64(price.price))*amount/100000000 * duration/1000000 * boostMultiplier;



        userStakes[msg.sender].push(
            Stake({
                tokenId: tokenId,
                amount: amount,
                startTime: block.timestamp,
                endTime:  block.timestamp+duration,
                epochId: epochId,
                rewardShares: rewardShares
            })
        );

        totalStaked[tokenId] += amount;
        ep.totalRewardShares += rewardShares;

        emit Staked(msg.sender, amount, block.timestamp, ep.endTime, epochId);
    }


    function calculateBoost(uint256 boostTokenAmount) internal pure returns (uint256 boost) {
        if (boostTokenAmount < 1) {
            return 0;
        }

        uint256 lnValue = Math.log2(boostTokenAmount + 1) * 1000; 

        uint256 scalingFactor = 361; 

        boost = (lnValue * scalingFactor) / 1000;

        if (boost > 2500) {
            boost = 2500;
        }

        return boost;
    }

    
    /**
     * @notice Withdraw staked tokens. If early, a penalty applies.
     */
    function withdraw(uint256 stakeIndex) external {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid index");
        Stake memory s = userStakes[msg.sender][stakeIndex];
        require(s.amount > 0, "Already withdrawn");
        userStakes[msg.sender][stakeIndex].amount = 0; 
        uint256 withdrawAmount = s.amount;
        bool early = block.timestamp < s.endTime;
        uint256 penalty = 0;
        if (early) {
            penalty = (withdrawAmount * penaltyRate) / 100;
            withdrawAmount -= penalty;
            epochs[epochId].totalReward += penalty;
        }

       
        totalStaked[s.tokenId] -= (withdrawAmount + penalty);


        // Transfer back user’s tokens (withdrawAmount)
        if (withdrawAmount > 0) {
            (bool success, ) = msg.sender.call{value: withdrawAmount}("");
            require(success, "Failed to send HBAR to existing requester");
        }

        emit Withdrawn(msg.sender, stakeIndex, withdrawAmount, early, penalty);
    }

    function safeCastToInt64(uint256 value) internal pure returns (int64) {
        require(value <= uint256(int256((type(int64).max))), "Value exceeds int64 max value");
        return int64(uint64(value));
    }

    /**
     * @notice Finalize the epoch: locks in rewards, users can claim after this.
     * This just marks epoch as finalized. Actual distribution on claim.
     */
    function finalizeEpoch(uint256 _epochId, uint256 totalReward) external {
        Epoch storage ep = epochs[_epochId];
        require(!ep.finalized, "Already finalized");
        require(block.timestamp > ep.endTime, "Epoch not ended");
        ep.finalized = true;
        ep.totalReward = totalReward;
        if (ep.totalRewardShares > 0) {
            ep.rewardPerShare = totalReward * 1e18 / ep.totalRewardShares; // scale by 1e18 for precision
        }

    }
    
    /**
     * @notice Associate this contract with a token.
     */
    function tokenAssociate(address tokenId) external {
       int response = associateToken(address(this), tokenId);
       require(response == HederaResponseCodes.SUCCESS, "Associate Failed");
    }

    /**
     * @notice Receive fallback to accept HBAR
     */
    receive() external payable {}

    fallback() external payable {}
}

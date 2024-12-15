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
    mapping(address => uint256) public totalStaked;
    uint256 public penaltyRate = 10;
    uint256 public epochId = 0;
    IPyth pyth;
    bytes32 hbarUsdPriceId;
    uint constant ONE_MONTH = 5 minutes;
    uint constant ONE_YEAR = 60 minutes;

    struct Stake {
        address tokenId;
        uint256 amount;    
        uint256 startTime;  
        uint256 endTime;
        uint256 rewardShares;
        uint256 nextToClaim;
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
    mapping(uint256 => mapping(address => mapping( uint256 => bool))) public epochClaimed;

    // Existing Events
    event Staked(address indexed user, uint256 amount, uint256 startTime, uint256 endTime, uint256 epochId);
    event Withdrawn(address indexed user, uint256 stakeIndex, uint256 amount, bool early, uint256 penalty);
    event RewardsDistributed(uint256 epochId, uint256 totalHBARDistributed, uint256 totalRewardTokenDistributed);
    event BoostUsed(address indexed user, uint256 stakeIndex, uint256 boostAmount, uint256 newRewardPercent);

    // New Events
    event EpochStarted(uint256 indexed epochId, uint256 startTime, uint256 endTime);
    event EpochFinalized(uint256 indexed epochId, uint256 totalReward, uint256 totalRewardShares, uint256 rewardPerShare);
    event TokenAssociated(address tokenId);

    // Since we're on Hedera, we rely on contract having proper associations and keys.
    constructor(address _pyth, bytes32 _hbarUsdPriceId) {
        pyth = IPyth(_pyth);
        hbarUsdPriceId = _hbarUsdPriceId;
        startNewEpoch();
    }

    modifier onlyAfterEpochFinalized(uint256 _epochId) {
        require(epochs[_epochId].finalized, "Epoch not finalized");
        _;
    }

    function startNewEpoch() private {
        if (epochId > 0) {
            require(epochs[epochId].finalized, "Previous epoch not finalized");
        }
        uint256 _endTime = block.timestamp + 1 hours;
        epochId += 1;
        epochs[epochId] = Epoch({
            startTime: block.timestamp,
            endTime: _endTime,
            totalReward: 0,
            totalRewardShares: 0,
            rewardPerShare: 0,
            finalized: false
        });

        emit EpochStarted(epochId, block.timestamp, _endTime);
    }

    /**
     * @notice Finalize the epoch: locks in rewards, users can claim after this.
     * This just marks epoch as finalized. Actual distribution on claim.
     */
    function finalizeEpoch() private  {
        Epoch memory ep = epochs[epochId];
        require(!ep.finalized, "Already finalized");
        require(block.timestamp > ep.endTime, "Epoch not ended");
        epochs[epochId].finalized = true;
        if (ep.totalRewardShares > 0) {
            epochs[epochId].rewardPerShare = (ep.totalReward * 1e18) / ep.totalRewardShares; // scale by 1e18 for precision
        }

        emit EpochFinalized(epochId, ep.totalReward, ep.totalRewardShares, ep.rewardPerShare);
    }

    /**
     * @notice Stake tokens into the current epoch.
     * @param amount Amount of tokens to stake (must be pre-approved to contract)
     * @param boostTokenAmount Amount of reward tokens to burn for a reward boost
     */
    function stake(address tokenId, uint256 amount,uint256 duration, uint256 boostTokenAmount,bytes[] calldata priceUpdate) external payable {
        Epoch memory ep = epochs[epochId];
        if(block.timestamp > ep.endTime){
            finalizeEpoch();
            startNewEpoch();
        }
        require(amount > 0, "Stake amount must be > 0");
        require(duration >= 5 minutes && duration <= 30 minutes, "Wrong stake duration");

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
        uint256 rewardShares = (uint256(uint64(price.price)) * amount / 100000000) * (duration / 1000000) * boostMultiplier;

        userStakes[msg.sender].push(
            Stake({
                tokenId: tokenId,
                amount: amount,
                startTime: block.timestamp,
                endTime: block.timestamp + duration,
                nextToClaim: epochId,
                rewardShares: rewardShares
            })
        );

        totalStaked[tokenId] += amount;
        epochs[epochId].totalRewardShares += rewardShares;

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
        Stake[] memory s = userStakes[msg.sender];
        require(stakeIndex < s.length, "Invalid index");
        require(s[stakeIndex].amount > 0, "Already withdrawn");
        Epoch memory ep = epochs[epochId];
        if(block.timestamp > ep.endTime){
            finalizeEpoch();
            startNewEpoch();
        }
        userStakes[msg.sender][stakeIndex].amount = 0; 
        uint256 withdrawAmount = s[stakeIndex].amount;
        bool early = block.timestamp < s[stakeIndex].endTime;
        uint256 penalty = 0;
        if (early) {
            penalty = (withdrawAmount * penaltyRate) / 100;
            withdrawAmount -= penalty;
            epochs[epochId].totalReward += penalty;
        }

        totalStaked[s[stakeIndex].tokenId] -= (withdrawAmount + penalty);

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
     * @notice Associate this contract with a token.
     */
    function tokenAssociate(address tokenId) external {
        int response = associateToken(address(this), tokenId);
        require(response == HederaResponseCodes.SUCCESS, "Associate Failed");
        emit TokenAssociated(tokenId);
    }

    
    function claimReward() external {
        Stake[] memory s = userStakes[msg.sender];
        require(s.length > 0, "No active stakes");
        Epoch memory ep = epochs[epochId];
        if(block.timestamp > ep.endTime){
            finalizeEpoch();
            startNewEpoch();
        }
        uint256 totalReward = 0;
        for (uint256 i = 0; i < s.length; i++) {
             for (uint256 e = s[i].nextToClaim; e < epochId ; e++) {
                Epoch memory cE = epochs[e]; // Directly access epochs[e]
                if(cE.finalized && cE.rewardPerShare != 0){
                        totalReward += (cE.rewardPerShare * s[i].rewardShares) / 1e18;
                }
             }
            userStakes[msg.sender][i].nextToClaim = epochId;
        }
        
        require(totalReward > 0, "No reward to claim");

        require(address(this).balance >= totalReward, "Insufficient contract balance");
        (bool success, ) = msg.sender.call{value: totalReward}("");
        require(success, "HBAR transfer failed");
    }


    /**
     * @notice Receive fallback to accept HBAR
     */
    receive() external payable {}

    fallback() external payable {}
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;



import "./hedera/HederaResponseCodes.sol";
import "./hedera/HederaTokenService.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IQuoter {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

interface IRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function unwrapWHBAR(uint256 amountMinimum, address recipient) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title HashHold
 * @dev Time-locked staking contract on Hedera. 
 */
contract HashHold is HederaTokenService, ReentrancyGuard, Ownable {

    // ====================================================
    // Configurable Parameters
    // ====================================================
    uint256 public minStakeDuration;
    uint256 public maxStakeDuration;
    uint256 public epochDuration; // Duration of each epoch

    address public usdcTokenAddress;
    address public whbarTokenAddress;

    // Mapping of token pair fees for swap paths
    mapping(address => mapping(address => uint24)) public poolFees;

    // ====================================================
    // State Variables
    // ====================================================
    mapping(address => uint256) public totalStakedAmount;
    mapping(address => Stake[]) public userStakes;
    mapping(uint256 => Epoch) public epochs;

    uint256 public penaltyRate = 10; // Penalty rate percentage (0 - 100)
    uint256 public epochId = 0;      // Current epoch identifier

    // External contract references
    IQuoter public saucerSwapQuoter;
    IRouter public saucerSwapRouter;
    IPyth public pyth;

    address public saucerSwapRouterAddress;
    bytes32 public hbarUsdPriceId;

    // ====================================================
    // Structs
    // ====================================================
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

    // ====================================================
    // Events
    // ====================================================
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        uint256 stakeIndex,
        address tokenId
    );
    event Withdrawn(
        address indexed user,
        uint256 stakeIndex,
        uint256 amount,
        bool early,
        uint256 penalty
    );
    event BoostUsed(
        address indexed user,
        uint256 stakeIndex,
        uint256 boostAmount,
        uint256 newRewardPercent
    );
    event EpochStarted(
        uint256 indexed epochId,
        uint256 startTime,
        uint256 endTime
    );
    event EpochFinalized(
        uint256 indexed epochId,
        uint256 totalReward,
        uint256 totalRewardShares,
        uint256 rewardPerShare
    );
    event RewardClaimed(
        address indexed user,
        uint256 totalReward
    );
    event TokenAssociated(address tokenId);

    // ====================================================
    // Constructor
    // ====================================================
    constructor(
        address _pyth,
        address _saucerSwapQuoterAddress,
        address _saucerSwapRouterAddress,
        address _usdcTokenAddress,
        address _whbarTokenAddress,
        bytes32 _hbarUsdPriceId,
        uint256 _minStakeDuration,
        uint256 _maxStakeDuration,
        uint256 _epochDuration
    ) Ownable(msg.sender) {
        pyth = IPyth(_pyth);
        saucerSwapQuoter = IQuoter(_saucerSwapQuoterAddress);
        saucerSwapRouter = IRouter(_saucerSwapRouterAddress);
        saucerSwapRouterAddress = _saucerSwapRouterAddress;
        usdcTokenAddress = _usdcTokenAddress;
        whbarTokenAddress = _whbarTokenAddress;
        hbarUsdPriceId = _hbarUsdPriceId;
        minStakeDuration = _minStakeDuration;
        maxStakeDuration = _maxStakeDuration;
        epochDuration = _epochDuration;
        _startNewEpoch();
    }

    // ====================================================
    // Modifiers
    // ====================================================
    modifier onlyAfterEpochFinalized(uint256 _epochId) {
        require(epochs[_epochId].finalized, "Epoch not finalized");
        _;
    }

    modifier checkAndFinalizeEpoch() {
        Epoch storage currentEpoch = epochs[epochId];
        if (block.timestamp > currentEpoch.endTime && !currentEpoch.finalized) {
            _finalizeEpoch();
            _startNewEpoch();
        }
        _;
    }

    // ====================================================
    // Owner-Only Setters
    // ====================================================
    function setPenaltyRate(uint256 _penaltyRate) external onlyOwner {
        require(_penaltyRate <= 100, "Penalty rate exceeds 100%");
        penaltyRate = _penaltyRate;
    }

    function setPyth(address _pyth) external onlyOwner {
        require(_pyth != address(0), "Invalid address");
        pyth = IPyth(_pyth);
    }

    function setUsdcTokenAddress(address _usdcTokenAddress) external onlyOwner {
        require(_usdcTokenAddress != address(0), "Invalid address");
        usdcTokenAddress = _usdcTokenAddress;
    }
    
    function setWhbarTokenAddress(address _whbarTokenAddress) external onlyOwner {
        require(_whbarTokenAddress != address(0), "Invalid address");
        whbarTokenAddress = _whbarTokenAddress;
    }

    function setPoolFees(address token1, address token2, uint24 newFee) external onlyOwner {
        require(newFee != 0, "Fee cannot be 0");
        poolFees[token1][token2] = newFee;
    }

    function setsaucerSwapQuoter(address _saucerSwapQuoter) external onlyOwner {
        require(_saucerSwapQuoter != address(0), "Invalid address");
        saucerSwapQuoter = IQuoter(_saucerSwapQuoter);
    }

    function setsaucerSwapRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid address");
        saucerSwapRouter = IRouter(_router);
        saucerSwapRouterAddress = _router;
    }

    function setHbarUsdPriceId(bytes32 _priceId) external onlyOwner {
        hbarUsdPriceId = _priceId;
    }

    function setEpochDuration(uint256 _epochDuration) external onlyOwner {
        require(_epochDuration > 0, "Epoch duration must be > 0");
        epochDuration = _epochDuration;
    }

    function setStakeDurationBounds(uint256 _min, uint256 _max) external onlyOwner {
        require(_min < _max, "Minimum duration must be less than maximum");
        minStakeDuration = _min;
        maxStakeDuration = _max;
    }

    // ====================================================
    // Epoch Management
    // ====================================================
    function _startNewEpoch() private {
        uint256 previousRewardShares = 0;
        if (epochId > 0) {
            require(epochs[epochId].finalized, "Previous epoch not finalized");
            previousRewardShares = epochs[epochId].totalRewardShares;
        }

        uint256 newEpochEndTime = block.timestamp + epochDuration;
        epochId += 1;

        epochs[epochId] = Epoch({
            startTime: block.timestamp,
            endTime: newEpochEndTime,
            totalReward: 0,
            totalRewardShares: previousRewardShares,
            rewardPerShare: 0,
            finalized: false
        });

        emit EpochStarted(epochId, block.timestamp, newEpochEndTime);
    }

    function _finalizeEpoch() private {
        Epoch storage currentEpoch = epochs[epochId];
        require(!currentEpoch.finalized, "Already finalized");
        require(block.timestamp > currentEpoch.endTime, "Epoch not ended");

        currentEpoch.finalized = true;

        if (currentEpoch.totalRewardShares > 0) {
            // Scale reward per share for precision (using 1e8)
            currentEpoch.rewardPerShare = (currentEpoch.totalReward * 1e8) / currentEpoch.totalRewardShares;
        }

        emit EpochFinalized(
            epochId,
            currentEpoch.totalReward,
            currentEpoch.totalRewardShares,
            currentEpoch.rewardPerShare
        );
    }

    // ====================================================
    // Staking Functions
    // ====================================================
    function encodeSwapPath(
        address tokenIn,
        uint24 fee,
        address tokenOut
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, fee, tokenOut);
    }

    function stake(
        address tokenId,
        uint256 amount,
        uint256 duration,
        uint256 boostTokenAmount,
        bytes[] calldata priceUpdate
    ) external payable nonReentrant checkAndFinalizeEpoch {
        require(amount > 0, "Stake amount must be > 0");
        require(
            duration >= minStakeDuration && duration <= maxStakeDuration,
            "Stake duration out of range"
        );
        require(userStakes[msg.sender].length < 10, "Maximum number of active stakes reached");
        
        uint256 tokenValue;
        uint256 stakedAmount = amount;

        if (tokenId == address(0)) {
            // HBAR staking
            require(msg.value == amount, "Incorrect HBAR amount sent");
            uint256 fee = pyth.getUpdateFee(priceUpdate);
            stakedAmount -= fee;
            pyth.updatePriceFeeds{value: fee}(priceUpdate);

            PythStructs.Price memory price = pyth.getPriceNoOlderThan(hbarUsdPriceId, 60);
            uint256 scaledPrice = uint256(int256(price.price)) / 10 ** uint256(uint32(-price.expo));
            tokenValue = (scaledPrice * stakedAmount) / 100000000;
            require(tokenValue >= 100, "Token value under 1 USD");
        } else {
            // HTS token staking
            bytes memory swapPath = encodeSwapPath(
                tokenId,
                poolFees[tokenId][usdcTokenAddress],
                usdcTokenAddress
            );
            (
                uint256 amountOut,
                ,
                ,
                
            ) = saucerSwapQuoter.quoteExactInput(swapPath, amount);

            tokenValue = amountOut / 10000;
            require(tokenValue >= 100, "Token value under 1 USD");

            int256 responseCode = HederaTokenService.transferToken(
                tokenId,
                msg.sender,
                address(this),
                int64(int256(amount))
            );
            require(responseCode == HederaResponseCodes.SUCCESS, "Token transfer failed");
        }

        uint256 rewardShares = tokenValue * duration;
        if (boostTokenAmount > 0) {
            rewardShares = _calculateBoostedShares(rewardShares, boostTokenAmount);
        }

        userStakes[msg.sender].push(
            Stake({
                tokenId: tokenId,
                amount: stakedAmount,
                startTime: block.timestamp,
                endTime: block.timestamp + duration,
                rewardShares: rewardShares,
                nextToClaim: epochId
            })
        );

        totalStakedAmount[tokenId] += amount;
        epochs[epochId].totalRewardShares += rewardShares;

        emit Staked(
            msg.sender,
            stakedAmount,
            block.timestamp,
            block.timestamp + duration,
            userStakes[msg.sender].length - 1,
            tokenId
        );
    }

    function _calculateBoostedShares(
        uint256 rewardShares,
        uint256 boostTokenAmount
    ) internal pure returns (uint256) {
        if (boostTokenAmount < 100000000) {
            return rewardShares;
        }
        uint256 boost = Math.log2(boostTokenAmount/1e8);
        if (boost > 25) {
            boost = 25;
        }
        return (rewardShares * (100 + boost)) / 100;
    }

    // ====================================================
    // Withdraw Function
    // ====================================================
    function withdraw(uint256 stakeIndex) external nonReentrant checkAndFinalizeEpoch {
        uint256 stakeCount = userStakes[msg.sender].length;
        require(stakeIndex < stakeCount, "Invalid index");

        Stake storage userStake = userStakes[msg.sender][stakeIndex];
        require(userStake.amount > 0, "Already withdrawn");

        uint256 withdrawAmount = userStake.amount;
        bool isEarlyWithdrawal = block.timestamp < userStake.endTime;
        uint256 penalty = 0;
        uint256 penaltyInHbar = 0;

        if (isEarlyWithdrawal) {
            penalty = (withdrawAmount * penaltyRate) / 100;
            withdrawAmount -= penalty;
        }

        totalStakedAmount[userStake.tokenId] -= (withdrawAmount + penalty);

        if (userStake.tokenId == address(0)) {
            penaltyInHbar = penalty;
            require(address(this).balance >= withdrawAmount, "Insufficient contract balance");
            (bool success, ) = msg.sender.call{value: withdrawAmount}("");
            require(success, "Failed to send HBAR");
        } else {
            int256 responseCode = HederaTokenService.transferToken(
                userStake.tokenId,
                address(this),
                msg.sender,
                safeCastToInt64(withdrawAmount)
            );
            require(responseCode == HederaResponseCodes.SUCCESS, "Token transfer back failed");

            if (isEarlyWithdrawal) {
                responseCode = HederaTokenService.approve(
                    userStake.tokenId,
                    saucerSwapRouterAddress,
                    penalty
                );
                require(responseCode == HederaResponseCodes.SUCCESS, "Failed to approve tokens for router");

                bytes memory swapPath = encodeSwapPath(
                    userStake.tokenId,
                    poolFees[userStake.tokenId][whbarTokenAddress],
                    whbarTokenAddress
                );

                (
                    uint256 amountOut,
                    ,
                    ,
                    
                ) = saucerSwapQuoter.quoteExactInput(swapPath, penalty);
                IRouter.ExactInputParams memory params = IRouter.ExactInputParams({
                    path: swapPath,
                    recipient: saucerSwapRouterAddress,
                    deadline: block.timestamp + 30,
                    amountIn: penalty,
                    amountOutMinimum: amountOut
                });

                bytes memory swapCall = abi.encodeWithSelector(
                    IRouter.exactInput.selector,
                    params
                );

                bytes memory unwrapCall = abi.encodeWithSelector(
                    IRouter.unwrapWHBAR.selector,
                    amountOut,
                    address(this)
                );

                bytes[] memory calls = new bytes[](2);
                calls[0] = swapCall;
                calls[1] = unwrapCall;

                bytes[] memory results = IRouter(saucerSwapRouter).multicall(calls);
                (uint256 swapAmountOut) = abi.decode(results[0], (uint256));

                penaltyInHbar = swapAmountOut;
            }
        }

        if (isEarlyWithdrawal) {
            epochs[epochId].totalReward += penaltyInHbar;
        }

        emit Withdrawn(
            msg.sender,
            stakeIndex,
            withdrawAmount,
            isEarlyWithdrawal,
            penaltyInHbar
        );

        if (stakeCount > 1 && stakeIndex != stakeCount - 1) {
            for (uint256 j = stakeIndex; j < stakeCount - 1; j++) {
                userStakes[msg.sender][j] = userStakes[msg.sender][j + 1];
            }
        }
        userStakes[msg.sender].pop(); 
    }

    // ====================================================
    // Reward Claiming
    // ====================================================
    function claimReward() external nonReentrant checkAndFinalizeEpoch {
        uint256 totalReward = 0;
        uint256 stakeCount = userStakes[msg.sender].length;

        require(stakeCount > 0, "No active stakes");

        for (uint256 i = 0; i < stakeCount; i++) {
            Stake storage stakeRef = userStakes[msg.sender][i];  
            uint256 rewardShares = stakeRef.rewardShares;  
            uint256 nextEpoch = stakeRef.nextToClaim; 
     
            for (uint256 e = nextEpoch; e < epochId; e++) {
                Epoch storage closedEpoch = epochs[e];  

                if (closedEpoch.finalized && closedEpoch.rewardPerShare != 0) {
                    totalReward += (closedEpoch.rewardPerShare * rewardShares) / 1e8;
                }
            }
            stakeRef.nextToClaim = epochId;  
         
        }

        require(address(this).balance >= totalReward, "Insufficient contract balance");

        (bool success, ) = msg.sender.call{value: totalReward}("");
        require(success, "HBAR transfer failed");

        emit RewardClaimed(msg.sender, totalReward);
    }


    // ====================================================
    // Utility Functions
    // ====================================================
    function safeCastToInt64(uint256 value) internal pure returns (int64) {
        require(value <= uint256(int256(type(int64).max)), "Value exceeds int64 max");
        return int64(uint64(value));
    }

    function tokenAssociate(address tokenId) external onlyOwner {
        int256 response = associateToken(address(this), tokenId);
        require(response == HederaResponseCodes.SUCCESS, "Associate Failed");
        emit TokenAssociated(tokenId);
    }

    // ====================================================
    // Receive & Fallback
    // ====================================================
    receive() external payable {}
    fallback() external payable {}
}

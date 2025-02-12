// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/*
 *  Hedera Time-Locked Staking Contract Example
 *  -------------------------------------------
 *  Demonstration contract for educational purposes. Not audited or production-ready.
 */

import "./hedera/HederaResponseCodes.sol";
import "./hedera/HederaTokenService.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}



interface ISaucerSwapV2Router {
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
 * @dev Time-locked staking contract on Hedera. Demonstration only, not for production use.
 */
contract hashhold is HederaTokenService, ReentrancyGuard {
    // ====================================================
    // Ownership
    // ====================================================
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not contract owner");
        _;
    }

    // ====================================================
    // Configurable Constants
    // ====================================================
    // These were fixed in your original code. Now we expose them for configuration.
    uint256 public minStakeDuration = 5 seconds;
    uint256 public maxStakeDuration = 30 minutes;

    // Instead of hardcoding 1 hour for each epoch, let's make it configurable.
    uint256 public epochDuration = 5 seconds;

    // ====================================================
    // State Variables
    // ====================================================
    mapping(address => uint256) public totalStaked;
    mapping(address => Stake[]) public userStakes;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public epochClaimed;

    // Current penalty rate in percentage (0 - 100)
    uint256 public penaltyRate = 10;

    // Current epoch ID
    uint256 public epochId = 0;

    // External contract references
    IQuoterV2 public quoterV2;
    ISaucerSwapV2Router public saucerSwapV2Router;
    IPyth public pyth;

    // Router address used for token approvals
    address public saucerSwapV2RouterAddress;

    // Pyth price feed info
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
        uint256 stakeIndex
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
        address quoterV2Address,
        address _saucerSwapV2RouterAddress,
        bytes32 _hbarUsdPriceId
    ) {
        pyth = IPyth(_pyth);
        quoterV2 = IQuoterV2(quoterV2Address);
        saucerSwapV2Router = ISaucerSwapV2Router(_saucerSwapV2RouterAddress);
        saucerSwapV2RouterAddress = _saucerSwapV2RouterAddress;
        hbarUsdPriceId = _hbarUsdPriceId;

        owner = msg.sender; // Set owner

        _startNewEpoch();
    }

    // ====================================================
    // Modifiers
    // ====================================================
    /**
     * @dev Ensures an epoch is finalized before interacting.
     */
    modifier onlyAfterEpochFinalized(uint256 _epochId) {
        require(epochs[_epochId].finalized, "Epoch not finalized");
        _;
    }

    /**
     * @dev Checks if the current epoch should be finalized and starts a new epoch if needed.
     */
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
    /**
     * @notice Update the penalty rate (0 - 100).
     */
    function setPenaltyRate(uint256 _penaltyRate) external onlyOwner {
        require(_penaltyRate <= 100, "Penalty rate exceeds 100%");
        penaltyRate = _penaltyRate;
    }

    /**
     * @notice Update the Pyth price feed contract.
     */
    function setPyth(address _pyth) external onlyOwner {
        require(_pyth != address(0), "Invalid address");
        pyth = IPyth(_pyth);
    }

    /**
     * @notice Update the quoter contract address.
     */
    function setQuoterV2(address _quoterV2) external onlyOwner {
        require(_quoterV2 != address(0), "Invalid address");
        quoterV2 = IQuoterV2(_quoterV2);
    }

    /**
     * @notice Update the SaucerSwap V3 router address.
     */
    function setSaucerSwapV2Router(address _router) external onlyOwner {
        require(_router != address(0), "Invalid address");
        saucerSwapV2Router = ISaucerSwapV2Router(_router);
        saucerSwapV2RouterAddress = _router;
    }

    /**
     * @notice Update the Pyth HBAR/USD price feed ID.
     */
    function setHbarUsdPriceId(bytes32 _priceId) external onlyOwner {
        hbarUsdPriceId = _priceId;
    }

    /**
     * @notice Change the epoch duration (e.g., 1 hours → 2 hours).
     */
    function setEpochDuration(uint256 _epochDuration) external onlyOwner {
        require(_epochDuration > 0, "Epoch duration must be > 0");
        epochDuration = _epochDuration;
    }

    /**
     * @notice Update min/max stake durations.
     */
    function setStakeDurationBounds(uint256 _min, uint256 _max) external onlyOwner {
        require(_min < _max, "min must be < max");
        minStakeDuration = _min;
        maxStakeDuration = _max;
    }

    // ====================================================
    // Epoch Management
    // ====================================================

    /**
     * @dev Starts a new epoch. Requires the previous epoch to be finalized.
     */
    function _startNewEpoch() private {
        uint256 lastEpochRewardShares = 0;
        if (epochId > 0) {
            require(epochs[epochId].finalized, "Previous epoch not finalized");
            lastEpochRewardShares = epochs[epochId].totalRewardShares;
        }

        uint256 _endTime = block.timestamp + epochDuration;
        epochId += 1;

        epochs[epochId] = Epoch({
            startTime: block.timestamp,
            endTime: _endTime,
            totalReward: 0,
            totalRewardShares: lastEpochRewardShares,
            rewardPerShare: 0,
            finalized: false
        });

        emit EpochStarted(epochId, block.timestamp, _endTime);
    }

    /**
     * @dev Finalizes the current epoch; locks rewards and calculates rewardPerShare.
     */
    function _finalizeEpoch() private {
        Epoch storage ep = epochs[epochId];
        require(!ep.finalized, "Already finalized");
        require(block.timestamp > ep.endTime, "Epoch not ended");

        ep.finalized = true;

        if (ep.totalRewardShares > 0) {
            // Scale by 1e18 for precision
            ep.rewardPerShare = (ep.totalReward * 1e8) / ep.totalRewardShares;
        }

        emit EpochFinalized(
            epochId,
            ep.totalReward,
            ep.totalRewardShares,
            ep.rewardPerShare
        );
    }

    // ====================================================
    // Staking
    // ====================================================

    /**
     * @dev Builds a swap path for the quoter/router.
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param fee Pool fee
     */
    function buildPath(
        address tokenIn,
        uint24 fee,
        address tokenOut
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, fee, tokenOut);
    }

    /**
     * @notice Stake tokens or HBAR into the current epoch.
     * @param tokenId The token being staked (0x0 for HBAR).
     * @param amount Amount of tokens to stake.
     * @param duration Duration for which tokens are locked.
     * @param boostTokenAmount Additional tokens to burn for a reward boost.
     * @param priceUpdate Pyth price feed updates.
     */
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

        uint256 tokenValue;
        uint256 stackedAmount = amount;
        // Transfer tokens / HBAR to contract
        if (tokenId == address(0)) {
            // HBAR staking
            require(msg.value == amount, "Incorrect HBAR amount sent");
            uint256 fee = pyth.getUpdateFee(priceUpdate);
            stackedAmount -= fee;
            pyth.updatePriceFeeds{value: fee}(priceUpdate);

            PythStructs.Price memory price = pyth.getPriceNoOlderThan(
                hbarUsdPriceId,
                60
            );
            // Price is scaled by expo => scale to 'regular' decimals
            uint256 scaledPrice = uint256(int256(price.price)) /
                10 ** uint256(uint32(-price.expo));

            tokenValue = (scaledPrice * stackedAmount) / 100000000;
            require(tokenValue >= 100, "Token value under 1 USD");
        } else {
            // HTS token staking
            bytes memory path = buildPath(
                tokenId,
                3000,
                0x0000000000000000000000000000000000003aD2 // Example target token
            );
            (
                uint256 amountOut,
                ,
                ,
                
            ) = quoterV2.quoteExactInput(path, amount);

            tokenValue = amountOut / 10000;
            require(tokenValue >= 100, "Token value under 1 USD");

            int256 responseCode = HederaTokenService.transferToken(
                tokenId,
                msg.sender,
                address(this),
                int64(int256(amount))
            );
            require(
                responseCode == HederaResponseCodes.SUCCESS,
                "Token transfer failed"
            );
        }

        // Calculate reward shares
        uint256 baseRewardShares = tokenValue * duration;
        uint256 rewardShares = baseRewardShares;

        // If boost is applied
        if (boostTokenAmount > 0) {
            rewardShares = _calculateBoostedShares(
                rewardShares,
                boostTokenAmount
            );
        }

        userStakes[msg.sender].push(
            Stake({
                tokenId: tokenId,
                amount: stackedAmount,
                startTime: block.timestamp,
                endTime: block.timestamp + duration,
                rewardShares: rewardShares,
                nextToClaim: epochId
            })
        );

        totalStaked[tokenId] += amount;
        epochs[epochId].totalRewardShares += rewardShares;

        emit Staked(
            msg.sender,
            stackedAmount,
            block.timestamp,
            block.timestamp + duration,
            userStakes[msg.sender].length - 1
        );
    }

    /**
     * @dev Calculates reward shares with a logarithmic-based boost.
     */
    function _calculateBoostedShares(
        uint256 rewardShares,
        uint256 boostTokenAmount
    ) internal pure returns (uint256) {
        if (boostTokenAmount < 1) {
            return rewardShares;
        }

        // lnValue ~ log2(boostTokenAmount + 1) * 1000
        uint256 lnValue = Math.log2(boostTokenAmount + 1) * 1000;
        // scalingFactor ~ 361
        uint256 scalingFactor = 361;
        // boost ~ (lnValue * scalingFactor) / 100000
        uint256 boost = (lnValue * scalingFactor) / 100000;

        // Cap at 25% = 2500 basis points
        if (boost > 2500) {
            boost = 2500;
        }

        // final = rewardShares * (100 + boost) / 100
        return (rewardShares * (100 + boost)) / 100;
    }

    // ====================================================
    // Withdraw
    // ====================================================
    /**
     * @notice Withdraw staked tokens. If withdrawn early, a penalty applies.
     * @param stakeIndex Index of the user's stake to withdraw.
     */
    function withdraw(uint256 stakeIndex)
        external
        nonReentrant
        checkAndFinalizeEpoch
    {
        require(
            stakeIndex < userStakes[msg.sender].length,
            "Invalid index"
        );

        Stake storage userStake = userStakes[msg.sender][stakeIndex];
        require(userStake.amount > 0, "Already withdrawn");

        uint256 withdrawAmount = userStake.amount;
        bool early = (block.timestamp < userStake.endTime);
        uint256 penalty = 0;
        uint256 penaltyInHbar = 0;

        // Apply penalty if withdrawing early
        if (early) {
            penalty = (withdrawAmount * penaltyRate) / 100;
            withdrawAmount -= penalty;
        }

        // Effects
        userStake.amount = 0; // Prevent re-withdraw
        totalStaked[userStake.tokenId] -= (withdrawAmount + penalty);

        // Interactions
        if (userStake.tokenId == address(0)) {
            // HBAR
            penaltyInHbar = penalty;
            require(
                address(this).balance >= withdrawAmount,
                "Insufficient contract balance"
            );
            (bool success, ) = msg.sender.call{value: withdrawAmount}("");
            require(success, "Failed to send HBAR");

        } else {
            // HTS tokens
            int256 responseCode = HederaTokenService.transferToken(
                userStake.tokenId,
                address(this),
                msg.sender,
                safeCastToInt64(withdrawAmount)
            );
            require(
                responseCode == HederaResponseCodes.SUCCESS,
                "Token transfer back failed"
            );

            if (early) {
                // 1. Approve penalty tokens for router
                responseCode = HederaTokenService.approve(
                    userStake.tokenId,
                    saucerSwapV2RouterAddress,
                    penalty
                );
                require(
                    responseCode == HederaResponseCodes.SUCCESS,
                    "Failed to approve tokens for router"
                );

                // Build path
                bytes memory path = buildPath(
                    userStake.tokenId,
                    3000,
                    0x0000000000000000000000000000000000003aD2
                );

                (
                    uint256 amountOut,
                    ,
                    ,
                    
                ) = quoterV2.quoteExactInput(path, penalty);
                ISaucerSwapV2Router.ExactInputParams memory params = ISaucerSwapV2Router.ExactInputParams({
                    path: path,
                    recipient: saucerSwapV2RouterAddress,
                    deadline: block.timestamp + 30,
                    amountIn: penalty,
                    amountOutMinimum: amountOut
                });
                

                bytes memory swapCall = abi.encodeWithSelector(
                    ISaucerSwapV2Router.exactInput.selector,
                    params
                );

                // Step 3: Encode Unwrap Call
                bytes memory unwrapCall = abi.encodeWithSelector(
                    ISaucerSwapV2Router.unwrapWHBAR.selector,
                    amountOut,
                    address(this) // Send unwrapped HBAR to contract
                );

                // Step 4: Execute Both in a Single Multicall
                bytes[] memory calls = new bytes[](2);
                calls[0] = swapCall;
                calls[1] = unwrapCall;

                bytes[] memory results = ISaucerSwapV2Router(saucerSwapV2Router).multicall(calls);
                (uint256 swapAmountOut) = abi.decode(results[0], (uint256));
                
                penaltyInHbar = swapAmountOut;
            }
        }

        // Add penalty to current epoch reward
        if (early) {
            epochs[epochId].totalReward += penaltyInHbar;
        }

        emit Withdrawn(
            msg.sender,
            stakeIndex,
            withdrawAmount,
            early,
            penaltyInHbar
        );
    }

    // ====================================================
    // Claim Reward
    // ====================================================
    /**
     * @notice Claims all available rewards from finalized epochs.
     */
    function claimReward() external nonReentrant checkAndFinalizeEpoch {
        Stake[] storage stakes = userStakes[msg.sender];
        require(stakes.length > 0, "No active stakes");

        uint256 totalReward = 0;

        for (uint256 i = 0; i < stakes.length; i++) {
            Stake storage s = stakes[i];

            for (uint256 e = s.nextToClaim; e < epochId; e++) {
                Epoch storage closedEpoch = epochs[e];
                if (closedEpoch.finalized && closedEpoch.rewardPerShare != 0) {
                    totalReward += (closedEpoch.rewardPerShare * s.rewardShares) / 1e8;
                }
            }
            // Update nextToClaim to the current epoch
            s.nextToClaim = epochId;
        }

        require(
            address(this).balance >= totalReward,
            "Insufficient contract balance"
        );

        (bool success, ) = msg.sender.call{value: totalReward}("");
        require(success, "HBAR transfer failed");
        emit RewardClaimed(
            msg.sender,
            totalReward
        );
    }

    // ====================================================
    // Utility
    // ====================================================
    /**
     * @dev Safely cast a uint256 to int64, reverting if out of range.
     */
    function safeCastToInt64(uint256 value) internal pure returns (int64) {
        require(value <= uint256(int256(type(int64).max)), "Value exceeds int64 max");
        return int64(uint64(value));
    }

    /**
     * @notice Associates this contract with a given HTS token.
     * @param tokenId The token address to associate with.
     */
    function tokenAssociate(address tokenId) external {
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

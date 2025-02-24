# HashHold

**HashHold** is a time-locked staking contract built for the Hedera network. It allows users to stake HBAR or HTS tokens for a fixed duration, earn rewards over epochs, and withdraw their stake with an early withdrawal penalty if applicable. The contract uses external price feeds (from Pyth) and decentralized swap/quoting services (from SaucerSwap) to determine the USD value of staked tokens, ensuring that only stakes with a minimum value (e.g., above 1 USD) are accepted.

---

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Usage](#usage)
  - [Staking](#staking)
  - [Reward Calculation & Claiming](#reward-calculation--claiming)
  - [Early Withdrawal](#early-withdrawal)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Security](#security)
- [License](#license)

---

## Features

- **Wide Token Staking Compatibility:** Stake either native HBAR or a wide range of HTS tokens that are available on SaucerSwap.
- **Time-Locked Staking:** Lock tokens for a configurable duration, with reward shares depending on the duration specified when staking.
- **Epoch-Based Reward Distribution:** Rewards are calculated over epochs. Each epoch tracks total rewards, reward shares, and computes a reward per share.
- **Early Withdrawal Penalty:** Withdrawing before the end of the lock period incurs a penalty. The penalty is exchanged for HBAR (if needed) and added to epoch rewards.
- **Boost Mechanism (Not Available Yet):** Users may boost their reward shares by burning tokens that are distributed as an additional reward on each completed user staking.

---

## Architecture

The contract uses several external dependencies and interfaces:

- **HederaTokenService & HederaResponseCodes:**  
  For interacting with Hedera HTS tokens and handling token transfers.
  
- **Pyth Price Feed (IPyth):**  
  To obtain real-time HBAR pricing data in USD.
  
- **IQuoter & IRouter Interfaces:**  
  Used for decentralized swapping and quoting of token prices, enabling conversion of tokens.
  
- **OpenZeppelin Libraries:**  
  Provides mathematical utilities and reentrancy protection.

---

## Usage

### Staking

- **HBAR Staking:**  
  When staking HBAR, the user sends HBAR along with the transaction. The contract calls Pyth to fetch the current HBAR price (using a specified price feed ID) and verifies that the USD value of the staked HBAR exceeds a minimum threshold.

- **HTS Token Staking:**  
  For HTS tokens, the contract uses a swap path via the IQuoter to determine the token’s USDC equivalent value. The stake is accepted only if this value exceeds the minimum threshold.

### Reward Calculation & Claiming

- Rewards are accrued per epoch.
- Each stake is assigned reward shares based on its USD value and staking duration.
- At the end of an epoch, the rewards are finalized and a `rewardPerShare` is computed.
- Users can claim rewards via the `claimReward()` function (or indirectly via `withdraw()`, which calls the internal reward-claiming logic) to collect accumulated HBAR rewards.

### Early Withdrawal

- Withdrawing before the end of the staking period triggers a penalty (defined by `penaltyRate`).
- For token stakes, the penalty is converted to HBAR through a swap mechanism.
- The penalty is added to the current epoch’s reward pool, ensuring fair distribution to remaining stakers.

---

## Deployment

1. **Configure Parameters:**  
   During deployment, set the following:
   - Pyth price feed contract address.
   - IQuoter and IRouter contract addresses.
   - Token addresses for USDC and WHBAR.
   - The Pyth price feed ID for HBAR/USD.
   - Minimum and maximum stake durations.
   - Epoch duration (defines the length of each reward period).

2. **Deploy Using Remix or a Deployment Script:**  
   Compile and deploy the contract using Remix IDE (or another Solidity development tool).  

---

## Configuration

Owner-only functions allow the contract owner to update key parameters:

- **`setPenaltyRate`**: Adjusts the early withdrawal penalty percentage.
- **`setPyth`**: Updates the Pyth price feed contract address.
- **`setUsdcTokenAddress` / `setWhbarTokenAddress`**: Changes the token addresses.
- **`setPoolFees`**: Configures fees for token swap paths.
- **`setsaucerSwapQuoter` / `setsaucerSwapRouter`**: Updates external quoter and router addresses.
- **`setEpochDuration` & `setStakeDurationBounds`**: Dynamically adjust time parameters for epochs and staking.

---

## Security

- **ReentrancyGuard:**  
  The contract protects critical functions (`stake()`,`claimReward()`, `withdraw()`) against reentrancy.

- **Access Control:**  
  Only the contract owner can update sensitive parameters via Ownable functions.

- **Price Feed Verification:**  
  Staked tokens are only accepted if their USD value meets a minimum threshold.

- **Audits & Testing:**  
  This contract is provided for demonstration purposes and has not been formally audited. Extensive testing is needed before deploying in mainnet.

---

## License

This project is licensed under the [Business Source License (BSL) 1.1](https://mariadb.com/bsl11/).  
The source code is provided for review and analysis purposes. Commercial use requires explicit permission from the author.  
After a specified period, the project may transition to an open-source license.

---

## Contributing

Feel free to fork the repository, open issues, or submit pull requests. Contributions and improvements are welcome!  
However, any commercial use of this code is restricted under the license terms.

---

**Disclaimer:** *This smart contract is not audited for production use. Deploy and use at your own risk.*


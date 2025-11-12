# KipuBankV3

KipuBankV3 is a decentralized finance (DeFi) vault built on Ethereum. It expands on the original `KipuBankV2` by integrating with the Uniswap V2 protocol, allowing users to deposit any ERC20 token (or native ETH) and have it automatically converted and stored as USDC.

**This project fulfills the final exam requirements for the Web3 Developer course.**

### 🔗 Deployed Contract (Sepolia)

The `KipuBankV3` contract has been successfully deployed and verified on the Sepolia testnet.

- **Verified Contract on Etherscan:** https://sepolia.etherscan.io/address/0x4fdd84b1d8ff10adf919ddb1975728ca2355c9b9

---

## 🚀 High-Level Improvements (V2 vs V3)

This project represents a significant evolution from `KipuBankV2`. The primary goal was to move from a simple multi-asset bank to a true, composable DeFi protocol.

- **Uniswap V2 Integration:** `KipuBankV2` could only accept and store specific tokens (ETH and USDC) that the admin manually approved. `KipuBankV3` accepts **any ERC20 token** that has a liquidity pair with USDC on Uniswap V2.
- **Auto-Swapping & Consolidation:** When a user deposits a token (like WETH or DAI), the contract automatically swaps it to USDC using the Uniswap V2 Router. This means all internal balances are consolidated and tracked in a single, stable asset (USDC).
- **Chainlink Dependency Removed:** `KipuBankV2` relied on a Chainlink Price Feed to _estimate_ the USD value of ETH deposits. `KipuBankV3` gets the _actual, real-time conversion value_ directly from the Uniswap router's `getAmountsOut` function.

### Why these improvements?

1.  **Superior User Experience (UX):** Users can deposit whatever asset they hold (e.g., WETH, DAI) without needing to perform a separate swap themselves. The vault handles the conversion seamlessly.
2.  **Simplified Bank Management:** By consolidating all assets into USDC, the bank's total value (`s_totalUsdDeposited`) is simple to track and enforce against the `s_bankCapUsd`. This simplifies risk management significantly compared to managing a diverse portfolio of volatile assets.

---

## 🛠️ Setup and Deployment

This project is built with Foundry.

### Prerequisites

- Git
- Foundry
- An `.env` file (see below)

### 1. Local Setup & Installation

First, clone the repository and install the required dependencies. This project's dependencies (`lib/`) are manually cloned to resolve installation conflicts with `forge install`.

```bash
# Clone the main repository
git clone [https://github.com/MLjorgefab/KipuBank](https://github.com/MLjorgefab/KipuBank)
cd KipuBank

# Manually clone dependencies into the 'lib' folder
rm -rf lib
mkdir lib
cd lib
git clone [https://github.com/OpenZeppelin/openzeppelin-contracts.git](https://github.com/OpenZeppelin/openzeppelin-contracts.git)
git clone [https://github.com/smartcontractkit/chainlink.git](https://github.com/smartcontractkit/chainlink.git)
git clone [https://github.com/Uniswap/v2-periphery.git](https://github.com/Uniswap/v2-periphery.git)
cd ..
```

### 2\. Environment Configuration

Create a `.env` file in the root of the project and add your credentials.

```bash
# .env file
SEPOLIA_RPC_URL=YOUR_ALCHEMY_OR_INFURA_RPC_URL
PRIVATE_KEY=YOUR_WALLET_PRIVATE_KEY_NO_0x
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY
```

### 3\. Compile & Test

Load the environment variables and run `forge build`. Then, run the fork-tests against the Sepolia network.

```bash
# Load environment variables
source .env

# Compile
forge build

# Run tests (forking Sepolia)
forge test --fork-url $SEPOLIA_RPC_URL
```

You should see all 6 tests pass.

### 4\. Deploy

The `DeployKipuBankV3.s.sol` script handles deployment.

```bash
# Make sure .env is loaded
source .env

# Run the deployment script
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
--rpc-url $SEPOLIA_RPC_URL \
--private-key $PRIVATE_KEY \
--broadcast
```

### 5\. Verify on Etherscan

To verify the contract, you must first get the ABI-encoded constructor arguments.

**Step 5a: Get Constructor Arguments**

```bash
# cast abi-encode "constructor(address,address,uint256)" <router> <usdc> <cap>
cast abi-encode "constructor(address,address,uint256)" 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 1000000000000
```

This will output a single long string: `0x00000...`

**Step 5b: Run Verification**
(Replace `<YOUR_DEPLOYED_ADDRESS>` and `<YOUR_CONSTRUCTOR_ARGS>` with your values)

```bash
forge verify-contract <YOUR_DEPLOYED_ADDRESS> \
src/KipuBankV3.sol:KipuBankV3 \
--chain sepolia \
--etherscan-api-key $ETHERSCAN_API_KEY \
--constructor-args <YOUR_CONSTRUCTOR_ARGS>
```

---

## 🧠 Design Decisions & Trade-offs

- **USDC-Only Balances:**

  - **Decision:** All user balances are stored in a single `mapping(address => uint256) s_usdcBalances`.
  - **Pro:** Greatly simplifies tracking the total value of the bank and enforcing the `bankCap`.
  - **Trade-off:** Users cannot withdraw their original asset. If a user deposits WETH, they can only withdraw the USDC equivalent, not their WETH back.

- **Fixed Swap Path:**

  - **Decision:** The contract assumes a direct pair `[TokenIn -> USDC]` exists on Uniswap V2 (or `[WETH -> USDC]` for native ETH).
  - **Pro:** Simplifies the swap logic immensely and meets the assignment requirements.
  - **Trade-off:** This is a major limitation. The contract **cannot** handle "multi-hop" swaps. For example, if a user deposits a token `XYZ` that only has a `XYZ/WETH` pair, the deposit will fail because a direct `XYZ/USDC` pair does not exist. A production-grade protocol would need a more complex router.

- **Bank Cap Safety Check:**

  - **Decision:** The `bankCap` is checked _before_ the swap is executed, using the `minOut` (minimum expected USDC) from `getAmountsOut`.
  - **Pro:** This is a critical safety feature. It prevents a deposit that _would_ succeed but, due to slippage, results in an amount of USDC that exceeds the bank's limit. It checks the "worst-case" scenario first.

- **Security:**

  - **Decision:** The contract uses OpenZeppelin's `ReentrancyGuard` on all functions that move funds or change state (`depositERC20`, `depositETH`, `withdrawUSDC`).
  - **Decision:** The contract uses the `approve(0)` / `approve(amount)` pattern when approving the Uniswap Router. This is a known pattern to mitigate potential "infinite approval" attack vectors from a previously-approved, malicious token.
  - **Decision:** The contract uses `SafeERC20` for `safeTransferFrom` and `safeTransfer`, but the standard `approve` as `safeApprove` is not publicly available.

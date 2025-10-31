# KipuBankV2

KipuBankV2 is an evolved smart contract, upgrading the original KipuBank into a multi-token (ETH & ERC20), secure, and production-ready decentralized bank.

This project demonstrates advanced Solidity concepts including role-based access control, secure interaction with external contracts (Oracles and Tokens), and precise management of assets with different decimal places.

## 🚀 Core Features & Design Decisions

This V2 implements critical improvements over the original, focusing on security, architecture, and scalability.

### 1. Role-Based Access Control (`AccessControl`)
Instead of a single `Ownable` address, the contract uses OpenZeppelin's `AccessControl`. This provides a clear separation of duties:
* **`DEFAULT_ADMIN_ROLE` (`0x00...00`):** This role is for governance. It is the only role that can grant or revoke other roles (e.g., assigning a new Token Manager).
* **`TOKEN_MANAGER_ROLE`:** A custom role responsible for the bank's asset listings. Only accounts with this role can call `addAllowedToken` or `removeAllowedToken`.

### 2. Multi-Token Support (ETH & ERC20)
The contract's accounting was upgraded from a single `mapping(address => uint256)` to a nested mapping:
`mapping(address => mapping(address => uint256)) private s_balances;`
* This allows the bank to track balances for unlimited assets per user.
* **Native ETH** is tracked using the zero address (`NATIVE_ETH_ADDRESS_ZERO`) as the token key.

### 3. USD-Based Bank Cap & Oracle Integration
The bank's total deposits are capped based on their **real-world USD value**, not the quantity of tokens.
* A Chainlink **ETH/USD Price Feed** (`i_priceFeed`) is provided in the constructor.
* This oracle is used to convert all ETH deposits and withdrawals into their USD equivalent.
* All ERC20 deposits (e.g., USDC, USDT) are *assumed* to be 6-decimal stablecoins, valued 1:1 with USD.

### 4. Security Patterns (Checks-Effects-Interactions)
Security is paramount. The contract strictly adheres to best practices to prevent common attacks:
* **Withdrawals (`withdrawETH`, `withdrawERC20`):** Use the **Checks-Effects-Interactions (C-E-I)** pattern. The internal balance (`s_balances`) is updated *before* the funds are sent (`.call` or `.transfer`). This makes all withdrawals fully reentrancy-proof.
* **Deposits (`depositERC20`):** Use the **Checks-Interaction-Effects (C-I-E)** pattern. The contract *pulls* the tokens using `transferFrom` (Interaction) *before* it updates the user's internal balance (Effect). This ensures the bank never credits an account for a failed transfer.

### 5. Custom Errors
The contract uses **custom errors** (e.g., `KipuBankV2__InsufficientBalance`) instead of `require()` strings. This significantly reduces gas costs on deployment and during runtime.

---

## 🧠 Key Design Challenge: Unified 6-Decimal Accounting

The most complex task for a multi-token bank is handling assets with different decimals.
* **ETH:** 18 decimals
* **Chainlink Price Feed (ETH/USD):** 8 decimals
* **USDC (Target Stablecoin):** 6 decimals

**Solution:** The contract standardizes all internal USD accounting to **6 decimals**, as requested by the project brief ("convertirlos a los decimales de USDC").

All internal state variables tracking value (`s_bankCapUsd`, `s_totalUsdDeposited`) are stored in this 6-decimal format.

* **For USDC (6 decimals):** The conversion is 1:1. Depositing `50_000000` ($50 USDC) adds `50000000` to `s_totalUsdDeposited`.
* **For ETH (18 decimals):** The function `getEthAmountInUsd` performs the complex conversion using the 8-decimal oracle price.



> **The Formula:**
> `UsdValue (6 decimals) = (EthAmount (18 decimals) * EthPrice (8 decimals)) / 10**20`

---

## 🛠️ How to Deploy & Interact

### 1. Deployment
1.  Deploy the `KipuBankV2.sol` contract.
2.  Pass the correct **ETH/USD Price Feed** address for your network into the constructor.
    * **Sepolia Testnet:** `0x694AA1769357215DE4FAC081bf1f309aDC325306`

### 2. Admin Setup (As Deployer)
*Your deployment address will have both `DEFAULT_ADMIN_ROLE` and `TOKEN_MANAGER_ROLE`.*

1.  **Set the Bank Cap:** Call `setBankCap(amount)`. (e.g., for $1,000,000, use `1000000000000`).
2.  **Allow a Token:** Call `addAllowedToken(tokenAddress)` with the address of a 6-decimal stablecoin.
    * **Sepolia USDC:** `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`

### 3. User Interaction
1.  **Deposit ETH:** Call `depositETH()` while sending ETH (e.g., `0.1 ETH`) in the transaction (msg.value).
2.  **Deposit ERC20:**
    * **Step A (In Token Contract):** Call `approve(KipuBankV2_Address, amount)` on the USDC contract to grant permission.
    * **Step B (In KipuBankV2 Contract):** Call `depositERC20(USDC_Address, amount)`.
3.  **Withdraw:** Call `withdrawETH(amount)` or `withdrawERC20(USDC_Address, amount)`.
4.  **Check Balance:** Call `getBalance(userAddress, tokenAddress)` at any time. Use `0x0...0` for the `tokenAddress` to check the ETH balance.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script, console} from "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

/**
 * @title DeployKipuBankV3
 * @notice A Foundry script to deploy the KipuBankV3 contract
 */
contract DeployKipuBankV3 is Script {
    // --- Network Configuration ---
    NetworkConfig public activeConfig;

    struct NetworkConfig {
        address router; // Uniswap V2 Router address
        address usdc; // USDC token address
        uint256 initialCap; // Initial bank cap ($1M)
    }

    // --- Script Constructor ---
    /**
     * @notice The constructor selects the network configuration
     * based on the chainId the script is run on.
     */
    constructor() {
        uint256 chainId = block.chainid;

        if (chainId == 11155111) {
            // Sepolia Testnet
            activeConfig = getSepoliaConfig();
        } else {
            revert("Unsupported chainId. Add config for this network.");
        }
    }

    /**
     * @notice Returns the configuration for the Sepolia network
     * @dev Replace these addresses if you are using a different network
     */
    function getSepoliaConfig() internal pure returns (NetworkConfig memory) {
        return NetworkConfig({
            // Uniswap V2 Router address on Sepolia
            router: 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3,
            // USDC address on Sepolia (6 decimals)
            usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
            // Initial Cap: $1,000,000 USDC (1M * 10**6)
            initialCap: 1_000_000e6
        });
    }

    // --- Script Entrypoint ---
    function run() external {
        // 1. Start the broadcast
        vm.startBroadcast();

        // 2. Deploy the contract!
        KipuBankV3 kipuBankV3 = new KipuBankV3(activeConfig.router, activeConfig.usdc, activeConfig.initialCap);

        // 3. Stop the broadcast
        vm.stopBroadcast();

        // 4. Log the deployed address to the console
        console.log("KipuBankV3 deployed to:", address(kipuBankV3));
    }
}

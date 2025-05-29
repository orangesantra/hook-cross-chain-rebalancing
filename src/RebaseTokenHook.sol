// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";

import {IRebaseToken} from "./interfaces/IRebaseToken.sol";
import {Pool} from "lib/ccip/contracts/src/v0.8/ccip/libraries/Pool.sol";

import {StateLibrary} from "lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

interface IRebaseTokenPool {
    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    ) external returns (Pool.LockOrBurnOutV1 memory);
}

/**
 * @title RebaseTokenHook
 * @author 0xorangesantra
 * @notice This hook automates cross-chain arbitrage and rebalancing for RebaseToken pools
 * @dev Integrates with Uniswap V4 and Chainlink CCIP for cross-chain operations
 */
contract RebaseTokenHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // -----------------------------------------------
    // State Variables
    // -----------------------------------------------

    // Cross-chain configuration
    struct CrossChainConfig {
        uint64 chainSelector;       // CCIP chain selector for destination chain
        address poolAddress;        // Address of the RebaseToken pool on destination chain
        address routerAddress;      // Address of the CCIP router on destination chain
        address rebaseTokenAddress; // Address of the RebaseToken on destination chain
        uint256 lastSyncTimestamp;  // Last time data was synced with this chain
        uint256 currentPrice;       // Current price of RebaseToken on this chain
        uint256 currentInterestRate; // Current global interest rate on this chain
    }

    // Pool imbalance tracking
    struct PoolBalance {
        uint256 token0Reserve;     // Current reserve of token0 (RebaseToken)
        uint256 token1Reserve;     // Current reserve of token1 (typically ETH/WETH)
        uint256 lastUpdateTime;    // Last time pool balance was updated
        uint256 imbalanceThreshold; // Threshold in basis points to trigger rebalancing
    }

    // Mapping from pool ID to its balance info
    mapping(PoolId => PoolBalance) public poolBalances;
    
    // Mapping from pool ID to cross-chain configs
    mapping(PoolId => CrossChainConfig[]) public crossChainConfigs;
    
    // Mapping for tracking arbitrage operations
    mapping(PoolId => uint256) public lastArbitrageTimestamp;
    
    // Counter for tracking operations
    mapping(PoolId => uint256) public beforeSwapCount;
    mapping(PoolId => uint256) public afterSwapCount;
    mapping(PoolId => uint256) public beforeAddLiquidityCount;
    mapping(PoolId => uint256) public beforeRemoveLiquidityCount;

    // Protocol addresses
    address public rebaseTokenAddress;
    address public rebaseTokenPoolAddress;
    
    // Configuration parameters
    uint256 public constant REBALANCE_COOLDOWN = 1 hours;
    uint256 public constant ARBITRAGE_THRESHOLD = 100; // 1% price difference (in basis points)
    uint256 public constant PRECISION_FACTOR = 10000;  // For basis point calculations

    // -----------------------------------------------
    // Events
    // -----------------------------------------------
    event CrossChainRebalanceInitiated(PoolId indexed poolId, uint64 destinationChainSelector, uint256 amount);
    event ArbitrageOpportunityDetected(PoolId indexed poolId, uint64 destinationChainSelector, uint256 priceDiff);
    event PoolImbalanceDetected(PoolId indexed poolId, uint256 imbalance);
    event CrossChainConfigAdded(PoolId indexed poolId, uint64 chainSelector, address poolAddress);

    // -----------------------------------------------
    // Constructor
    // -----------------------------------------------
    constructor(
        IPoolManager _poolManager,
        address _rebaseTokenAddress,
        address _rebaseTokenPoolAddress
    ) BaseHook(_poolManager) {
        rebaseTokenAddress = _rebaseTokenAddress;
        rebaseTokenPoolAddress = _rebaseTokenPoolAddress;
    }

    function getPoolManager() public view returns (IPoolManager) {
        return poolManager;
    }

    // -----------------------------------------------
    // Admin Functions
    // -----------------------------------------------

    /**
     * @notice Add a new cross-chain configuration for a pool
     * @param poolId The ID of the pool to configure
     * @param chainSelector CCIP chain selector for the destination chain
     * @param poolAddress Address of the RebaseToken pool on destination chain
     * @param routerAddress Address of the CCIP router on destination chain
     * @param rebaseTokenAddressu Address of the RebaseToken on destination chain
     * @param currentInterestRate Current global interest rate on destination chain
     */
    function addCrossChainConfig(
        PoolId poolId,
        uint64 chainSelector,
        address poolAddress,
        address routerAddress,
        address rebaseTokenAddressu,
        uint256 currentInterestRate
    ) external {
        CrossChainConfig memory config = CrossChainConfig({
            chainSelector: chainSelector,
            poolAddress: poolAddress,
            routerAddress: routerAddress,
            rebaseTokenAddress: rebaseTokenAddressu,
            lastSyncTimestamp: block.timestamp,
            currentPrice: 0, // Will be updated during first sync
            currentInterestRate: currentInterestRate
        });
        
        crossChainConfigs[poolId].push(config);
        
        emit CrossChainConfigAdded(poolId, chainSelector, poolAddress);
    }

    /**
     * @notice Set the imbalance threshold for a pool
     * @param poolId The ID of the pool to configure
     * @param threshold Threshold in basis points (e.g., 200 = 2%)
     */
    function setImbalanceThreshold(PoolId poolId, uint256 threshold) external {
        require(threshold > 0 && threshold <= 1000, "Threshold must be between 0 and 10%");
        poolBalances[poolId].imbalanceThreshold = threshold;
    }

    /**
     * @notice Update cross-chain price data manually (can also be automated via oracles)
     * @param poolId The ID of the pool
     * @param chainIndex Index of the chain in the crossChainConfigs array
     * @param price Current price on the destination chain
     * @param interestRate Current interest rate on the destination chain
     */
    function updateCrossChainData(
        PoolId poolId,
        uint256 chainIndex,
        uint256 price,
        uint256 interestRate
    ) external {
        require(chainIndex < crossChainConfigs[poolId].length, "Invalid chain index");
        
        crossChainConfigs[poolId][chainIndex].currentPrice = price;
        crossChainConfigs[poolId][chainIndex].currentInterestRate = interestRate;
        crossChainConfigs[poolId][chainIndex].lastSyncTimestamp = block.timestamp;
    }

    // -----------------------------------------------
    // Hook Permissions
    // -----------------------------------------------
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }    
    
    // -----------------------------------------------
    // Hook Implementation
    // -----------------------------------------------
    
    // function _afterSwap(
    //     address,
    //     PoolKey calldata key,
    //     SwapParams calldata,
    //     BalanceDelta delta,
    //     bytes calldata
    // ) internal override returns (bytes4, int128) {
    //     return (BaseHook.afterSwap.selector, 0);
    // }

    // function _afterAddLiquidity(
    //     address sender,
    //     PoolKey calldata key,
    //     ModifyLiquidityParams calldata params,
    //     BalanceDelta delta,
    //     BalanceDelta feesAccrued,
    //     bytes calldata hookData
    // ) internal override returns (bytes4, BalanceDelta) {
    //     return (BaseHook.afterAddLiquidity.selector, delta);
    // }

    /**
     * @notice Called before a swap to ensure RebaseToken interest is minted
     * @dev Ensures accurate pricing by updating balances before swap
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        beforeSwapCount[key.toId()]++;
          // Check if either token in the pool is a RebaseToken
        if (isRebaseToken(Currency.unwrap(key.currency0))) {
            // Mint accrued interest for the sender to ensure accurate swap pricing
            mintAccruedInterestIfNeeded(Currency.unwrap(key.currency0), params.zeroForOne ? address(this) : sender);
        }
        
        if (isRebaseToken(Currency.unwrap(key.currency1))) {
            // Mint accrued interest for the sender to ensure accurate swap pricing
            mintAccruedInterestIfNeeded(Currency.unwrap(key.currency1), params.zeroForOne ? sender : address(this));
        }
          return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Called after a swap to check for arbitrage opportunities and pool imbalances
     * @dev Analyzes pool state and initiates cross-chain actions if needed
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        afterSwapCount[key.toId()]++;
        
        PoolId poolId = key.toId();
        
        // Only perform checks for pools containing RebaseToken
        if (isRebaseTokenPool(key)) {
            // Update pool balance tracking
            updatePoolBalance(poolId, key);
            
            // Check for pool imbalance
            uint256 imbalance = calculatePoolImbalance(poolId);
            if (imbalance > poolBalances[poolId].imbalanceThreshold) {
                emit PoolImbalanceDetected(poolId, imbalance);
                
                // Only trigger rebalancing if enough time has passed since last arbitrage
                if (block.timestamp > lastArbitrageTimestamp[poolId] + REBALANCE_COOLDOWN) {
                    autoRebalanceAcrossChains(poolId, key, imbalance);
                }
            }
            
            // Check for cross-chain arbitrage opportunities
            checkCrossChainArbitrageOpportunities(poolId, key);
        }
          return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Called before adding liquidity to ensure RebaseToken interest is minted
     * @dev Ensures accurate valuation of added liquidity
     */    
     
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        beforeAddLiquidityCount[key.toId()]++;
        
        // Mint accrued interest for the sender to ensure accurate liquidity valuation
        if (isRebaseToken(Currency.unwrap(key.currency0))) {
            mintAccruedInterestIfNeeded(Currency.unwrap(key.currency0), sender);
        }
        
        if (isRebaseToken(Currency.unwrap(key.currency1))) {
            mintAccruedInterestIfNeeded(Currency.unwrap(key.currency1), sender);
        }
          return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @notice Called before removing liquidity to ensure RebaseToken interest is minted
     * @dev Ensures accurate valuation of removed liquidity
     */
     function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        beforeRemoveLiquidityCount[key.toId()]++;
        
        // Mint accrued interest for the sender to ensure accurate liquidity valuation
        if (isRebaseToken(Currency.unwrap(key.currency0))) {
            mintAccruedInterestIfNeeded(Currency.unwrap(key.currency0), sender);
        }
        
        if (isRebaseToken(Currency.unwrap(key.currency1))) {
            mintAccruedInterestIfNeeded(Currency.unwrap(key.currency1), sender);
        }
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // -----------------------------------------------
    // Helper Functions
    // -----------------------------------------------

    /**
     * @notice Check if a token is a RebaseToken
     * @param tokenAddress Address of the token to check
     * @return bool True if the token is a RebaseToken
     */
    function isRebaseToken(address tokenAddress) internal view returns (bool) {
        return tokenAddress == rebaseTokenAddress;
    }

    /**
     * @notice Check if a pool contains RebaseToken
     * @param key The pool key
     * @return bool True if the pool contains RebaseToken
     */    
     
    function isRebaseTokenPool(PoolKey calldata key) internal view returns (bool) {
        return isRebaseToken(Currency.unwrap(key.currency0)) || isRebaseToken(Currency.unwrap(key.currency1));
    }

    /**
     * @notice Mint accrued interest for a user if needed
     * @param tokenAddress Address of the RebaseToken
     * @param user Address of the user
     */
    function mintAccruedInterestIfNeeded(address tokenAddress, address user) internal {
        // This would require adding a mintAccruedInterest function to the RebaseToken contract
        // For now, we assume the interest is minted automatically during transfers/burns/mints
    }

    /**
     * @notice Update the tracked balance for a pool
     * @param poolId ID of the pool
     * @param key Pool key
     */    function updatePoolBalance(PoolId poolId, PoolKey calldata key) internal {
        // Get current reserves
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Calculate reserves based on sqrtPriceX96
        // This is a simplified calculation - in production, use proper Uniswap math
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);
        
        poolBalances[poolId].token0Reserve = price;
        poolBalances[poolId].token1Reserve = 1e18; // Normalized to 1 unit of token1
        poolBalances[poolId].lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Calculate the current imbalance in a pool
     * @param poolId ID of the pool
     * @return imbalance The imbalance in basis points
     */
    function calculatePoolImbalance(PoolId poolId) internal view returns (uint256) {
        // This is a simplified calculation - in production, use proper Uniswap math
        PoolBalance memory balance = poolBalances[poolId];
        
        if (balance.token0Reserve == 0 || balance.token1Reserve == 0) {
            return 0;
        }
        
        // Calculate the current ratio
        uint256 currentRatio = (balance.token0Reserve * PRECISION_FACTOR) / balance.token1Reserve;
        
        // Get the ideal ratio (this could be stored or calculated based on interest rates)
        uint256 idealRatio = PRECISION_FACTOR; // 1:1 ratio for simplicity
        
        // Calculate imbalance in basis points
        if (currentRatio > idealRatio) {
            return ((currentRatio - idealRatio) * PRECISION_FACTOR) / idealRatio;
        } else {
            return ((idealRatio - currentRatio) * PRECISION_FACTOR) / idealRatio;
        }
    }

    /**
     * @notice Check for arbitrage opportunities across chains
     * @param poolId ID of the pool
     * @param key Pool key
     */
    function checkCrossChainArbitrageOpportunities(PoolId poolId, PoolKey calldata key) internal {
        // Get current price on this chain
        uint256 currentPrice = getCurrentPrice(key);
        
        // Check against prices on other chains
        CrossChainConfig[] memory configs = crossChainConfigs[poolId];
        for (uint256 i = 0; i < configs.length; i++) {
            // Skip stale data
            if (block.timestamp - configs[i].lastSyncTimestamp > 1 hours) {
                continue;
            }
            
            uint256 remotePrice = configs[i].currentPrice;
            if (remotePrice == 0) continue;
            
            // Calculate price difference in basis points
            uint256 priceDiff;
            if (currentPrice > remotePrice) {
                priceDiff = ((currentPrice - remotePrice) * PRECISION_FACTOR) / currentPrice;
            } else {
                priceDiff = ((remotePrice - currentPrice) * PRECISION_FACTOR) / currentPrice;
            }
            
            // If price difference exceeds threshold, initiate arbitrage
            if (priceDiff > ARBITRAGE_THRESHOLD) {
                emit ArbitrageOpportunityDetected(poolId, configs[i].chainSelector, priceDiff);
                
                // Only execute if cooldown period has passed
                if (block.timestamp > lastArbitrageTimestamp[poolId] + REBALANCE_COOLDOWN) {
                    executeArbitrage(poolId, key, i, currentPrice, remotePrice);
                }
            }
        }
    }

    /**
     * @notice Execute arbitrage between chains
     * @param poolId ID of the pool
     * @param key Pool key
     * @param chainIndex Index of the destination chain
     * @param localPrice Price on this chain
     * @param remotePrice Price on the destination chain
     */
    function executeArbitrage(
        PoolId poolId,
        PoolKey calldata key,
        uint256 chainIndex,
        uint256 localPrice,
        uint256 remotePrice
    ) internal {
        // Determine direction: buy here and sell there, or vice versa
        bool buyHereSellThere = localPrice < remotePrice;
        
        if (buyHereSellThere) {
            // Calculate optimal amount for arbitrage
            uint256 arbitrageAmount = calculateOptimalArbitrageAmount(localPrice, remotePrice);
            
            // Bridge tokens to destination chain
            bridgeTokens(poolId, chainIndex, arbitrageAmount);
        }
        
        // Update timestamp of last arbitrage
        lastArbitrageTimestamp[poolId] = block.timestamp;
    }

    /**
     * @notice Calculate the optimal amount to arbitrage
     * @param localPrice Price on this chain
     * @param remotePrice Price on the destination chain
     * @return amount The optimal amount to arbitrage
     */
    function calculateOptimalArbitrageAmount(
        uint256 localPrice,
        uint256 remotePrice
    ) internal pure returns (uint256) {
        // Simplified calculation - in production use more sophisticated models
        // that account for slippage, gas costs, etc.
        return 1e18; // 1 token for simplicity
    }    /**
     * @notice Get the current price from a pool
     * @param key Pool key
     * @return price The current price
     */
    function getCurrentPrice(PoolKey calldata key) internal view returns (uint256) {
        // Get current price from Uniswap V4 pool
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, key.toId());
        
        // Convert sqrtPriceX96 to price
        // This is a simplified calculation - in production, use proper Uniswap math
        return uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);
    }

    /**
     * @notice Get the current price from a pool using poolId
     * @param poolId Pool ID
     * @return price The current price
     */
    function getCurrentPriceByPoolId(PoolId poolId) internal view returns (uint256) {
        // Get current price from Uniswap V4 pool
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Convert sqrtPriceX96 to price
        // This is a simplified calculation - in production, use proper Uniswap math
        return uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);
    }

    /**
     * @notice Rebalance liquidity across chains
     * @param poolId ID of the pool
     * @param key Pool key
     * @param imbalance Current imbalance in basis points
     */
    function autoRebalanceAcrossChains(
        PoolId poolId,
        PoolKey calldata key,
        uint256 imbalance
    ) internal {
        // Calculate amount to bridge
        uint256 amountToBridge = calculateRebalanceAmount(poolId, imbalance);
        
        // Find best chain to rebalance with
        uint256 bestChainIndex = findBestChainForRebalance(poolId);
        
        // Bridge tokens
        bridgeTokens(poolId, bestChainIndex, amountToBridge);
    }

    /**
     * @notice Calculate amount needed for rebalancing
     * @param poolId ID of the pool
     * @param imbalance Current imbalance in basis points
     * @return amount Amount to bridge
     */
    function calculateRebalanceAmount(
        PoolId poolId,
        uint256 imbalance
    ) internal view returns (uint256) {
        // Simplified calculation - in production use more sophisticated models
        PoolBalance memory balance = poolBalances[poolId];
        
        // Calculate percentage of imbalance to correct (50% for now)
        uint256 correction = (imbalance * 5000) / PRECISION_FACTOR;
        
        // Calculate amount based on token0 reserve
        return (balance.token0Reserve * correction) / PRECISION_FACTOR;
    }

    /**
     * @notice Find the best chain to rebalance with
     * @param poolId ID of the pool
     * @return chainIndex Index of the best chain
     */
    function findBestChainForRebalance(PoolId poolId) internal view returns (uint256) {
        
        require(crossChainConfigs[poolId].length > 0, "No cross-chain configs available");
        
        // If only one chain configuration exists, return it
        if (crossChainConfigs[poolId].length == 1) {
            return 0;
        }
          // Get local price and interest rate
        uint256 localInterestRate = IRebaseToken(rebaseTokenAddress).getInterestRate();
        uint256 localPrice = getCurrentPriceByPoolId(poolId);
        
        // Variables to track the best chain
        uint256 bestChainIndex = 0;
        uint256 highestScore = 0;
        uint256 maxAge = 2 hours; // Maximum acceptable age for data
        
        // Evaluate each chain configuration
        for (uint256 i = 0; i < crossChainConfigs[poolId].length; i++) {
            CrossChainConfig memory config = crossChainConfigs[poolId][i];
            uint256 chainScore = 0;
            
            // Skip chains with too old data
            if (block.timestamp - config.lastSyncTimestamp > maxAge) {
                continue;
            }
            
            // 1. Score based on interest rate differential (0-50 points)
            uint256 interestRateDiff;
            if (config.currentInterestRate > localInterestRate) {
                interestRateDiff = config.currentInterestRate - localInterestRate;
            } else {
                interestRateDiff = localInterestRate - config.currentInterestRate;
            }
            
            // Higher interest rate differential gets more points (max 50)
            uint256 interestRateScore = (interestRateDiff * 50) / (1e18); // Assuming interest rates are in 1e18 scale
            if (interestRateScore > 50) interestRateScore = 50;
            chainScore += interestRateScore;
            
            // 2. Score based on price differential (0-40 points)
            if (config.currentPrice > 0) {
                uint256 priceDiff;
                if (config.currentPrice > localPrice) {
                    priceDiff = ((config.currentPrice - localPrice) * PRECISION_FACTOR) / localPrice;
                } else {
                    priceDiff = ((localPrice - config.currentPrice) * PRECISION_FACTOR) / localPrice;
                }
                
                // Higher price differential gets more points (max 40)
                uint256 priceScore = (priceDiff * 40) / 1000; // 10% difference would give 40 points
                if (priceScore > 40) priceScore = 40;
                chainScore += priceScore;
            }
            
            // 3. Score based on data recency (0-30 points)
            uint256 dataAge = block.timestamp - config.lastSyncTimestamp;
            uint256 recencyScore = ((maxAge - dataAge) * 30) / maxAge;
            chainScore += recencyScore;
            
            // 4. Consider historical success rate if tracked (would be implemented in production)
            // Example: chainScore += (successRate[poolId][i] * 20) / 100;
            
            // 5. Consider gas costs on destination chain if available
            // Example: chainScore += (maxGasCost - gasCost[config.chainSelector]) * 10 / maxGasCost;
            
            // Update best chain if this one has a higher score
            if (chainScore > highestScore) {
                highestScore = chainScore;
                bestChainIndex = i;
            }
        }
        
        return bestChainIndex;
    }    
    
    /**
     * @notice Bridge tokens to another chain using CCIP
     * @param poolId ID of the pool
     * @param chainIndex Index of the destination chain
     * @param amount Amount to bridge
     */
    function bridgeTokens(
        PoolId poolId,
        uint256 chainIndex,
        uint256 amount
    ) internal {
        require(chainIndex < crossChainConfigs[poolId].length, "Invalid chain index");
        
        CrossChainConfig memory config = crossChainConfigs[poolId][chainIndex];
          // Create CCIP message
        Pool.LockOrBurnInV1 memory lockOrBurnIn = Pool.LockOrBurnInV1({
            receiver: abi.encode(config.poolAddress),
            remoteChainSelector: config.chainSelector,
            originalSender: address(this),
            amount: amount,
            localToken: rebaseTokenAddress
        });
        
        // Execute bridge via RebaseTokenPool
        IRebaseTokenPool(rebaseTokenPoolAddress).lockOrBurn(lockOrBurnIn);
        
        emit CrossChainRebalanceInitiated(poolId, config.chainSelector, amount);
    }
}

// Ankr-Optimized AutoPool Telegram Bot Configuration
// Enhanced configuration using Ankr.com infrastructure for better performance

module.exports = {
    // Telegram Bot Configuration
    telegram: {
        botToken: process.env.TELEGRAM_BOT_TOKEN || '7971008538:AAH4aFwSVtEBK19tBSUxf_QYT1KO7Xopzn8',
        chatId: process.env.TELEGRAM_CHAT_ID || '-1002265429420',
        enableNotifications: true
    },

    // Ankr Blockchain Configuration
    blockchain: {
        // Ankr BSC Mainnet RPC
        rpcUrls: [
            `https://rpc.ankr.com/bsc/${process.env.ANKR_API_KEY || 'ef80b55cc9ebd656fe573fcb1babe7adb6f05bc123eaad02b0a7e8834688766f'}`
        ],
        // Fallback to public endpoints (reduced priority)
        fallbackRpcUrls: [
            'https://bsc-dataseed.binance.org/',
            'https://bsc-dataseed1.defibit.io/'
        ],
        // UPDATED: V11 contract address
        contractAddress: '0xaF1D24B42937Ac8Dfa9e353dc50E40980F2D30E2',
        usdtContractAddress: '0x55d398326f99059fF775485246999027B3197955',
        chainId: 56,
        networkName: 'BSC Mainnet'
    },

    // Ankr Service Configuration
    ankr: {
        apiKeys: [
            process.env.ANKR_API_KEY || 'ef80b55cc9ebd656fe573fcb1babe7adb6f05bc123eaad02b0a7e8834688766f'  // Your Ankr API key
        ],
        enableApiKeyRotation: false, // Single key, no rotation needed
        rateLimitBuffer: 0.8, // Use 80% of rate limit to avoid hitting limits
        enableMonitoring: true
    },

    // Enhanced Event Monitoring - Optimized for Ankr's high performance
    events: {
        enableJoinNotifications: true,
        enableRejoinNotifications: true,
        enableBonusNotifications: false, // Disabled - only show joins and rejoins
        enableStatistics: false, // Disabled to reduce API calls
        checkIntervalSeconds: 5, // 5 seconds with Ankr
        maxBlockRange: 500, // 500 blocks with Ankr
        batchDelay: 500, // Reduced from 2000 to 500ms
        retryDelay: 1000, // Reduced from 5000 to 1000ms
        maxRetries: 5, // Increased retry attempts
        enableBatchRequests: true, // Ankr supports efficient batching
        maxBatchSize: 10
    },

    // Enhanced Connection Settings
    connection: {
        reconnectAttempts: 10, // Increased due to better reliability
        reconnectDelayMs: 3000, // Reduced delay
        timeoutMs: 15000, // Reduced timeout (Ankr is fast)
        enableHealthCheck: true,
        healthCheckIntervalMs: 60000, // Check connection health every minute
        enableLoadBalancing: true
    },

    // Enhanced Message Formatting
    messages: {
        includeEmojis: true,
        includeAmounts: true,
        includeStats: false, // Disabled for cleaner messages
        includeLinks: true,
        includeAnkrStats: false, // Disabled for cleaner messages
        bscScanUrl: 'https://bscscan.com'
    },

    // Performance Monitoring
    monitoring: {
        enablePerformanceLogging: true,
        logRpcResponseTimes: true,
        alertOnSlowResponse: true,
        slowResponseThresholdMs: 2000,
        enableDashboard: true
    },

    // V11 Contract ABI - Load from external file
    contractABI: require('./newcontractabi.json')
}; 

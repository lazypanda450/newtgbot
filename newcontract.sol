/**
 *Submitted for verification at BscScan.com on 2025-07-20
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAutoPoolFundV12 {
    function users(address user) external view returns (
        address referrer, uint256 totalEarned, uint256 lastJoinTime, uint256 lastROITime,
        uint256 joinCount, uint256 rejoinCount, bool isActive, bool reachedTotalLimit, uint256 directReferrals
    );
    function userDownlines(address user, uint256 index) external view returns (address);
    function userPendingROI(address user) external view returns (uint256);
    function autopoolPendingBalance(address user) external view returns (uint256);
    function userTotalROIClaims(address user) external view returns (uint256);
    function migratedUsers(uint256 index) external view returns (address);
    function migratedUsersCount() external view returns (uint256);
    function totalUsers() external view returns (uint256);
}

contract TeamBasedAutoPool {
    IERC20 public usdt;
    address public admin;
    bool internal locked;
    IAutoPoolFundV12 private oldV12Contract;

    // Constants
    uint256 public constant ENTRY_FEE = 10 * 1e18;
    uint256 public constant REJOIN_FEE = 10 * 1e18;
    uint256 public constant ADMIN_FEE_ENTRY = 2 * 1e18;
    uint256 public constant ADMIN_FEE_REJOIN = 1 * 1e18;
    uint256 public constant POOL_PAYOUT = 20 * 1e18;
    uint256 public constant ROI_PAYOUT = 12 * 1e18;
    uint256 public constant ROI_DURATION = 1 hours;
    uint256 public constant TEAM_SIZE = 3; // 3 members needed for pool payout
    uint256 public constant MIN_TOTAL_DIRECTS = 1;
    uint256 public constant NET_PROFIT_CAP = 20 * 1e18; // 20 USDT net profit cap

    struct User {
        address referrer;
        uint256 totalEarned;
        uint256 lastJoinTime;
        uint256 joinCount;
        uint256 rejoinCount;
        bool isActive;
        uint256 totalDirectReferrals;
        uint256 roiStartTime;
        bool hasPoolPending;
        bool hasROIPending;
        uint256 totalInvested;
        uint256 netProfit;
    }

    // Core mappings
    mapping(address => User) public users;
    mapping(address => address[]) public userDownlines;
    mapping(address => uint256) public pendingPoolClaim;
    mapping(address => uint256) public pendingROIClaim;

    // Team pool mappings
    mapping(address => address[]) public teamPools; // referrer => pool queue
    mapping(address => uint256) public userPoolPosition; // user => position in their team pool

    // Migration mappings
    mapping(address => bool) public hasBeenMigrated;
    mapping(address => bool) public downlinesMigrated;
    address[] public migratedUsers;
    uint256 public migratedUsersCount;
    bool public migrationCompleted;
    uint8 public currentMigrationPhase;
    uint256 public newMigrationIndex;
    uint256 public totalUsersMigrated;
    bool public newMigrationActive;

    // Stats
    uint256 public totalUsers;
    uint256 public totalFundsReceived;
    uint256 public totalPoolPayouts;
    uint256 public totalROIPayouts;

    event Join(address indexed user, address indexed referrer, uint256 fee);
    event Rejoin(address indexed user, address indexed referrer, uint256 fee);
    event PoolPayout(address indexed user, address indexed teamLeader, uint256 amount, uint256 position);
    event ROIPayout(address indexed user, uint256 amount);
    event PoolClaim(address indexed user, uint256 amount);
    event ROIClaim(address indexed user, uint256 amount);
    event ActiveDirectUpdate(address indexed referrer, address indexed direct, uint256 newCount);
    event NetProfitCapReached(address indexed user, uint256 netProfit);
    
    // Migration events
    event Migrate(address indexed user, address indexed referrer, uint256 dirs, uint256 earned);
    event UserDeactivated(address indexed user, uint256 rejoinCount, string reason);
    event DownMigrate(address indexed user, uint256 count);
    event BatchDone(uint256 batch, uint256 index, uint256 time);
    event MigrateDone(uint256 total, uint256 time);

    modifier noReentrant() {
        require(!locked);
        locked = true;
        _;
        locked = false;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    modifier postMigration() {
        require(migrationCompleted);
        _;
    }

    constructor() {
        usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
        admin = 0x3Da7310861fbBdf5105ea6963A2C39d0Cb34a4Ff;
        oldV12Contract = IAutoPoolFundV12(0x982e0C94E805eaa405E12E0ee0531A245934D244);
        
        // Initialize admin
        users[admin].isActive = true;
        users[admin].lastJoinTime = block.timestamp;
        users[admin].joinCount = 1;
        users[admin].roiStartTime = block.timestamp;
        users[admin].totalDirectReferrals = 0;
    }

    // ===================
    // MAIN FUNCTIONS
    // ===================

    function join(address referrer) external postMigration noReentrant {
        User storage user = users[msg.sender];
        require(!user.isActive, "User already active");
        require(user.joinCount == 0, "Use rejoin function");
        require(usdt.transferFrom(msg.sender, address(this), ENTRY_FEE), "Transfer failed");

        // Validate referrer
        address actualReferrer = admin;
        if (referrer != address(0) && referrer != msg.sender && users[referrer].isActive) {
            actualReferrer = referrer;
        }

        // Set user data
        user.referrer = actualReferrer;
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.joinCount = 1;
        user.rejoinCount = 0;
        user.roiStartTime = block.timestamp;
        user.hasPoolPending = false;
        user.hasROIPending = false;

        user.totalDirectReferrals = 0; // Initialize to 0
        user.totalInvested += ENTRY_FEE; // Track investment
        user.netProfit = user.totalEarned - user.totalInvested; // Calculate net profit

        // Add to referrer's downlines and update active count
        userDownlines[actualReferrer].push(msg.sender);
        users[actualReferrer].totalDirectReferrals += 1;
        
        // BUG FIX #2: Remove duplicate active direct update (handled in _enterTeamPool)
        // Active direct count will be updated in _enterTeamPool function

        // Enter team pool (BUG FIX #5: Use active team leader)
        address activeTeamLeader = _getActiveTeamLeader(msg.sender);
        _enterTeamPool(msg.sender, activeTeamLeader);

        // Admin fee and stats
        require(usdt.transfer(admin, ADMIN_FEE_ENTRY), "Admin fee transfer failed");
        totalUsers += 1;
        totalFundsReceived += ENTRY_FEE;

        emit Join(msg.sender, actualReferrer, ENTRY_FEE);
    }

    function rejoin() external postMigration noReentrant {
        User storage user = users[msg.sender];
        require(!user.isActive, "User already active");
        require(user.joinCount > 0, "Use join function first");
        require(usdt.transferFrom(msg.sender, address(this), REJOIN_FEE), "Transfer failed");

        // Clear any pending claims first
        pendingPoolClaim[msg.sender] = 0;
        pendingROIClaim[msg.sender] = 0;

        // Reset user state
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.rejoinCount += 1;
        user.roiStartTime = block.timestamp;
        user.hasPoolPending = false;
        user.hasROIPending = false;
        

        
        // Track investment
        user.totalInvested += REJOIN_FEE;
        user.netProfit = user.totalEarned - user.totalInvested;



        // Re-enter team pool (BUG FIX #5: Use active team leader)
        address activeTeamLeader = _getActiveTeamLeader(msg.sender);
        _enterTeamPool(msg.sender, activeTeamLeader);

        // Admin fee and stats
        require(usdt.transfer(admin, ADMIN_FEE_REJOIN), "Admin fee transfer failed");
        totalFundsReceived += REJOIN_FEE;

        emit Rejoin(msg.sender, user.referrer, REJOIN_FEE);
    }



    // Remove manual recalculation function - now done automatically during migration
    // BUG FIX #5: Ensure users join active referrer's pool or admin's pool
    function _getActiveTeamLeader(address userAddr) internal view returns (address) {
        address referrer = users[userAddr].referrer;
        
        // If referrer is active, use their pool
        if (referrer != address(0) && users[referrer].isActive) {
            return referrer;
        }
        
        // Otherwise, assign to admin's pool to prevent dead pools
        return admin;
    }

    function _enterTeamPool(address userAddr, address teamLeader) internal {
        // Remove from any existing pool first
        _removeFromTeamPool(userAddr);
        
        // Add to team pool queue (everyone rotates equally)
        teamPools[teamLeader].push(userAddr);
        userPoolPosition[userAddr] = teamPools[teamLeader].length - 1;
        

        
        // Check if pool is ready for payout
        _processTeamPool(teamLeader);
    }

    function _processTeamPool(address teamLeader) internal {
        address[] storage pool = teamPools[teamLeader];
        
        if (pool.length >= TEAM_SIZE) {
            address payoutUser = pool[0]; // First person in queue gets paid
            
            // Give pool payout to first user (regardless if it's team leader or member)
            pendingPoolClaim[payoutUser] = POOL_PAYOUT;
            users[payoutUser].hasPoolPending = true;
            users[payoutUser].hasROIPending = false; // No ROI if pool pending
            users[payoutUser].isActive = false; // BUG FIX #1: Deactivate user who gets pool payout
            
            emit PoolPayout(payoutUser, teamLeader, POOL_PAYOUT, 0);
            
            // Remove first user and shift queue - EVERYONE rotates equally
            for (uint256 i = 0; i < pool.length - 1; i++) {
                pool[i] = pool[i + 1];
                userPoolPosition[pool[i]] = i;
            }
            pool.pop();
            
            // Reset position for the paid user
            userPoolPosition[payoutUser] = 0;
            
            totalPoolPayouts += POOL_PAYOUT;
        }
    }

    // ===================
    // CLAIM FUNCTIONS
    // ===================

    function claimPool() external postMigration noReentrant {
        User storage user = users[msg.sender];
        require(user.hasPoolPending, "No pool to claim");
        require(user.totalDirectReferrals >= MIN_TOTAL_DIRECTS, "Need 1 total direct");
        
        uint256 amount = pendingPoolClaim[msg.sender];
        require(amount > 0, "No pool amount");
        require(usdt.balanceOf(address(this)) >= amount, "Insufficient contract balance");
        
        // Reset state
        pendingPoolClaim[msg.sender] = 0;
        user.hasPoolPending = false;
        user.isActive = false; // User out of pool immediately
        
        // Update earnings and net profit
        user.totalEarned += amount;
        user.netProfit = user.totalEarned - user.totalInvested;
        
        // Check net profit cap and reset directs if needed
        if (user.netProfit >= NET_PROFIT_CAP) {
            user.totalDirectReferrals = 0;
            // Clear downlines array
            delete userDownlines[msg.sender];
            emit NetProfitCapReached(msg.sender, user.netProfit);
        }
        
        require(usdt.transfer(msg.sender, amount), "Transfer failed");
        
        emit PoolClaim(msg.sender, amount);
    }

    function claimROI() external postMigration noReentrant {
        User storage user = users[msg.sender];
        require(user.isActive, "User not active");
        require(!user.hasPoolPending, "Has pool pending - claim pool first");
        require(user.totalDirectReferrals >= MIN_TOTAL_DIRECTS, "Need 1 total direct");
        require(user.roiStartTime > 0, "ROI not started");
        
        // BUG FIX #4: Check if 1 hour passed AND user still in pool (no pool payout received)
        require(block.timestamp >= user.roiStartTime + ROI_DURATION, "ROI not ready");
        require(!user.hasPoolPending, "Pool payout received - cannot claim ROI");
        
        // Ensure user doesn't already have ROI pending
        require(!user.hasROIPending, "ROI already pending");
        
        // Set ROI pending
        pendingROIClaim[msg.sender] = ROI_PAYOUT;
        user.hasROIPending = true;
        user.isActive = false; // User out of pool
        
        // Remove from current pool position
        _removeFromTeamPool(msg.sender);
        
        totalROIPayouts += ROI_PAYOUT;
        emit ROIPayout(msg.sender, ROI_PAYOUT);
        
        // Auto-claim the ROI immediately
        uint256 amount = pendingROIClaim[msg.sender];
        require(usdt.balanceOf(address(this)) >= amount, "Insufficient contract balance");
        
        // Reset state
        pendingROIClaim[msg.sender] = 0;
        user.hasROIPending = false;
        
        // Update earnings and net profit
        user.totalEarned += amount;
        user.netProfit = user.totalEarned - user.totalInvested;
        
        // Check net profit cap and reset directs if needed
        if (user.netProfit >= NET_PROFIT_CAP) {
            user.totalDirectReferrals = 0;
            // Clear downlines array
            delete userDownlines[msg.sender];
            emit NetProfitCapReached(msg.sender, user.netProfit);
        }
        
        require(usdt.transfer(msg.sender, amount), "Transfer failed");
        
        emit ROIClaim(msg.sender, amount);
    }

    function _removeFromTeamPool(address userAddr) internal {
        address teamLeader = users[userAddr].referrer;
        address[] storage pool = teamPools[teamLeader];
        uint256 position = userPoolPosition[userAddr];
        
        if (position < pool.length && pool[position] == userAddr) {
            // Remove user and shift positions
            for (uint256 i = position; i < pool.length - 1; i++) {
                pool[i] = pool[i + 1];
                userPoolPosition[pool[i]] = i;
            }
            pool.pop();
            userPoolPosition[userAddr] = 0; // Reset position
        }
    }

    // ===================
    // VIEW FUNCTIONS  
    // ===================

    function getUserInfo(address userAddr) external view returns (
        address referrer,
        bool isActive,
        uint256 totalDirects,
        uint256 joinCount,
        uint256 rejoinCount
    ) {
        return (
            users[userAddr].referrer,
            users[userAddr].isActive,
            users[userAddr].totalDirectReferrals,
            users[userAddr].joinCount,
            users[userAddr].rejoinCount
        );
    }

    function getUserStatus(address userAddr) external view returns (
        uint256 roiTimeLeft,
        bool hasPool,
        bool hasROI,
        uint256 poolPosition
    ) {
        return (
            (users[userAddr].isActive && users[userAddr].roiStartTime > 0 && block.timestamp < users[userAddr].roiStartTime + ROI_DURATION) 
                ? (users[userAddr].roiStartTime + ROI_DURATION) - block.timestamp : 0,
            users[userAddr].hasPoolPending,
            users[userAddr].hasROIPending,
            userPoolPosition[userAddr]
        );
    }

    function getNetProfitInfo(address userAddr) external view returns (
        uint256 totalInvested,
        uint256 totalEarned,
        uint256 netProfit,
        uint256 profitCapRemaining,
        bool willResetDirects
    ) {
        User memory user = users[userAddr];
        uint256 remaining = user.netProfit >= NET_PROFIT_CAP ? 0 : NET_PROFIT_CAP - user.netProfit;
        bool willReset = user.netProfit >= NET_PROFIT_CAP;
        
        return (
            user.totalInvested,
            user.totalEarned,
            user.netProfit,
            remaining,
            willReset
        );
    }

    function getTeamPoolInfo(address teamLeader) external view returns (
        address[] memory poolQueue,
        uint256 poolSize,
        uint256 membersNeededForPayout,
        address nextToPayout
    ) {
        address[] memory queue = teamPools[teamLeader];
        uint256 needed = queue.length >= TEAM_SIZE ? 0 : TEAM_SIZE - queue.length;
        address nextPayout = queue.length > 0 ? queue[0] : address(0);
        
        return (queue, queue.length, needed, nextPayout);
    }

    function getPendingClaims(address userAddr) external view returns (
        uint256 poolAmount,
        uint256 roiAmount,
        bool canClaimPool,
        bool canClaimROI
    ) {
        User memory user = users[userAddr];
        bool hasTotalDirects = user.totalDirectReferrals >= MIN_TOTAL_DIRECTS;
        
        return (
            pendingPoolClaim[userAddr],
            pendingROIClaim[userAddr],
            user.hasPoolPending && hasTotalDirects,
            user.hasROIPending && hasTotalDirects
        );
    }

    function getContractStats() external view returns (
        uint256 totalUsersCount,
        uint256 totalFundsReceivedAmount,
        uint256 totalPoolPayoutsAmount,
        uint256 totalROIPayoutsAmount,
        uint256 contractBalance
    ) {
        return (
            totalUsers,
            totalFundsReceived,
            totalPoolPayouts,
            totalROIPayouts,
            usdt.balanceOf(address(this))
        );
    }

    // ===================
    // MIGRATION FUNCTIONS
    // ===================

    function startNewMigration() external onlyAdmin {
        require(!migrationCompleted, "Migration already completed");
        newMigrationActive = true;
        newMigrationIndex = 0;
        totalUsersMigrated = 0;
        currentMigrationPhase = 0;
    }
    
    function newBatchMigration(uint256 batchSize) external onlyAdmin {
        require(newMigrationActive, "New migration not started");
        require(!migrationCompleted, "Migration completed");
        require(batchSize >= 10 && batchSize <= 100, "Batch size 10-100");
        
        uint256 oldContractTotalUsers;
        try oldV12Contract.totalUsers() returns (uint256 total) {
            oldContractTotalUsers = total;
        } catch {
            oldContractTotalUsers = 0;
        }
        
        require(oldContractTotalUsers > 0, "No users in old contract");
        
        if (currentMigrationPhase == 0) {
            _newMigrateUsersBatch(batchSize, oldContractTotalUsers);
        } else if (currentMigrationPhase == 1) {
            _newMigrateDownlinesBatch(batchSize);
        }
    }

    function _newMigrateUsersBatch(uint256 batchSize, uint256 totalUsersInOld) internal {
        uint256 processed = 0;
        uint256 attempts = 0;
        uint256 maxAttempts = batchSize * 3;
        
        while (processed < batchSize && attempts < maxAttempts && newMigrationIndex < totalUsersInOld) {
            attempts++;
            
            address userToMigrate = address(0);
            bool foundUser = false;
            
            if (newMigrationIndex < 334) {
                try oldV12Contract.migratedUsers(newMigrationIndex) returns (address userAddr) {
                    if (userAddr != address(0)) {
                        userToMigrate = userAddr;
                        foundUser = true;
                    }
                } catch {}
            }
            
            if (foundUser && userToMigrate != address(0) && !hasBeenMigrated[userToMigrate]) {
                try oldV12Contract.users(userToMigrate) returns (
                    address, uint256, uint256 lastJoinTime, uint256, uint256, uint256, bool, bool, uint256
                ) {
                    if (lastJoinTime > 0) {
                        _newMigrateUser(userToMigrate);
                        processed++;
                        totalUsersMigrated++;
                    }
                } catch {}
            }
            
            newMigrationIndex++;
        }
        
        emit BatchDone(processed, newMigrationIndex, block.timestamp);
    }
    
    function _newMigrateUser(address userAddr) internal {
        try oldV12Contract.users(userAddr) returns (
            address oldReferrer, uint256 oldTotalEarned, uint256 oldLastJoinTime, uint256,
            uint256 oldJoinCount, uint256 oldRejoinCount, bool oldIsActive, bool, uint256 oldDirectReferrals
        ) {
            if (oldLastJoinTime == 0) return;
            
            // Validate referrer
            address validatedReferrer = oldReferrer;
            if (oldReferrer != admin && oldReferrer != address(0)) {
                if (!hasBeenMigrated[oldReferrer] && !users[oldReferrer].isActive) {
                    validatedReferrer = admin;
                }
            }
            
            // Deactivate users who have 2 or more rejoins
            bool shouldBeActive = oldIsActive;
            if (oldRejoinCount >= 2) {
                shouldBeActive = false;
            }
            
            // Set user data for new autopool system
            users[userAddr] = User({
                referrer: validatedReferrer,
                totalEarned: oldTotalEarned,
                lastJoinTime: oldLastJoinTime,
                joinCount: oldJoinCount,
                rejoinCount: oldRejoinCount,
                isActive: shouldBeActive,
                totalDirectReferrals: 0, // Reset all directs to 0 in migration
                roiStartTime: shouldBeActive ? block.timestamp : 0,
                hasPoolPending: false,
                hasROIPending: false,
                totalInvested: 0, // Migration users start with 0 investment tracking
                netProfit: oldTotalEarned // Existing earnings count as net profit
            });
            
            // Mark as migrated
            hasBeenMigrated[userAddr] = true;
            migratedUsers.push(userAddr);
            migratedUsersCount++;
            totalUsers++;
            
            if (oldRejoinCount >= 2) {
                emit UserDeactivated(userAddr, oldRejoinCount, "User with 2+ rejoins deactivated - must rejoin");
            }
            
            emit Migrate(userAddr, validatedReferrer, oldDirectReferrals, oldTotalEarned);
        } catch {}
    }

    function migrateRemainingSpecificUsers(address[] calldata remainingUserAddresses) external onlyAdmin {
        require(newMigrationActive, "New migration not started");
        require(remainingUserAddresses.length <= 50, "Max 50 users");
        
        uint256 migrated = 0;
        for (uint256 i = 0; i < remainingUserAddresses.length; i++) {
            address userAddr = remainingUserAddresses[i];
            if (!hasBeenMigrated[userAddr] && userAddr != address(0)) {
                _newMigrateUser(userAddr);
                migrated++;
                totalUsersMigrated++;
            }
        }
        
        emit BatchDone(migrated, newMigrationIndex, block.timestamp);
    }
    
    function _newMigrateDownlinesBatch(uint256 batchSize) internal {
        uint256 processed = 0;
        
        for (uint256 i = 0; i < migratedUsers.length && processed < batchSize; i++) {
            address userAddr = migratedUsers[i];
            if (hasBeenMigrated[userAddr] && !downlinesMigrated[userAddr]) {
                _newMigrateDownlines(userAddr);
                processed++;
            }
        }
        
        emit BatchDone(processed, newMigrationIndex, block.timestamp);
    }

    function _newMigrateDownlines(address userAddr) internal {
        // Get original downline count from old contract (since we reset totalDirectReferrals to 0)
        uint256 expectedDownlines = 0;
        try oldV12Contract.users(userAddr) returns (
            address, uint256, uint256, uint256, uint256, uint256, bool, bool, uint256 oldDirectReferrals
        ) {
            expectedDownlines = oldDirectReferrals;
        } catch {}
        
        delete userDownlines[userAddr];
        
        uint256 actualCount = 0;
        
        for (uint256 i = 0; i < expectedDownlines && i < 50; i++) {
            try oldV12Contract.userDownlines(userAddr, i) returns (address downline) {
                if (downline != address(0)) {
                    userDownlines[userAddr].push(downline);
                    actualCount++;
                }
            } catch {
                break; 
            }
        }
        

        
        downlinesMigrated[userAddr] = true;
        emit DownMigrate(userAddr, actualCount);
        

    }

    function startDownlinesMigration() external onlyAdmin {
        require(newMigrationActive, "New migration not started");
        currentMigrationPhase = 1;
    }
    
    function completeNewMigration() external onlyAdmin {
        require(newMigrationActive, "New migration not started");
        migrationCompleted = true;
        currentMigrationPhase = 2;
        newMigrationActive = false;
        emit MigrateDone(totalUsersMigrated, block.timestamp);
    }

    function getMigrationStats() external view returns (
        bool isCompleted,
        uint256 migratedCount,
        uint256 totalMigrated,
        uint8 currentPhase,
        bool isActive
    ) {
        return (
            migrationCompleted,
            migratedUsersCount,
            totalUsersMigrated,
            currentMigrationPhase,
            newMigrationActive
        );
    }

    // ===================
    // ADMIN FUNCTIONS
    // ===================

    function emergencyWithdraw(uint256 amount) external onlyAdmin {
        require(usdt.transfer(admin, amount), "Transfer failed");
    }
}
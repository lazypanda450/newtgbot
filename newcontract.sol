/**
 *Submitted for verification at BscScan.com on 2025-07-19
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
    function autopoolPendingBalance(address user) external view returns (uint256);
    function migratedUsers(uint256 index) external view returns (address);
    function migratedUsersCount() external view returns (uint256);
    function totalUsers() external view returns (uint256);
}

contract AutoPoolFundV12Final {
    IERC20 public usdt;
    address public admin;
    bool internal locked;
    bool public emergencyPaused;
    IAutoPoolFundV12 private oldV12Contract;

    // Constants
    uint256 public constant ENTRY_FEE = 10 * 1e18;
    uint256 public constant REJOIN_FEE = 10 * 1e18;
    uint256 public constant ADMIN_FEE_PER_JOIN = 2 * 1e18;
    uint256 public constant ADMIN_FEE_FROM_ENTRY = 2 * 1e18;
    uint256 public constant MIN_CONTRACT_BALANCE = 200 * 1e18;
    uint256 public constant AUTOPOOL_COMMISSION = 20 * 1e18;
    uint256 public constant MIN_CLAIM_AMOUNT = 20 * 1e18;
    uint256 public constant TEAM_POOL_SIZE = 3;
    uint256 public constant MIN_DIRECT_FOR_CLAIM = 1;
    uint256 public constant HOURLY_INCOME = 12 * 1e18;
    uint256 public constant HOURLY_INCOME_INTERVAL = 1 hours;
    uint256 public constant MIN_HOURLY_CLAIM = 12 * 1e18;

    struct User {
        address referrer;
        uint256 totalEarned;
        uint256 lastJoinTime;
        uint256 joinCount;
        uint256 rejoinCount;
        bool isActive;
        bool reachedTotalLimit;
        uint256 directReferrals;
        uint256 lastPoolJoinTime;
        uint256 lastHourlyUpdate;
        uint256 activeDirects;
    }

    // Core mappings
    mapping(address => User) public users;
    mapping(address => address[]) public userDownlines;
    mapping(address => uint256) public autopoolPendingBalance;
    mapping(address => uint256) public hourlyIncomePending;

    // Autopool mappings
    mapping(address => address[]) public teamAutopoolQueue;
    mapping(address => address) public userTeamLeader;
    mapping(address => uint256) public autopoolTotalEarned;
    mapping(address => uint256) public autopoolPosition;
    mapping(address => bool) public isAutopoolActive;
    mapping(address => uint256) public teamJoinCount; // Track joins per team leader
    mapping(address => bool) public autopoolProcessing; // Race condition protection

    // Migration mappings
    mapping(address => bool) public hasBeenMigrated;
    mapping(address => bool) public downlinesMigrated;
    address[] public migratedUsers;
    uint256 public migratedUsersCount;
    uint256 public migrationCurrentIndex;
    bool public migrationCompleted;
    uint8 public currentMigrationPhase;

    // New migration system
    uint256 public newMigrationIndex;
    uint256 public totalUsersMigrated;
    bool public newMigrationActive;

    // State variables
    uint256 public totalUsers;
    uint256 public totalFundsReceived;
    uint256 public totalPaidOut;
    uint256 public totalHourlyIncomePaid;

    event Join(address indexed user, address indexed referrer, uint256 fee);
    event Rejoin(address indexed user, address indexed referrer, uint256 fee);
    event PoolOut(address indexed user, address indexed leader, uint256 amount, uint256 pos);
    event PoolClaim(address indexed user, uint256 amount);
    event HourlyIncomeAdd(address indexed user, uint256 amount, uint256 total, uint256 time);
    event HourlyIncomeClaim(address indexed user, uint256 amount);
    event AutopoolReset(address indexed user, uint256 resetAmount, string reason);
    event Migrate(address indexed user, address indexed referrer, uint256 dirs, uint256 earned);
    event DownMigrate(address indexed user, uint256 count);
    event BatchDone(uint256 batch, uint256 index, uint256 time);
    event MigrateDone(uint256 total, uint256 time);
    event EmergencyPause(uint256 timestamp);
    event EmergencyUnpause(uint256 timestamp);

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

    modifier whenNotPaused() {
        require(!emergencyPaused, "Contract is paused");
        _;
    }

    modifier emergencyOnly() {
        require(emergencyPaused, "Only during emergency");
        _;
    }

    constructor() {
        usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
        admin = 0x3Da7310861fbBdf5105ea6963A2C39d0Cb34a4Ff;
        oldV12Contract = IAutoPoolFundV12(0x982e0C94E805eaa405E12E0ee0531A245934D244);
        users[admin].isActive = true;
        users[admin].lastJoinTime = block.timestamp;
        users[admin].joinCount = 1;
    }

    // SIMPLIFIED: Check 1 direct referral that is active (Gas optimized)
    function hasActiveDirectReferral(address userAddr) public view returns (bool) {
        if (users[userAddr].directReferrals == 0) return false;
        
        // Check if any direct referral is active (cap loop to prevent gas issues)
        address[] memory downlines = userDownlines[userAddr];
        uint256 maxCheck = downlines.length > 50 ? 50 : downlines.length; // Gas limit protection
        
        for (uint256 i = 0; i < maxCheck; i++) {
            if (downlines[i] != address(0) && users[downlines[i]].isActive) {
                return true; // Found at least 1 active direct
            }
        }
        return false; // No active directs found
    }

    // BUSINESS LOGIC: Either/Or system - user can claim EITHER autopool OR ROI
    function getClaimableInfo(address userAddr) external view returns (
        bool canClaimROI,
        bool canClaimAutopool, 
        uint256 roiAmount,
        uint256 autopoolAmount,
        string memory message
    ) {
        uint256 hourlyPending = this.getPendingHourlyIncome(userAddr);
        uint256 autopoolPending = autopoolPendingBalance[userAddr];
        bool hasRequiredDirects = hasActiveDirectReferral(userAddr);
        
        canClaimROI = hourlyPending >= MIN_HOURLY_CLAIM && hasRequiredDirects;
        canClaimAutopool = autopoolPending >= MIN_CLAIM_AMOUNT && hasRequiredDirects;
        
        roiAmount = hourlyPending;
        autopoolAmount = autopoolPending;
        
        if (!hasRequiredDirects) {
            message = "Need 1 active direct to claim";
        } else if (canClaimROI && canClaimAutopool) {
            message = "You can claim EITHER ROI or autopool earnings";
        } else if (canClaimROI) {
            message = "Can claim ROI earnings";
        } else if (canClaimAutopool) {
            message = "Can claim autopool earnings";
        } else {
            message = "No claimable amounts available";
        }
    }

    // BUSINESS LOGIC: Show user their earning options (Either/Or system)
    function getEarningsOptions(address userAddr) external view returns (
        uint256 roiAmount,
        uint256 autopoolAmount,
        bool canClaimROI,
        bool canClaimAutopool,
        bool hasRequiredDirects,
        string memory options
    ) {
        uint256 hourlyPending = this.getPendingHourlyIncome(userAddr);
        uint256 autopoolPending = autopoolPendingBalance[userAddr];
        bool hasDirects = hasActiveDirectReferral(userAddr);
        
        bool _canClaimROI = hourlyPending >= MIN_HOURLY_CLAIM && hasDirects;
        bool _canClaimAutopool = autopoolPending >= MIN_CLAIM_AMOUNT && hasDirects;
        
        string memory message;
        if (_canClaimROI && _canClaimAutopool) {
            message = "You can choose: Claim ROI OR claim autopool (both available)";
        } else if (_canClaimROI) {
            message = "ROI available for claiming";
        } else if (_canClaimAutopool) {
            message = "Autopool available for claiming";
        } else {
            message = "No earnings ready for claiming yet";
        }
        
        return (
            hourlyPending,
            autopoolPending,
            _canClaimROI,
            _canClaimAutopool,
            hasDirects,
            message
        );
    }

    // FIXED: Join Function with proper security and validation
    function join(address referrer) external postMigration noReentrant whenNotPaused {
        // CHECKS: Input validation
        require(msg.sender != address(0), "Invalid sender address");
        require(usdt.balanceOf(msg.sender) >= ENTRY_FEE, "Insufficient USDT balance");
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE, "Contract balance too low");
        
        User storage user = users[msg.sender];

        if (user.reachedTotalLimit) {
            // REJOIN LOGIC
            require(usdt.balanceOf(msg.sender) >= REJOIN_FEE, "Insufficient USDT for rejoin");
            require(user.referrer != address(0), "Invalid referrer for rejoin");
            
            // EFFECTS: Update state before external calls
            user.rejoinCount += 1;
            user.reachedTotalLimit = false;
            user.isActive = true;
            user.lastJoinTime = block.timestamp;
            user.joinCount += 1;
            totalFundsReceived += REJOIN_FEE;
            
            // Reset directs to 0 on rejoin as per requirement  
            user.directReferrals = 0;
            user.activeDirects = 0;
            
            // CRITICAL FIX: Correct state update order
            // 1. First recalculate this user's own directs (after state is set)
            _recalculateDirectReferrals(msg.sender);
            _recalculateActiveDirects(msg.sender);
            
            // 2. THEN update referrer's active direct count (now that user is active)
            _updateReferrerActiveDirects(msg.sender, true);
            
            // INTERACTIONS: External calls last
            require(usdt.transferFrom(msg.sender, address(this), REJOIN_FEE), "Rejoin fee transfer failed");
            require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN), "Admin fee transfer failed");
            
            _enterUserIntoAutopool(msg.sender);
            emit Rejoin(msg.sender, user.referrer, REJOIN_FEE);
            return;
        }

        // FIRST-TIME JOIN LOGIC
        require(!user.isActive && user.joinCount == 0, "User already joined");
        require(usdt.balanceOf(msg.sender) >= ENTRY_FEE, "Insufficient USDT for entry");

        // Validate referrer
        address actualReferrer = admin;
        if (referrer != address(0) && referrer != msg.sender && users[referrer].isActive) {
            actualReferrer = referrer;
        }
        require(actualReferrer != address(0), "Invalid referrer");
        
        // EFFECTS: Update all state before external calls
        user.referrer = actualReferrer;
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.joinCount = 1;
        user.rejoinCount = 0;
        user.directReferrals = 0;
        user.lastPoolJoinTime = 0;
        user.lastHourlyUpdate = 0;
        user.activeDirects = 0;
        
        // Add to downlines safely
        userDownlines[actualReferrer].push(msg.sender);
        users[actualReferrer].directReferrals += 1;
        
        totalUsers += 1;
        totalFundsReceived += ENTRY_FEE;
        
        // INTERACTIONS: External calls last
        require(usdt.transferFrom(msg.sender, address(this), ENTRY_FEE), "Entry fee transfer failed");
        require(usdt.transfer(admin, ADMIN_FEE_FROM_ENTRY), "Admin fee transfer failed");
        
        // Update referrer's active direct count after successful join
        _updateReferrerActiveDirects(msg.sender, true);

        _enterUserIntoAutopool(msg.sender);
        emit Join(msg.sender, user.referrer, ENTRY_FEE);
    }

    // FIXED: Improved claim function with ROI priority logic
    function claimAutopoolEarnings() external postMigration noReentrant whenNotPaused {
        // CHECKS: Input validation and requirements
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE, "Insufficient contract balance");
        require(hasActiveDirectReferral(msg.sender), "Need 1 active direct to claim");
        require(msg.sender != address(0), "Invalid address");
        
        uint256 pending = autopoolPendingBalance[msg.sender];
        require(pending >= MIN_CLAIM_AMOUNT, "Below minimum claim amount");
        require(usdt.balanceOf(address(this)) >= pending, "Insufficient funds for transfer");
        
        // EFFECTS: Update all state first (CEI Pattern)
        autopoolPendingBalance[msg.sender] = 0;
        users[msg.sender].totalEarned += pending;
        totalPaidOut += pending;
        
        // Update referrer's active direct count before making user inactive
        _updateReferrerActiveDirects(msg.sender, false);

        users[msg.sender].isActive = false;
        users[msg.sender].reachedTotalLimit = true;
        
        // INTERACTIONS: External calls last
        require(usdt.transfer(msg.sender, pending), "Transfer failed");
        emit PoolClaim(msg.sender, pending);
    }

    function claimHourlyIncome() external postMigration noReentrant whenNotPaused {
        // CHECKS: Input validation and requirements
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE, "Insufficient contract balance");
        require(hasActiveDirectReferral(msg.sender), "Need 1 active direct to claim");
        require(msg.sender != address(0), "Invalid address");
        
        // Update hourly income calculation first
        _updateHourlyIncome(msg.sender);
        
        uint256 pending = hourlyIncomePending[msg.sender];
        require(pending >= MIN_HOURLY_CLAIM, "Below minimum hourly claim amount");
        require(usdt.balanceOf(address(this)) >= pending, "Insufficient funds for transfer");
        
        // EFFECTS: Update all state first (CEI Pattern)
        hourlyIncomePending[msg.sender] = 0;
        totalHourlyIncomePaid += pending;
        users[msg.sender].totalEarned += pending;
        
        // Update referrer's active direct count before making user inactive
        _updateReferrerActiveDirects(msg.sender, false);
        
        users[msg.sender].isActive = false;
        users[msg.sender].reachedTotalLimit = true;
        
        // INTERACTIONS: External calls last
        require(usdt.transfer(msg.sender, pending), "Transfer failed");
        emit HourlyIncomeClaim(msg.sender, pending);
    }

        // MUTUAL EXCLUSION: User gets EITHER autopool OR ROI (CAPPED AT 1 HOUR)
    function _updateHourlyIncome(address userAddr) internal {
        User storage user = users[userAddr];
        
        // Only calculate for active users who are in autopool
        if (!user.isActive || user.reachedTotalLimit || !isAutopoolActive[userAddr]) return;
        
        // MUTUAL EXCLUSION: If user already has autopool income, NO ROI updates
        if (autopoolPendingBalance[userAddr] > 0) return;
        
        // Calculate hours since join/rejoin time
        uint256 hoursSinceJoin = (block.timestamp - user.lastJoinTime) / HOURLY_INCOME_INTERVAL;
        
        if (hoursSinceJoin >= 1) {
            // CRITICAL FIX: ROI stops after 1 hour - only give 12 USDT maximum
            uint256 roiAmount = HOURLY_INCOME; // Always 12 USDT (1 hour max)
            
            // Set pending amount (capped at 1 hour)
            hourlyIncomePending[userAddr] = roiAmount;
            
            // User automatically exits pool after getting ROI
            _removeUserFromAutopool(userAddr);
            
            emit HourlyIncomeAdd(userAddr, roiAmount, hourlyIncomePending[userAddr], block.timestamp);
        }
    }

    function _removeUserFromAutopool(address userAddr) internal {
        // Input validation
        if (userAddr == address(0) || !isAutopoolActive[userAddr]) return;
        
        address teamLeader = userTeamLeader[userAddr];
        if (teamLeader == address(0)) return;
        
        address[] storage queue = teamAutopoolQueue[teamLeader];
        if (queue.length == 0) return;
        
        // Find and remove user from queue with bounds checking
        bool userFound = false;
        for (uint256 i = 0; i < queue.length; i++) {
            if (queue[i] == userAddr) {
                userFound = true;
                // Shift remaining users up with proper bounds checking
                for (uint256 j = i; j < queue.length - 1; j++) {
                    require(j + 1 < queue.length, "Array bounds error");
                    queue[j] = queue[j + 1];
                    // Update position mapping safely
                    if (queue[j] != address(0)) {
                        autopoolPosition[queue[j]] = j;
                    }
                }
                // Safe array pop
                if (queue.length > 0) {
                    queue.pop();
                }
                break;
            }
        }
        
        // Only reset status if user was actually found and removed
        if (userFound) {
            isAutopoolActive[userAddr] = false;
            userTeamLeader[userAddr] = address(0);
            autopoolPosition[userAddr] = 0;
            users[userAddr].lastPoolJoinTime = 0;
            users[userAddr].lastHourlyUpdate = 0;
        }
    }

    // Recalculate direct referrals count for a user (used on rejoin)
    function _recalculateDirectReferrals(address userAddr) internal {
        if (userAddr == address(0)) return;
        
        address[] memory downlines = userDownlines[userAddr];
        users[userAddr].directReferrals = downlines.length;
    }
        
        // FIXED: Recalculate active directs for a user (used on rejoin) with gas limit protection
    function _recalculateActiveDirects(address userAddr) internal {
        if (userAddr == address(0)) return;
        
        users[userAddr].activeDirects = 0;
        address[] memory downlines = userDownlines[userAddr];
        
        // Prevent gas limit issues by capping the loop
        uint256 maxCheck = downlines.length > 100 ? 100 : downlines.length;
        
        for (uint256 i = 0; i < maxCheck; i++) {
            address direct = downlines[i];
            if (direct == address(0)) continue;
            
            // Active direct = user is active AND has at least 1 direct referral themselves
            if (users[direct].isActive && users[direct].directReferrals >= 1) {
                users[userAddr].activeDirects += 1;
            }
        }
    }
        
    // CRITICAL FIX: Properly validate user state when updating referrer's active direct count
    function _updateReferrerActiveDirects(address userAddr, bool isBecomingActive) internal {
        if (userAddr == address(0)) return;
        
        address referrer = users[userAddr].referrer;
        if (referrer == address(0) || referrer == admin) return;
        
        User memory user = users[userAddr];
        User storage referrerData = users[referrer];
        
        // CRITICAL: Only count as active direct if user is ACTUALLY active AND has >= 1 direct
        bool isQualifiedActiveDirectNow = user.isActive && user.directReferrals >= 1;
        
        if (isBecomingActive) {
            // User is becoming active - check if they qualify as active direct
            if (isQualifiedActiveDirectNow) {
                referrerData.activeDirects += 1;
            }
        } else {
            // User is becoming inactive - check if they were qualified before
            bool wasQualifiedBefore = user.directReferrals >= 1; // They had directs when active
            if (wasQualifiedBefore && referrerData.activeDirects > 0) {
                referrerData.activeDirects -= 1;
            }
        }
        
        // SAFETY: Ensure activeDirects never exceeds actual directReferrals
        if (referrerData.activeDirects > referrerData.directReferrals) {
            referrerData.activeDirects = referrerData.directReferrals;
        }
    }
    
    // Get user's pending hourly income (CAPPED AT 1 HOUR MAXIMUM)
    function getPendingHourlyIncome(address userAddr) external view returns (uint256) {
        User memory user = users[userAddr];
        
        // Only calculate for active users who are in autopool
        if (!user.isActive || user.reachedTotalLimit || !isAutopoolActive[userAddr]) {
            return hourlyIncomePending[userAddr];
        }
        
        // Don't give hourly income if user already earned pool commission
        if (autopoolPendingBalance[userAddr] > 0) {
            return hourlyIncomePending[userAddr];
        }
        
        // Calculate hours since join/rejoin time but CAP AT 1 HOUR
        uint256 hoursSinceJoin = (block.timestamp - user.lastJoinTime) / HOURLY_INCOME_INTERVAL;
        
        if (hoursSinceJoin >= 1) {
            // CRITICAL FIX: ROI stops after 1 hour - only give 1 hour worth (12 USDT max)
            return HOURLY_INCOME; // Always 12 USDT maximum (1 hour only)
        }
        
        return hourlyIncomePending[userAddr];
    }
    
    // REMOVED: Manual update function no longer needed - income calculates automatically from join time

    function _enterUserIntoAutopool(address userAddr) internal {
        if (!isAutopoolActive[userAddr]) {
        address teamLeader = _getTeamLeader(userAddr);
        userTeamLeader[userAddr] = teamLeader;
        teamAutopoolQueue[teamLeader].push(userAddr);
        autopoolPosition[userAddr] = teamAutopoolQueue[teamLeader].length - 1;
        isAutopoolActive[userAddr] = true;
            
            users[userAddr].lastPoolJoinTime = block.timestamp;
            // REMOVED: lastHourlyUpdate - now using lastJoinTime for automatic calculation
            
        processTeamAutopool(teamLeader);
        }
    }

    function _getTeamLeader(address userAddr) internal view returns (address) {
        address referrer = users[userAddr].referrer;
        if (referrer != address(0) && referrer != userAddr && users[referrer].isActive && referrer != admin) {
            return referrer;
        }
        return admin;
    }

    // CRITICAL FIX: Race condition protection + Gas-efficient autopool processing
    function processTeamAutopool(address teamLeader) internal {
        if (teamLeader == address(0)) return;
        
        // RACE CONDITION PROTECTION: Prevent concurrent processing
        if (autopoolProcessing[teamLeader]) return;
        autopoolProcessing[teamLeader] = true;
        
        address[] storage queue = teamAutopoolQueue[teamLeader];
        
        // Increment join count for this team leader
        teamJoinCount[teamLeader]++;
        
        // Trigger payout every 2 joins/rejoins (not based on queue size)
        if (teamJoinCount[teamLeader] % 2 == 0 && queue.length > 0) {
            address payoutUser = queue[0];
            if (payoutUser == address(0) || !isAutopoolActive[payoutUser]) {
                autopoolProcessing[teamLeader] = false;
                return;
            }
            
            // MUTUAL EXCLUSION: If user already has ROI income, NO autopool payout
            if (hourlyIncomePending[payoutUser] > 0) {
                autopoolProcessing[teamLeader] = false;
                return;
            }
            
            // ATOMIC STATE UPDATE: All changes happen together to prevent race conditions
            
            // 1. Pay the user
            autopoolPendingBalance[payoutUser] += AUTOPOOL_COMMISSION;
            autopoolTotalEarned[payoutUser] += AUTOPOOL_COMMISSION;
            
            // 2. GAS-EFFICIENT REMOVAL: Swap with last element (O(1) instead of O(n))
            uint256 queueLength = queue.length;
            if (queueLength > 1) {
                // Move last element to first position (no shifting needed)
                address lastUser = queue[queueLength - 1];
                queue[0] = lastUser;
                autopoolPosition[lastUser] = 0; // Update position of moved user
            }
            queue.pop(); // Remove last element
            
            // 3. Reset user's autopool status
            isAutopoolActive[payoutUser] = false;
            userTeamLeader[payoutUser] = address(0);
            autopoolPosition[payoutUser] = 0;
            users[payoutUser].lastPoolJoinTime = 0;
            users[payoutUser].lastHourlyUpdate = 0;
            
            // 4. Emit event after all state changes are complete
            emit PoolOut(payoutUser, teamLeader, AUTOPOOL_COMMISSION, teamJoinCount[teamLeader]);
        }
        
        // Release processing lock
        autopoolProcessing[teamLeader] = false;
    }

    // MIGRATION FUNCTIONS (keeping original migration logic)
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
            uint256 oldJoinCount, uint256 oldRejoinCount, bool oldIsActive, bool oldReachedTotalLimit, uint256 oldDirectReferrals
        ) {
            if (oldLastJoinTime == 0) return;
            
            address validatedReferrer = oldReferrer;
            if (oldReferrer != admin && oldReferrer != address(0)) {
                if (!hasBeenMigrated[oldReferrer] && !users[oldReferrer].isActive) {
                    validatedReferrer = admin;
                }
            }
            
            users[userAddr] = User({
                referrer: validatedReferrer,
                totalEarned: oldTotalEarned,
                lastJoinTime: oldLastJoinTime,
                joinCount: oldJoinCount,
                rejoinCount: oldRejoinCount,
                isActive: oldIsActive,
                reachedTotalLimit: oldReachedTotalLimit,
                directReferrals: 0, // RESET to 0 during migration (will restore on rejoin)
                lastPoolJoinTime: 0,
                lastHourlyUpdate: 0,
                activeDirects: 0
            });
            
            _newSetUserEarnings(userAddr);
            
            hasBeenMigrated[userAddr] = true;
            migratedUsers.push(userAddr);
            migratedUsersCount++;
            totalUsers++;
            
            emit Migrate(userAddr, validatedReferrer, oldDirectReferrals, oldTotalEarned);
        } catch {}
    }

    function _newSetUserEarnings(address userAddr) internal {
        try oldV12Contract.autopoolPendingBalance(userAddr) returns (uint256 balance) {
            autopoolPendingBalance[userAddr] = balance;
        } catch { 
            autopoolPendingBalance[userAddr] = 0; 
        }
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
        uint256 expectedDownlines = users[userAddr].directReferrals;
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
    }

    // EMERGENCY WITHDRAWAL FUNCTION
    function emergencyWithdrawAll() external onlyAdmin {
        uint256 contractBalance = usdt.balanceOf(address(this));
        require(contractBalance > 0, "No USDT to withdraw");
        require(usdt.transfer(admin, contractBalance), "Emergency withdrawal failed");
    }

    // UTILITY FUNCTIONS
    function getUserTotalPending(address userAddr) external view returns (
        uint256 autopoolPending,
        uint256 hourlyPending,
        uint256 totalPending
    ) {
        autopoolPending = autopoolPendingBalance[userAddr];
        hourlyPending = this.getPendingHourlyIncome(userAddr);
        totalPending = autopoolPending + hourlyPending;
    }
    
    function getContractStats() external view returns (
        uint256 totalUsersCount,
        uint256 totalFundsReceivedAmount, 
        uint256 totalPaidOutAmount,
        uint256 totalHourlyPaidAmount,
        uint256 contractBalance
    ) {
        return (
            totalUsers,
            totalFundsReceived,
            totalPaidOut,
            totalHourlyIncomePaid,
            usdt.balanceOf(address(this))
        );
    }
    
    function hasEnoughBalance() external view returns (bool) {
        return usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE;
    }
    
    function getQueueInfo(address teamLeader) external view returns (
        address[] memory queueMembers,
        uint256[] memory positions,
        uint256 queueLength
    ) {
        address[] memory queue = teamAutopoolQueue[teamLeader];
        uint256[] memory memberPositions = new uint256[](queue.length);
        
        for (uint256 i = 0; i < queue.length; i++) {
            memberPositions[i] = autopoolPosition[queue[i]];
        }
        
        return (queue, memberPositions, queue.length);
    }
    
    function getUserQueuePosition(address userAddr) external view returns (
        address teamLeader,
        uint256 position,
        uint256 queueLength,
        bool isInPool
    ) {
        address leader = userTeamLeader[userAddr];
        uint256 pos = autopoolPosition[userAddr];
        uint256 length = teamAutopoolQueue[leader].length;
        bool inPool = isAutopoolActive[userAddr];
        
        return (leader, pos, length, inPool);
    }
    
    function canUserJoinAutopool(address userAddr) external view returns (bool canJoin, string memory reason) {
        if (isAutopoolActive[userAddr]) {
            return (false, "Already in autopool");
        }
        if (!users[userAddr].isActive) {
            return (false, "User not active");
        }
        if (users[userAddr].reachedTotalLimit) {
            return (false, "User reached limit, must rejoin");
        }
        return (true, "Can join autopool");
    }

    // FIXED: Split into two functions to avoid stack too deep
    function getUserBasicInfo(address userAddr) external view returns (
        bool isActive,
        uint256 directReferrals,
        uint256 activeDirects,
        address referrer
    ) {
        User memory user = users[userAddr];
        return (
            user.isActive,
            user.directReferrals,
            user.activeDirects,
            user.referrer
        );
    }
    
    function getUserClaimInfo(address userAddr) external view returns (
        uint256 autopoolPending,
        uint256 hourlyPending,
        bool canClaimROI,
        bool canClaimAutopool,
        bool isInAutopool,
        uint256 timeInPool,
        string memory claimPriority
    ) {
        User memory user = users[userAddr];
        
        return (
            autopoolPendingBalance[userAddr],
            this.getPendingHourlyIncome(userAddr),
            this.getPendingHourlyIncome(userAddr) >= MIN_HOURLY_CLAIM && hasActiveDirectReferral(userAddr),
            autopoolPendingBalance[userAddr] >= MIN_CLAIM_AMOUNT && hasActiveDirectReferral(userAddr),
            isAutopoolActive[userAddr],
            user.lastPoolJoinTime > 0 ? block.timestamp - user.lastPoolJoinTime : 0,
            _getClaimPriority(userAddr)
        );
    }
    
    // Helper function to reduce stack depth
    function _getClaimPriority(address userAddr) internal view returns (string memory) {
        if (!hasActiveDirectReferral(userAddr)) {
            return "Need 1 active direct";
        }
        
        bool canClaimROI = this.getPendingHourlyIncome(userAddr) >= MIN_HOURLY_CLAIM;
        bool canClaimAutopool = autopoolPendingBalance[userAddr] >= MIN_CLAIM_AMOUNT;
        
        if (canClaimROI && canClaimAutopool) {
            return "Choose: Claim ROI OR autopool (both ready)";
        }
        if (canClaimROI) {
            return "Can claim ROI";
        }
        if (canClaimAutopool) {
            return "Can claim autopool";
        }
        return "No claimable amounts";
    }
    
    function getTeamJoinCount(address teamLeader) external view returns (uint256) {
        return teamJoinCount[teamLeader];
    }
    
    function getTeamAutopoolQueue(address teamLeader) external view returns (address[] memory) {
        return teamAutopoolQueue[teamLeader];
    }
}
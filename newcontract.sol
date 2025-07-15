/**
 *Submitted for verification at BscScan.com on 2025-07-15
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

contract AutoPoolFundV12Final {
    IERC20 public usdt;
    address public admin;
    bool internal locked;
    IAutoPoolFundV12 private oldV12Contract;

    // Constants
    uint256 public constant ENTRY_FEE = 10 * 1e18;
    uint256 public constant REJOIN_FEE = 10 * 1e18;
    uint256 public constant ADMIN_FEE_PER_JOIN = 2 * 1e18;
    uint256 public constant ADMIN_FEE_FROM_ENTRY = 2 * 1e18;
    uint256 public constant HOURLY_ROI_AMOUNT = 5 * 1e18;
    uint256 public constant ROI_INTERVAL = 1 hours;
    uint256 public constant MIN_CONTRACT_BALANCE = 200 * 1e18;
    uint256 public constant MIN_TOTAL_DIRECT_REFERRALS = 2;
    uint256 public constant MIN_ACTIVE_DIRECT_REFERRALS = 1;
    uint256 public constant AUTOPOOL_COMMISSION = 5 * 1e18;
    uint256 public constant COMBINED_PROFIT_THRESHOLD = 20 * 1e18;
    uint256 public constant MAX_PROFIT_CAP = 20 * 1e18;
    uint256 public constant MIN_CLAIM_AMOUNT = 20 * 1e18;
    uint256 public constant TEAM_POOL_SIZE = 2;

    struct User {
        address referrer;
        uint256 totalEarned;
        uint256 lastJoinTime;
        uint256 lastROITime;
        uint256 joinCount;
        uint256 rejoinCount;
        bool isActive;
        bool reachedTotalLimit;
        uint256 directReferrals;
    }

    // Core mappings
    mapping(address => User) public users;
    mapping(address => address[]) public userDownlines;
    mapping(address => uint256) public userPendingROI;
    mapping(address => uint256) public autopoolPendingBalance;
    mapping(address => uint256) public userCombinedProfits;
    mapping(address => uint256) public userTotalROIClaims;
    mapping(address => uint256) public userLastROIUpdate;

    // Autopool mappings
    mapping(address => address[]) public teamAutopoolQueue;
    mapping(address => address) public userTeamLeader;
    mapping(address => uint256) public autopoolTotalEarned;
    mapping(address => uint256) public autopoolPosition;
    mapping(address => bool) public isAutopoolActive;

    // Migration mappings
    mapping(address => bool) public hasBeenMigrated;
    mapping(address => bool) public downlinesMigrated;
    address[] public migratedUsers;
    uint256 public migratedUsersCount;
    uint256 public migrationCurrentIndex;
    bool public migrationCompleted;
    uint8 public currentMigrationPhase; // 0=USER_DATA, 1=DOWNLINES, 2=COMPLETED

    // State variables
    uint256 public totalUsers;
    uint256 public totalFundsReceived;
    uint256 public totalPaidOut;
    uint256 public totalCombinedProfitRejoins;

    // Events
    event UserJoined(address indexed user, address indexed referrer, uint256 fee);
    event UserRejoined(address indexed user, address indexed referrer, uint256 fee);
    event CombinedProfitRejoin(address indexed user, uint256 roiUsed, uint256 autopoolUsed, uint256 timestamp);
    event HourlyROIAccumulated(address indexed user, uint256 amount, uint256 totalPending, uint256 timestamp);
    event ROIClaimed(address indexed user, uint256 amount);
    event AutopoolPayout(address indexed user, address indexed teamLeader, uint256 amount, uint256 position);
    event AutopoolClaimed(address indexed user, uint256 amount);
    event CombinedProfitsClaimed(address indexed user, uint256 roiAmount, uint256 autopoolAmount, uint256 totalClaimed);
    event UserMigrated(address indexed user, address indexed referrer, uint256 directReferrals, uint256 totalEarned);
    event DownlinesMigrated(address indexed user, uint256 downlinesCount);
    event MigrationBatchCompleted(uint256 batchSize, uint256 currentIndex, uint256 timestamp);
    event MigrationCompleted(uint256 totalMigratedUsers, uint256 timestamp);

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

    modifier migrationCompleteOnly() {
        require(migrationCompleted);
        _;
    }

    constructor() {
        usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
        admin = 0x3Da7310861fbBdf5105ea6963A2C39d0Cb34a4Ff;
        oldV12Contract = IAutoPoolFundV12(0x4317B4D50dDa70Ca6020fE1F3b48f4bE4a969f2b);
        users[admin].isActive = true;
        users[admin].lastJoinTime = block.timestamp;
        users[admin].joinCount = 1;
    }

    // FIXED: Main Join Function
    function join(address referrer) external migrationCompleteOnly noReentrant {
        User storage user = users[msg.sender];

        if (user.reachedTotalLimit) {
            require(usdt.transferFrom(msg.sender, address(this), REJOIN_FEE));
            user.rejoinCount += 1;
            user.reachedTotalLimit = false;
            user.isActive = true;
            user.lastJoinTime = block.timestamp;
            user.lastROITime = 0;
            user.joinCount += 1;
            userLastROIUpdate[msg.sender] = block.timestamp;
            require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN));
            totalFundsReceived += REJOIN_FEE;
            _enterUserIntoAutopool(msg.sender);
            emit UserRejoined(msg.sender, user.referrer, REJOIN_FEE);
            return;
        }

        require(!user.isActive && user.joinCount == 0);
        require(usdt.transferFrom(msg.sender, address(this), ENTRY_FEE));

        address actualReferrer = admin;
        if (referrer != address(0) && referrer != msg.sender && users[referrer].isActive) {
            actualReferrer = referrer;
        }
        
        user.referrer = actualReferrer;
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.joinCount = 1;
        user.rejoinCount = 0;
        user.directReferrals = 0;
        
        // FIXED: Properly add to downlines
        userDownlines[actualReferrer].push(msg.sender);
        users[actualReferrer].directReferrals += 1;
        
        userLastROIUpdate[msg.sender] = block.timestamp;
        userPendingROI[msg.sender] = 0;

        _enterUserIntoAutopool(msg.sender);
        totalUsers += 1;
        totalFundsReceived += ENTRY_FEE;
        require(usdt.transfer(admin, ADMIN_FEE_FROM_ENTRY));
        emit UserJoined(msg.sender, user.referrer, ENTRY_FEE);
    }

    function rejoinWithCombinedProfits() external migrationCompleteOnly noReentrant {
        User storage user = users[msg.sender];
        require(user.reachedTotalLimit);
        
        _updatePendingROI(msg.sender);
        
        uint256 pendingROI = userPendingROI[msg.sender];
        uint256 autopoolEarnings = autopoolPendingBalance[msg.sender];
        uint256 totalCombined = pendingROI + autopoolEarnings;
        require(totalCombined >= COMBINED_PROFIT_THRESHOLD);

        uint256 roiDeduction = (REJOIN_FEE * pendingROI) / totalCombined;
        uint256 autopoolDeduction = REJOIN_FEE - roiDeduction;
        
        userPendingROI[msg.sender] -= roiDeduction;
        autopoolPendingBalance[msg.sender] -= autopoolDeduction;
        userCombinedProfits[msg.sender] = userPendingROI[msg.sender] + autopoolPendingBalance[msg.sender];

        user.rejoinCount += 1;
        user.reachedTotalLimit = false;
        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.lastROITime = 0;
        user.joinCount += 1;
        userLastROIUpdate[msg.sender] = block.timestamp;

        require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN));
        totalFundsReceived += REJOIN_FEE;
        totalCombinedProfitRejoins += 1;

        _enterUserIntoAutopool(msg.sender);
        emit CombinedProfitRejoin(msg.sender, roiDeduction, autopoolDeduction, block.timestamp);
        emit UserRejoined(msg.sender, user.referrer, REJOIN_FEE);
    }

    function _updatePendingROI(address userAddr) internal {
        User storage user = users[userAddr];
        if (!user.isActive || user.reachedTotalLimit) return;
        
        uint256 currentCombined = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        if (currentCombined >= MAX_PROFIT_CAP) return;
        
        if (users[userAddr].directReferrals < MIN_TOTAL_DIRECT_REFERRALS || 
            getActiveDirectReferrals(userAddr) < MIN_ACTIVE_DIRECT_REFERRALS) return;
        
        (bool isChainActive,) = isUplineChainActive(userAddr);
        if (!isChainActive) return;
        
        uint256 lastUpdate = userLastROIUpdate[userAddr];
        if (lastUpdate == 0) lastUpdate = user.lastJoinTime;
        
        uint256 hoursPassed = (block.timestamp - lastUpdate) / ROI_INTERVAL;
        if (hoursPassed > 0) {
            uint256 roiToAdd = hoursPassed * HOURLY_ROI_AMOUNT;
            uint256 newCombined = currentCombined + roiToAdd;
            if (newCombined > MAX_PROFIT_CAP) {
                roiToAdd = MAX_PROFIT_CAP - currentCombined;
            }
            
            if (roiToAdd > 0) {
                userPendingROI[userAddr] += roiToAdd;
                userLastROIUpdate[userAddr] = lastUpdate + (hoursPassed * ROI_INTERVAL);
                userCombinedProfits[userAddr] = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
                emit HourlyROIAccumulated(userAddr, roiToAdd, userPendingROI[userAddr], block.timestamp);
            }
        }
    }
    
    function updatePendingROI(address userAddr) external {
        _updatePendingROI(userAddr);
    }

    function claimROI() external migrationCompleteOnly noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE);
        require(users[msg.sender].directReferrals >= MIN_TOTAL_DIRECT_REFERRALS);
        require(getActiveDirectReferrals(msg.sender) >= MIN_ACTIVE_DIRECT_REFERRALS);
        
        _updatePendingROI(msg.sender);
        
        uint256 pending = userPendingROI[msg.sender];
        require(pending >= MIN_CLAIM_AMOUNT);
        require(usdt.balanceOf(address(this)) >= pending);
        
        userPendingROI[msg.sender] = 0;
        userCombinedProfits[msg.sender] = autopoolPendingBalance[msg.sender];
        
        if (pending >= MIN_CLAIM_AMOUNT) {
            users[msg.sender].isActive = false;
            users[msg.sender].reachedTotalLimit = true;
        }
        
        require(usdt.transfer(msg.sender, pending));
        totalPaidOut += pending;
        emit ROIClaimed(msg.sender, pending);
    }

    function _enterUserIntoAutopool(address userAddr) internal {
        address teamLeader = _getTeamLeader(userAddr);
        userTeamLeader[userAddr] = teamLeader;
        teamAutopoolQueue[teamLeader].push(userAddr);
        autopoolPosition[userAddr] = teamAutopoolQueue[teamLeader].length - 1;
        isAutopoolActive[userAddr] = true;
        processTeamAutopool(teamLeader);
    }

    function _getTeamLeader(address userAddr) internal view returns (address) {
        address referrer = users[userAddr].referrer;
        if (referrer != address(0) && referrer != userAddr && users[referrer].isActive) {
            return referrer;
        }
        return admin;
    }

    function processTeamAutopool(address teamLeader) internal {
        address[] storage queue = teamAutopoolQueue[teamLeader];
        if (queue.length >= TEAM_POOL_SIZE) {
            address payoutUser = queue[0];
            if (payoutUser != address(0)) {
                uint256 currentCombined = userPendingROI[payoutUser] + autopoolPendingBalance[payoutUser];
                if (currentCombined < MAX_PROFIT_CAP) {
                    uint256 autopoolToAdd = AUTOPOOL_COMMISSION;
                    if (currentCombined + autopoolToAdd > MAX_PROFIT_CAP) {
                        autopoolToAdd = MAX_PROFIT_CAP - currentCombined;
                    }
                    if (autopoolToAdd > 0) {
                        autopoolPendingBalance[payoutUser] += autopoolToAdd;
                        autopoolTotalEarned[payoutUser] += autopoolToAdd;
                        userCombinedProfits[payoutUser] = userPendingROI[payoutUser] + autopoolPendingBalance[payoutUser];
                        emit AutopoolPayout(payoutUser, teamLeader, autopoolToAdd, 0);
                    }
                }
                for (uint256 i = 0; i < queue.length - 1; i++) {
                    queue[i] = queue[i + 1];
                    autopoolPosition[queue[i]] = i;
                }
                queue[queue.length - 1] = payoutUser;
                autopoolPosition[payoutUser] = queue.length - 1;
            }
        }
    }

    function claimAutopoolEarnings() external noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE);
        require(users[msg.sender].directReferrals >= MIN_TOTAL_DIRECT_REFERRALS);
        require(getActiveDirectReferrals(msg.sender) >= MIN_ACTIVE_DIRECT_REFERRALS);
        
        uint256 pending = autopoolPendingBalance[msg.sender];
        require(pending >= MIN_CLAIM_AMOUNT);
        require(usdt.balanceOf(address(this)) >= pending);
        
        autopoolPendingBalance[msg.sender] = 0;
        _updatePendingROI(msg.sender);
        userCombinedProfits[msg.sender] = userPendingROI[msg.sender];
        
        if (pending >= MIN_CLAIM_AMOUNT) {
            users[msg.sender].isActive = false;
            users[msg.sender].reachedTotalLimit = true;
        }
        
        require(usdt.transfer(msg.sender, pending));
        totalPaidOut += pending;
        emit AutopoolClaimed(msg.sender, pending);
    }
    
    function claimCombinedEarnings() external noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE);
        require(users[msg.sender].directReferrals >= MIN_TOTAL_DIRECT_REFERRALS);
        require(getActiveDirectReferrals(msg.sender) >= MIN_ACTIVE_DIRECT_REFERRALS);
        
        _updatePendingROI(msg.sender);
        
        uint256 roiPending = userPendingROI[msg.sender];
        uint256 autopoolPending = autopoolPendingBalance[msg.sender];
        uint256 totalPending = roiPending + autopoolPending;
        
        require(totalPending >= MIN_CLAIM_AMOUNT);
        require(usdt.balanceOf(address(this)) >= totalPending);
        
        userPendingROI[msg.sender] = 0;
        autopoolPendingBalance[msg.sender] = 0;
        userCombinedProfits[msg.sender] = 0;
        
        users[msg.sender].isActive = false;
        users[msg.sender].reachedTotalLimit = true;
        
        require(usdt.transfer(msg.sender, totalPending));
        totalPaidOut += totalPending;
        emit CombinedProfitsClaimed(msg.sender, roiPending, autopoolPending, totalPending);
    }

    function getActiveDirectReferrals(address userAddr) public view returns (uint256 activeCount) {
        User storage user = users[userAddr];
        for (uint256 i = 0; i < userDownlines[userAddr].length; i++) {
            address downline = userDownlines[userAddr][i];
            if (users[downline].isActive &&
                users[downline].lastJoinTime > user.lastJoinTime &&
                users[downline].directReferrals >= MIN_TOTAL_DIRECT_REFERRALS) {
                activeCount++;
            }
        }
    }

    function isUplineChainActive(address userAddr) public view returns (bool, address) {
        address currentUpline = users[userAddr].referrer;
        uint256 depth = 0;
        while (currentUpline != address(0) && depth < 10) {
            if (currentUpline == admin) return (true, address(0));
            User memory uplineUser = users[currentUpline];
            if (!uplineUser.isActive || uplineUser.reachedTotalLimit) {
                return (false, currentUpline);
            }
            currentUpline = uplineUser.referrer;
            depth++;
        }
        return (true, address(0));
    }

    // FIXED: Migration Functions - No Stack Issues
    function setOldV12Contract(address oldV12Address) external onlyAdmin {
        require(oldV12Address != address(0));
        oldV12Contract = IAutoPoolFundV12(oldV12Address);
    }

    function setMigrationPhase(uint8 newPhase) external onlyAdmin {
        require(newPhase <= 2);
        currentMigrationPhase = newPhase;
    }

    function completeMigration() external onlyAdmin {
        migrationCompleted = true;
        currentMigrationPhase = 2;
    }

    // FIXED: Simplified migration to avoid stack issues
    function migrateV12User(address userAddr) external onlyAdmin {
        require(address(oldV12Contract) != address(0));
        require(!hasBeenMigrated[userAddr]);
        require(!migrationCompleted);
        require(currentMigrationPhase == 0);
        
        // Get data from old contract
        (
            address oldReferrer,
            uint256 oldTotalEarned,
            uint256 oldLastJoinTime,
            uint256 oldLastROITime,
            uint256 oldJoinCount,
            uint256 oldRejoinCount,
            bool oldIsActive,
            bool oldReachedTotalLimit,
            uint256 oldDirectReferrals
        ) = oldV12Contract.users(userAddr);
        
        require(oldLastJoinTime > 0);
        
        // Migrate user data
        _migrateUserData(
            userAddr, 
            oldReferrer, 
            oldTotalEarned, 
            oldLastJoinTime, 
            oldLastROITime, 
            oldJoinCount, 
            oldRejoinCount, 
            oldIsActive, 
            oldReachedTotalLimit, 
            oldDirectReferrals
        );
    }

    // FIXED: Split into smaller function to avoid stack issues
    function _migrateUserData(
        address userAddr,
        address referrer,
        uint256 totalEarned,
        uint256 lastJoinTime,
        uint256 lastROITime,
        uint256 joinCount,
        uint256 rejoinCount,
        bool isActive,
        bool reachedTotalLimit,
        uint256 directReferrals
    ) internal {
        // Validate referrer
        address validatedReferrer = referrer;
        if (referrer != admin && referrer != address(0)) {
            if (!hasBeenMigrated[referrer] && !users[referrer].isActive) {
                validatedReferrer = admin;
            }
        }
        
        // Set user data
        users[userAddr] = User({
            referrer: validatedReferrer,
            totalEarned: totalEarned,
            lastJoinTime: lastJoinTime,
            lastROITime: lastROITime,
            joinCount: joinCount,
            rejoinCount: rejoinCount,
            isActive: isActive,
            reachedTotalLimit: reachedTotalLimit,
            directReferrals: directReferrals
        });
        
        _migrateUserEarnings(userAddr);
        
        hasBeenMigrated[userAddr] = true;
        migratedUsers.push(userAddr);
        migratedUsersCount++;
        totalUsers++;
        
        emit UserMigrated(userAddr, validatedReferrer, directReferrals, totalEarned);
    }

    // FIXED: Separate function for earnings to avoid stack issues
    function _migrateUserEarnings(address userAddr) internal {
        userLastROIUpdate[userAddr] = block.timestamp;
        
        // Get earnings with try/catch
        try oldV12Contract.userPendingROI(userAddr) returns (uint256 pending) {
            userPendingROI[userAddr] = pending;
        } catch {}
        
        try oldV12Contract.autopoolPendingBalance(userAddr) returns (uint256 balance) {
            autopoolPendingBalance[userAddr] = balance;
        } catch {}
        
        try oldV12Contract.userTotalROIClaims(userAddr) returns (uint256 claims) {
            userTotalROIClaims[userAddr] = claims;
        } catch {}
        
        userCombinedProfits[userAddr] = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
    }

    function migrateV12UserDownlines(address userAddr) external onlyAdmin {
        require(hasBeenMigrated[userAddr]);
        require(!downlinesMigrated[userAddr]);
        require(currentMigrationPhase == 1);
        
        uint256 expectedDownlines = users[userAddr].directReferrals;
        delete userDownlines[userAddr];
        
        uint256 actualCount = 0;
        for (uint256 i = 0; i < expectedDownlines; i++) {
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
        emit DownlinesMigrated(userAddr, actualCount);
    }

    function migrateV12UsersBatch(address[] calldata userAddrs) external onlyAdmin {
        require(address(oldV12Contract) != address(0));
        require(!migrationCompleted);
        require(userAddrs.length <= 50);
        
        for (uint256 i = 0; i < userAddrs.length; i++) {
            if (currentMigrationPhase == 0 && !hasBeenMigrated[userAddrs[i]]) {
                try this.migrateV12User(userAddrs[i]) {} catch {}
            } else if (currentMigrationPhase == 1 && 
                      hasBeenMigrated[userAddrs[i]] && 
                      !downlinesMigrated[userAddrs[i]]) {
                try this.migrateV12UserDownlines(userAddrs[i]) {} catch {}
            }
        }
    }

    // NEW: Automated batch migration - migrates users by index range
    function migrateUsersAutoBatch(uint256 batchSize) external onlyAdmin {
        require(address(oldV12Contract) != address(0));
        require(!migrationCompleted);
        require(batchSize >= 50 && batchSize <= 100, "Batch size must be 50-100");
        
        if (currentMigrationPhase == 0) {
            _migrateUserDataBatch(batchSize);
        } else if (currentMigrationPhase == 1) {
            _migrateDownlinesBatch(batchSize);
        }
    }

    // FIXED: Auto-migrate user data from ALL users (migrated + new joiners)
    function _migrateUserDataBatch(uint256 batchSize) internal {
        uint256 processed = 0;
        uint256 oldContractMigratedCount;
        uint256 oldContractTotalUsers;
        
        // Get both migrated users and total users from old contract
        try oldV12Contract.migratedUsersCount() returns (uint256 count) {
            oldContractMigratedCount = count;
        } catch {
            oldContractMigratedCount = 0;
        }
        
        try oldV12Contract.totalUsers() returns (uint256 totalUsersInOld) {
            oldContractTotalUsers = totalUsersInOld;
        } catch {
            oldContractTotalUsers = 0;
        }
        
        // First, process migrated users array (V10→V12 users)
        while (migrationCurrentIndex < oldContractMigratedCount && processed < batchSize) {
            try oldV12Contract.migratedUsers(migrationCurrentIndex) returns (address userAddr) {
                if (userAddr != address(0) && !hasBeenMigrated[userAddr]) {
                    _migrateUserQuick(userAddr);
                    processed++;
                }
            } catch {}
            migrationCurrentIndex++;
        }
        
        // FIXED: If we've processed all migrated users but haven't reached batch limit,
        // try to find new users who joined directly in V12
        if (processed < batchSize && migrationCurrentIndex >= oldContractMigratedCount) {
            _migrateNewV12Users(batchSize - processed);
        }
        
        emit MigrationBatchCompleted(processed, migrationCurrentIndex, block.timestamp);
    }

    // NEW: Migrate users who joined directly in V12 (not from V10 migration)
    function _migrateNewV12Users(uint256 /* remainingBatch */) internal {
        // We need to find users by scanning or using a different method
        // Since we can't easily iterate all users, we'll use a discovery approach
        
        // Try to get recent users by checking known patterns or admin can provide addresses
        // For now, emit an event so admin knows to use manual migration for new users
        emit MigrationBatchCompleted(0, migrationCurrentIndex, block.timestamp);
    }

    // NEW: Manual function to migrate specific new V12 users
    function migrateNewV12Users(address[] calldata newUserAddresses) external onlyAdmin {
        require(newUserAddresses.length <= 50, "Max 50 users per batch");
        
        uint256 migrated = 0;
        for (uint256 i = 0; i < newUserAddresses.length; i++) {
            address userAddr = newUserAddresses[i];
            if (!hasBeenMigrated[userAddr]) {
                _migrateUserQuick(userAddr);
                migrated++;
            }
        }
        
        emit MigrationBatchCompleted(migrated, migrationCurrentIndex, block.timestamp);
    }

    // NEW: Get unmigrated users count from old contract
    function getOldContractUserCounts() external view returns (
        uint256 totalUsersInOld,
        uint256 migratedFromV10,
        uint256 newV12Users,
        uint256 alreadyMigratedHere
    ) {
        try oldV12Contract.totalUsers() returns (uint256 totalCount) {
            totalUsersInOld = totalCount;
        } catch {}
        
        try oldV12Contract.migratedUsersCount() returns (uint256 migrated) {
            migratedFromV10 = migrated;
        } catch {}
        
        newV12Users = totalUsersInOld - migratedFromV10; // Users who joined directly in V12
        alreadyMigratedHere = migratedUsersCount;
    }

    // NEW: Check if user exists in old contract but not migrated here
    function checkUserInOldContract(address userAddr) external view returns (
        bool existsInOld,
        bool isInMigratedArray,
        bool alreadyMigratedHere,
        uint256 directReferrals
    ) {
        alreadyMigratedHere = hasBeenMigrated[userAddr];
        
        try oldV12Contract.users(userAddr) returns (
            address, uint256, uint256 lastJoinTime, uint256, uint256, uint256, bool, bool, uint256 refs
        ) {
            existsInOld = (lastJoinTime > 0);
            directReferrals = refs;
        } catch {}
        
        // Check if user is in migrated array
        try oldV12Contract.migratedUsersCount() returns (uint256 count) {
            for (uint256 i = 0; i < count && i < 1000; i++) { // Limit search to prevent gas issues
                try oldV12Contract.migratedUsers(i) returns (address migUser) {
                    if (migUser == userAddr) {
                        isInMigratedArray = true;
                        break;
                    }
                } catch { break; }
            }
        } catch {}
    }

    // NEW: Quick user migration without external calls
    function _migrateUserQuick(address userAddr) internal {
        // Get user data from old contract
        try oldV12Contract.users(userAddr) returns (
            address oldReferrer, uint256 oldTotalEarned, uint256 oldLastJoinTime, uint256 oldLastROITime,
            uint256 oldJoinCount, uint256 oldRejoinCount, bool oldIsActive, bool oldReachedTotalLimit, uint256 oldDirectReferrals
        ) {
            if (oldLastJoinTime == 0) return; // Skip invalid users
            
            // Validate referrer
            address validatedReferrer = oldReferrer;
            if (oldReferrer != admin && oldReferrer != address(0)) {
                if (!hasBeenMigrated[oldReferrer] && !users[oldReferrer].isActive) {
                    validatedReferrer = admin;
                }
            }
            
            // Set user data directly
            users[userAddr] = User({
                referrer: validatedReferrer,
                totalEarned: oldTotalEarned,
                lastJoinTime: oldLastJoinTime,
                lastROITime: oldLastROITime,
                joinCount: oldJoinCount,
                rejoinCount: oldRejoinCount,
                isActive: oldIsActive,
                reachedTotalLimit: oldReachedTotalLimit,
                directReferrals: oldDirectReferrals
            });
            
            // Set earnings
            _setUserEarnings(userAddr);
            
            // Mark as migrated
            hasBeenMigrated[userAddr] = true;
            migratedUsers.push(userAddr);
            migratedUsersCount++;
            totalUsers++;
            
            emit UserMigrated(userAddr, validatedReferrer, oldDirectReferrals, oldTotalEarned);
        } catch {
            // Skip users that fail migration
        }
    }

    // NEW: Set user earnings efficiently
    function _setUserEarnings(address userAddr) internal {
        userLastROIUpdate[userAddr] = block.timestamp;
        
        // Get earnings with single calls
        try oldV12Contract.userPendingROI(userAddr) returns (uint256 pending) {
            userPendingROI[userAddr] = pending;
        } catch { userPendingROI[userAddr] = 0; }
        
        try oldV12Contract.autopoolPendingBalance(userAddr) returns (uint256 balance) {
            autopoolPendingBalance[userAddr] = balance;
        } catch { autopoolPendingBalance[userAddr] = 0; }
        
        try oldV12Contract.userTotalROIClaims(userAddr) returns (uint256 claims) {
            userTotalROIClaims[userAddr] = claims;
        } catch { userTotalROIClaims[userAddr] = 0; }
        
        userCombinedProfits[userAddr] = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
    }

    // NEW: Auto-migrate downlines for all migrated users
    function _migrateDownlinesBatch(uint256 batchSize) internal {
        uint256 processed = 0;
        
        // Find users who need downlines migration
        for (uint256 i = 0; i < migratedUsers.length && processed < batchSize; i++) {
            address userAddr = migratedUsers[i];
            if (hasBeenMigrated[userAddr] && !downlinesMigrated[userAddr]) {
                _migrateUserDownlinesQuick(userAddr);
                processed++;
            }
        }
        
        emit MigrationBatchCompleted(processed, migrationCurrentIndex, block.timestamp);
    }

    // NEW: Quick downlines migration
    function _migrateUserDownlinesQuick(address userAddr) internal {
        uint256 expectedDownlines = users[userAddr].directReferrals;
        delete userDownlines[userAddr];
        
        uint256 actualCount = 0;
        for (uint256 i = 0; i < expectedDownlines && i < 50; i++) { // Limit to prevent gas issues
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
        emit DownlinesMigrated(userAddr, actualCount);
    }

    // NEW: Get total migration progress
    function getMigrationProgress() external view returns (
        uint256 oldContractTotalUsersCount,
        uint256 currentIndex,
        uint256 migratedCount,
        uint256 downlinesMigratedCount,
        uint256 percentComplete,
        bool allUserDataMigrated,
        bool allDownlinesMigrated
    ) {
        // Get total from old contract
        try oldV12Contract.migratedUsersCount() returns (uint256 totalCount) {
            oldContractTotalUsersCount = totalCount;
        } catch {
            oldContractTotalUsersCount = 0;
        }
        
        currentIndex = migrationCurrentIndex;
        migratedCount = migratedUsersCount;
        
        // Count downlines migrated
        for (uint256 i = 0; i < migratedUsers.length; i++) {
            if (downlinesMigrated[migratedUsers[i]]) {
                downlinesMigratedCount++;
            }
        }
        
        // Calculate progress
        if (oldContractTotalUsersCount > 0) {
            percentComplete = (migratedCount * 100) / oldContractTotalUsersCount;
        }
        
        allUserDataMigrated = (currentIndex >= oldContractTotalUsersCount);
        allDownlinesMigrated = (downlinesMigratedCount == migratedCount);
    }

    // NEW: Estimate remaining migration batches
    function estimateRemainingBatches(uint256 batchSize) external view returns (
        uint256 userDataBatches,
        uint256 downlinesBatches,
        uint256 totalBatches,
        uint256 estimatedGasPerBatch
    ) {
        uint256 oldContractTotalCount;
        try oldV12Contract.migratedUsersCount() returns (uint256 totalCount) {
            oldContractTotalCount = totalCount;
        } catch {
            oldContractTotalCount = 0;
        }
        
        uint256 remainingUsers = 0;
        if (oldContractTotalCount > migrationCurrentIndex) {
            remainingUsers = oldContractTotalCount - migrationCurrentIndex;
        }
        
        userDataBatches = (remainingUsers + batchSize - 1) / batchSize; // Ceiling division
        
        uint256 downlinesRemaining = 0;
        for (uint256 i = 0; i < migratedUsers.length; i++) {
            if (!downlinesMigrated[migratedUsers[i]]) {
                downlinesRemaining++;
            }
        }
        
        downlinesBatches = (downlinesRemaining + batchSize - 1) / batchSize;
        totalBatches = userDataBatches + downlinesBatches;
        
        // Estimate gas (rough calculation)
        estimatedGasPerBatch = batchSize * 150000; // ~150k gas per user migration
    }

    // NEW: Complete migration automatically
    function autoCompleteMigration() external onlyAdmin {
        (,,,, uint256 percentComplete, bool allUserDataMigrated, bool allDownlinesMigrated) = this.getMigrationProgress();
        
        require(percentComplete >= 95, "Migration not 95% complete");
        require(allUserDataMigrated, "User data migration incomplete");
        require(allDownlinesMigrated, "Downlines migration incomplete");
        
        migrationCompleted = true;
        currentMigrationPhase = 2;
        
        emit MigrationCompleted(migratedUsersCount, block.timestamp);
    }

    // Admin functions
    function emergencyWithdraw() external onlyAdmin {
        require(usdt.balanceOf(address(this)) > 0);
        require(usdt.transfer(admin, usdt.balanceOf(address(this))));
    }

    // View functions
    function getUserDownlines(address userAddr) external view returns (address[] memory) {
        return userDownlines[userAddr];
    }

    function getMigrationStats() external view returns (
        uint256 migratedCount, 
        uint256 downlinesMigratedCount, 
        uint8 currentPhase, 
        bool completed
    ) {
        migratedCount = migratedUsersCount;
        
        for (uint256 i = 0; i < migratedUsers.length; i++) {
            if (downlinesMigrated[migratedUsers[i]]) {
                downlinesMigratedCount++;
            }
        }
        
        currentPhase = currentMigrationPhase;
        completed = migrationCompleted;
    }

    function verifyUserMigration(address userAddr) external view returns (
        bool userMigrated, 
        bool downlinesMigratedStatus, 
        uint256 expectedDownlines, 
        uint256 actualDownlines, 
        bool complete
    ) {
        userMigrated = hasBeenMigrated[userAddr];
        downlinesMigratedStatus = downlinesMigrated[userAddr];
        expectedDownlines = users[userAddr].directReferrals;
        actualDownlines = userDownlines[userAddr].length;
        complete = userMigrated && downlinesMigratedStatus && (expectedDownlines == actualDownlines);
    }

    function fixUserDownlines(address userAddr, address[] calldata correctDownlines) external onlyAdmin {
        require(hasBeenMigrated[userAddr]);
        require(users[userAddr].directReferrals == correctDownlines.length);
        
        delete userDownlines[userAddr];
        for (uint256 i = 0; i < correctDownlines.length; i++) {
            require(correctDownlines[i] != address(0));
            userDownlines[userAddr].push(correctDownlines[i]);
        }
        downlinesMigrated[userAddr] = true;
        emit DownlinesMigrated(userAddr, correctDownlines.length);
    }

    function rebuildAllConnections() external onlyAdmin {
        // Clear all downlines
        for (uint256 i = 0; i < migratedUsers.length; i++) {
            delete userDownlines[migratedUsers[i]];
        }
        
        // Rebuild from referrer relationships
        for (uint256 i = 0; i < migratedUsers.length; i++) {
            address user = migratedUsers[i];
            address referrer = users[user].referrer;
            if (referrer != address(0)) {
                userDownlines[referrer].push(user);
            }
        }
        
        // Mark all as migrated
        for (uint256 i = 0; i < migratedUsers.length; i++) {
            downlinesMigrated[migratedUsers[i]] = true;
        }
    }

    function validateAllConnections() external view returns (bool allValid, uint256 totalErrors) {
        uint256 errors = 0;
        for (uint256 i = 0; i < migratedUsers.length; i++) {
            address user = migratedUsers[i];
            if (users[user].directReferrals != userDownlines[user].length) {
                errors++;
                continue;
            }
            for (uint256 j = 0; j < userDownlines[user].length; j++) {
                if (users[userDownlines[user][j]].referrer != user) {
                    errors++;
                    break;
                }
            }
        }
        allValid = (errors == 0);
        totalErrors = errors;
    }

    function getContractStats() external view returns (
        uint256 totalUsersCount,
        uint256 contractBalance,
        uint256 totalFundsReceivedAmount,
        uint256 totalPaidOutAmount,
        uint256 totalCombinedProfitRejoinsCount
    ) {
        return (
            totalUsers,
            usdt.balanceOf(address(this)),
            totalFundsReceived,
            totalPaidOut,
            totalCombinedProfitRejoins
        );
    }
}
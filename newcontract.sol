/**
 *Submitted for verification at BscScan.com on 2025-07-16
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
    IAutoPoolFundV12 private secondV12Contract;

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
    uint256 public constant DAILY_SALARY = 50 * 1e18;
    uint256 public constant SALARY_INTERVAL = 24 hours;
    uint256 public constant SALARY_REJOIN_REQUIREMENT = 50;

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
        uint256 lastSalaryUpdate;
        bool salaryEnabled;
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

    // Salary mappings
    mapping(address => uint256) public pendingSalary;
    uint256 public salaryEligibleUsers;
    uint256 public totalSalaryPaid;

    // State variables
    uint256 public totalUsers;
    uint256 public totalFundsReceived;
    uint256 public totalPaidOut;
    uint256 public totalCombinedProfitRejoins;

    event Join(address indexed user, address indexed referrer, uint256 fee);
    event Rejoin(address indexed user, address indexed referrer, uint256 fee);
    event CombRejoin(address indexed user, uint256 roi, uint256 pool, uint256 time);
    event ROIAdd(address indexed user, uint256 amount, uint256 total, uint256 time);
    event ROIOut(address indexed user, uint256 amount);
    event PoolOut(address indexed user, address indexed leader, uint256 amount, uint256 pos);
    event PoolClaim(address indexed user, uint256 amount);
    event CombClaim(address indexed user, uint256 roi, uint256 pool, uint256 total);
    event Migrate(address indexed user, address indexed referrer, uint256 dirs, uint256 earned);
    event DownMigrate(address indexed user, uint256 count);
    event BatchDone(uint256 batch, uint256 index, uint256 time);
    event MigrateDone(uint256 total, uint256 time);
    event SalaryOn(address indexed user, uint256 rejoins, uint256 time);
    event SalaryAdd(address indexed user, uint256 amount, uint256 total, uint256 time);
    event SalaryOut(address indexed user, uint256 amount);

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
        oldV12Contract = IAutoPoolFundV12(0x4317B4D50dDa70Ca6020fE1F3b48f4bE4a969f2b);
        secondV12Contract = IAutoPoolFundV12(0x34b93858ee0eE4144aA6B2d894e72B36E232a465);
        users[admin].isActive = true;
        users[admin].lastJoinTime = block.timestamp;
        users[admin].joinCount = 1;
    }

    // Join Function
    function join(address referrer) external postMigration noReentrant {
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
            
            // Enable salary if user reaches 50 rejoins
            if (user.rejoinCount >= SALARY_REJOIN_REQUIREMENT && !user.salaryEnabled) {
                user.salaryEnabled = true;
                user.lastSalaryUpdate = block.timestamp;
                salaryEligibleUsers++;
                emit SalaryOn(msg.sender, user.rejoinCount, block.timestamp);
            }
            
            require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN));
            totalFundsReceived += REJOIN_FEE;
            _enterUserIntoAutopool(msg.sender);
            emit Rejoin(msg.sender, user.referrer, REJOIN_FEE);
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
        user.lastSalaryUpdate = 0;
        user.salaryEnabled = false;
        
        // Add to downlines
        userDownlines[actualReferrer].push(msg.sender);
        users[actualReferrer].directReferrals += 1;
        
        userLastROIUpdate[msg.sender] = block.timestamp;
        userPendingROI[msg.sender] = 0;

        _enterUserIntoAutopool(msg.sender);
        totalUsers += 1;
        totalFundsReceived += ENTRY_FEE;
        require(usdt.transfer(admin, ADMIN_FEE_FROM_ENTRY));
        emit Join(msg.sender, user.referrer, ENTRY_FEE);
    }

    function rejoinWithCombinedProfits() external postMigration noReentrant {
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

        // Enable salary if user reaches 50 rejoins
        if (user.rejoinCount >= SALARY_REJOIN_REQUIREMENT && !user.salaryEnabled) {
            user.salaryEnabled = true;
            user.lastSalaryUpdate = block.timestamp;
            salaryEligibleUsers++;
            emit SalaryOn(msg.sender, user.rejoinCount, block.timestamp);
        }

        require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN));
        totalFundsReceived += REJOIN_FEE;
        totalCombinedProfitRejoins += 1;

        _enterUserIntoAutopool(msg.sender);
        emit CombRejoin(msg.sender, roiDeduction, autopoolDeduction, block.timestamp);
        emit Rejoin(msg.sender, user.referrer, REJOIN_FEE);
    }

    function _updatePendingROI(address userAddr) internal {
        User storage user = users[userAddr];
        if (!user.isActive || user.reachedTotalLimit) return;
        
        uint256 currentCombined = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        if (currentCombined >= MAX_PROFIT_CAP) return;
        
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
                emit ROIAdd(userAddr, roiToAdd, userPendingROI[userAddr], block.timestamp);
            }
        }
    }
    


    function claimROI() external postMigration noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE);
        require(users[msg.sender].directReferrals >= MIN_TOTAL_DIRECT_REFERRALS);
        
        uint256 rejoins = users[msg.sender].rejoinCount;
        uint256 activeDirs = getActiveDirectReferrals(msg.sender);
        require(rejoins > 3 ? activeDirs >= 2 : activeDirs >= 1);
        
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
        emit ROIOut(msg.sender, pending);
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
                        emit PoolOut(payoutUser, teamLeader, autopoolToAdd, 0);
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
        
        uint256 rejoins = users[msg.sender].rejoinCount;
        uint256 activeDirs = getActiveDirectReferrals(msg.sender);
        require(rejoins > 3 ? activeDirs >= 2 : activeDirs >= 1);
        
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
        emit PoolClaim(msg.sender, pending);
    }
    
    function claimCombinedEarnings() external noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE);
        require(users[msg.sender].directReferrals >= MIN_TOTAL_DIRECT_REFERRALS);
        
        uint256 rejoins = users[msg.sender].rejoinCount;
        uint256 activeDirs = getActiveDirectReferrals(msg.sender);
        require(rejoins > 3 ? activeDirs >= 2 : activeDirs >= 1);
        
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
        emit CombClaim(msg.sender, roiPending, autopoolPending, totalPending);
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

    // Migration Functions
    function setOldV12Contract(address oldV12Address) external onlyAdmin {
        require(oldV12Address != address(0));
        oldV12Contract = IAutoPoolFundV12(oldV12Address);
    }
    
    function setSecondV12Contract(address secondV12Address) external onlyAdmin {
        require(secondV12Address != address(0));
        secondV12Contract = IAutoPoolFundV12(secondV12Address);
    }

    function setMigrationPhase(uint8 newPhase) external onlyAdmin {
        require(newPhase <= 2);
        currentMigrationPhase = newPhase;
    }

    function completeMigration() external onlyAdmin {
        migrationCompleted = true;
        currentMigrationPhase = 2;
    }

    // Simplified migration
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

    // Split function
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
            directReferrals: directReferrals,
            lastSalaryUpdate: rejoinCount >= SALARY_REJOIN_REQUIREMENT ? block.timestamp : 0,
            salaryEnabled: rejoinCount >= SALARY_REJOIN_REQUIREMENT
        });
        
        _migrateUserEarnings(userAddr);
        
        // Update salary eligible count
        if (rejoinCount >= SALARY_REJOIN_REQUIREMENT) {
            salaryEligibleUsers++;
            emit SalaryOn(userAddr, rejoinCount, block.timestamp);
        }
        
        hasBeenMigrated[userAddr] = true;
        migratedUsers.push(userAddr);
        migratedUsersCount++;
        totalUsers++;
        
        emit Migrate(userAddr, validatedReferrer, directReferrals, totalEarned);
    }

    // Earnings function
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

    // Second V12 Migration
    function migrateFromSecondV12(address userAddr) external onlyAdmin {
        require(address(secondV12Contract) != address(0), "No V12 contract");
        require(!hasBeenMigrated[userAddr], "Already migrated");
        require(!migrationCompleted, "Migration done");
        
        // Get data from second V12 contract
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
        ) = secondV12Contract.users(userAddr);
        
        require(oldLastJoinTime > 0, "User not exist");
        
        // Migrate user data
        _migrateV12Data(
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

    function _migrateV12Data(
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
            directReferrals: directReferrals,
            lastSalaryUpdate: rejoinCount >= SALARY_REJOIN_REQUIREMENT ? block.timestamp : 0,
            salaryEnabled: rejoinCount >= SALARY_REJOIN_REQUIREMENT
        });
        
        _migrateV12Earnings(userAddr);
        
        // Update salary eligible count
        if (rejoinCount >= SALARY_REJOIN_REQUIREMENT) {
            salaryEligibleUsers++;
            emit SalaryOn(userAddr, rejoinCount, block.timestamp);
        }
        
        hasBeenMigrated[userAddr] = true;
        migratedUsers.push(userAddr);
        migratedUsersCount++;
        totalUsers++;
        
        emit Migrate(userAddr, validatedReferrer, directReferrals, totalEarned);
    }

    function _migrateV12Earnings(address userAddr) internal {
        userLastROIUpdate[userAddr] = block.timestamp;
        
        // Get earnings from second V12 contract
        try secondV12Contract.userPendingROI(userAddr) returns (uint256 pending) {
            userPendingROI[userAddr] = pending;
        } catch { userPendingROI[userAddr] = 0; }
        
        try secondV12Contract.autopoolPendingBalance(userAddr) returns (uint256 balance) {
            autopoolPendingBalance[userAddr] = balance;
        } catch { autopoolPendingBalance[userAddr] = 0; }
        
        try secondV12Contract.userTotalROIClaims(userAddr) returns (uint256 claims) {
            userTotalROIClaims[userAddr] = claims;
        } catch { userTotalROIClaims[userAddr] = 0; }
        
        userCombinedProfits[userAddr] = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
    }

    function migrateSecondV12UserDownlines(address userAddr) external onlyAdmin {
        require(hasBeenMigrated[userAddr], "Not migrated");
        require(!downlinesMigrated[userAddr], "Downlines done");
        
        uint256 expectedDownlines = users[userAddr].directReferrals;
        delete userDownlines[userAddr];
        
        uint256 actualCount = 0;
        for (uint256 i = 0; i < expectedDownlines; i++) {
            try secondV12Contract.userDownlines(userAddr, i) returns (address downline) {
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

    function migrateSecondV12UsersBatch(address[] calldata userAddrs) external onlyAdmin {
        require(address(secondV12Contract) != address(0), "No V12 contract");
        require(!migrationCompleted, "Migration done");
        require(userAddrs.length <= 50, "Max 50");
        
        for (uint256 i = 0; i < userAddrs.length; i++) {
            if (!hasBeenMigrated[userAddrs[i]]) {
                try this.migrateFromSecondV12(userAddrs[i]) {} catch {}
            }
        }
    }

    function migrateSecondV12DownlinesBatch(address[] calldata userAddrs) external onlyAdmin {
        require(userAddrs.length <= 50, "Max 50");
        
        for (uint256 i = 0; i < userAddrs.length; i++) {
            if (hasBeenMigrated[userAddrs[i]] && !downlinesMigrated[userAddrs[i]]) {
                try this.migrateSecondV12UserDownlines(userAddrs[i]) {} catch {}
            }
        }
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
        emit DownMigrate(userAddr, actualCount);
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

    // Auto batch migration
    function migrateUsersAutoBatch(uint256 batchSize) external onlyAdmin {
        require(address(oldV12Contract) != address(0));
        require(!migrationCompleted);
        require(batchSize >= 50 && batchSize <= 100, "Size 50-100");
        
        if (currentMigrationPhase == 0) {
            _migrateUserDataBatch(batchSize);
        } else if (currentMigrationPhase == 1) {
            _migrateDownlinesBatch(batchSize);
        }
    }

    // Migrate user data
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
        
        // Process remaining if batch not full
        if (processed < batchSize && migrationCurrentIndex >= oldContractMigratedCount) {
            _migrateNewV12Users(batchSize - processed);
        }
        
        emit BatchDone(processed, migrationCurrentIndex, block.timestamp);
    }

    // Migrate new V12 users
    function _migrateNewV12Users(uint256 /* remainingBatch */) internal {
        // Emit event for manual migration of new users
        emit BatchDone(0, migrationCurrentIndex, block.timestamp);
    }

    // Manual new V12 users
    function migrateNewV12Users(address[] calldata newUserAddresses) external onlyAdmin {
        require(newUserAddresses.length <= 50, "Max 50");
        
        uint256 migrated = 0;
        for (uint256 i = 0; i < newUserAddresses.length; i++) {
            address userAddr = newUserAddresses[i];
            if (!hasBeenMigrated[userAddr]) {
                _migrateUserQuick(userAddr);
                migrated++;
            }
        }
        
        emit BatchDone(migrated, migrationCurrentIndex, block.timestamp);
    }

    // Get old contract counts


    // Check user in old contract


    // Check user in second V12


    // Get contract addresses
    function getContractAddresses() external view returns (
        address oldV12,
        address secondV12,
        address usdtToken,
        address adminAddress
    ) {
        return (
            address(oldV12Contract),
            address(secondV12Contract),
            address(usdt),
            admin
        );
    }

    // Quick migration
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
                directReferrals: oldDirectReferrals,
                lastSalaryUpdate: oldRejoinCount >= SALARY_REJOIN_REQUIREMENT ? block.timestamp : 0,
                salaryEnabled: oldRejoinCount >= SALARY_REJOIN_REQUIREMENT
            });
            
            // Set earnings
            _setUserEarnings(userAddr);
            
            // Update salary eligible count
            if (oldRejoinCount >= SALARY_REJOIN_REQUIREMENT) {
                salaryEligibleUsers++;
                emit SalaryOn(userAddr, oldRejoinCount, block.timestamp);
            }
            
            // Mark as migrated
            hasBeenMigrated[userAddr] = true;
            migratedUsers.push(userAddr);
            migratedUsersCount++;
            totalUsers++;
            
            emit Migrate(userAddr, validatedReferrer, oldDirectReferrals, oldTotalEarned);
        } catch {
            // Skip users that fail migration
        }
    }

    // Set earnings
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

    // Auto-migrate downlines
    function _migrateDownlinesBatch(uint256 batchSize) internal {
        uint256 processed = 0;
        
        // Find users who need downlines migration
        for (uint256 i = 0; i < migratedUsers.length && processed < batchSize; i++) {
            address userAddr = migratedUsers[i];
            if (hasBeenMigrated[userAddr] && !downlinesMigrated[userAddr]) {
                _migrateDownlines(userAddr);
                processed++;
            }
        }
        
        emit BatchDone(processed, migrationCurrentIndex, block.timestamp);
    }

    // Quick downlines
    function _migrateDownlines(address userAddr) internal {
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
        emit DownMigrate(userAddr, actualCount);
    }

    // Migration progress


    // Estimate batches
    

    // Auto complete migration


    // Salary Functions
    function updateSalary(address userAddr) public {
        User storage user = users[userAddr];
        if (!user.salaryEnabled || user.lastSalaryUpdate == 0) return;
        
        uint256 daysPassed = (block.timestamp - user.lastSalaryUpdate) / SALARY_INTERVAL;
        if (daysPassed > 0) {
            uint256 salaryToAdd = daysPassed * DAILY_SALARY;
            pendingSalary[userAddr] += salaryToAdd;
            user.lastSalaryUpdate += daysPassed * SALARY_INTERVAL;
            
            emit SalaryAdd(userAddr, salaryToAdd, pendingSalary[userAddr], block.timestamp);
        }
    }
    
    function claimSalary() external postMigration noReentrant {
        require(users[msg.sender].salaryEnabled, "No salary");
        require(users[msg.sender].rejoinCount >= SALARY_REJOIN_REQUIREMENT, "Need 50 rejoins");
        
        updateSalary(msg.sender);
        
        uint256 salary = pendingSalary[msg.sender];
        require(salary >= DAILY_SALARY, "Min 1 day");
        require(usdt.balanceOf(address(this)) >= salary, "Low balance");
        
        pendingSalary[msg.sender] = 0;
        require(usdt.transfer(msg.sender, salary), "Transfer fail");
        
        totalSalaryPaid += salary;
        totalPaidOut += salary;
        
        emit SalaryOut(msg.sender, salary);
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

        function getMigrationStats() external view returns (uint256, uint8, bool) {
        return (migratedUsersCount, currentMigrationPhase, migrationCompleted);
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
        emit DownMigrate(userAddr, correctDownlines.length);
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



    function getPendingSalary(address userAddr) external view returns (uint256) {
        User memory user = users[userAddr];
        if (!user.salaryEnabled || user.lastSalaryUpdate == 0) return pendingSalary[userAddr];
        uint256 daysPassed = (block.timestamp - user.lastSalaryUpdate) / SALARY_INTERVAL;
        return daysPassed > 0 ? pendingSalary[userAddr] + daysPassed * DAILY_SALARY : pendingSalary[userAddr];
    }
    
    // Migration stats
    function getComprehensiveMigrationStats() external view returns (uint256, uint256, bool) {
        return (migratedUsersCount, migrationCurrentIndex, migrationCompleted);
    }

    function getContractStats() external view returns (uint256, uint256, uint256, uint256) {
        return (totalUsers, usdt.balanceOf(address(this)), totalFundsReceived, totalPaidOut);
    }
}
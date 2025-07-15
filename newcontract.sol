/**
 *Submitted for verification at BscScan.com on 2025-07-15
*/

/**
 *Submitted for verification at BscScan.com on 2025-07-14
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
        address referrer,
        uint256 totalEarned,
        uint256 lastJoinTime,
        uint256 lastROITime,
        uint256 joinCount,
        uint256 rejoinCount,
        bool isActive,
        bool reachedTotalLimit,
        uint256 directReferrals
    );
    function userDownlines(address user, uint256 index) external view returns (address);
    function userPendingROI(address user) external view returns (uint256);
    function autopoolPendingBalance(address user) external view returns (uint256);
    function userCombinedProfits(address user) external view returns (uint256);
    function userTotalROIClaims(address user) external view returns (uint256);
    function totalUsers() external view returns (uint256);
    function hasBeenMigrated(address user) external view returns (bool);
    function migratedUsers(uint256 index) external view returns (address);
    function migratedUsersCount() external view returns (uint256);
}

contract AutoPoolFundV11 {
    IERC20 public usdt;
    address public admin;
    bool internal locked;
    IAutoPoolFundV12 private oldV12Contract;

    // Constants for ROI System
    uint256 public constant ENTRY_FEE = 10 * 1e18;
    uint256 public constant REJOIN_FEE = 10 * 1e18;
    uint256 public constant ADMIN_FEE_PER_JOIN = 2 * 1e18;
    uint256 public constant ADMIN_FEE_FROM_ENTRY = 2 * 1e18;
    uint256 public constant HOURLY_ROI_AMOUNT = 5 * 1e18;
    uint256 public constant ROI_INTERVAL = 1 hours;
    uint256 public constant MIN_CONTRACT_BALANCE = 200 * 1e18;
    uint256 public constant MIN_TOTAL_DIRECT_REFERRALS = 2;
    uint256 public constant MIN_ACTIVE_DIRECT_REFERRALS = 1;

    // === COMBINED PROFIT SYSTEM ===
    uint256 public constant AUTOPOOL_COMMISSION = 5 * 1e18;
    uint256 public constant COMBINED_PROFIT_THRESHOLD = 20 * 1e18;
    uint256 public constant MAX_PROFIT_CAP = 20 * 1e18;
    uint256 public constant MIN_CLAIM_AMOUNT = 20 * 1e18;
    uint256 public constant TEAM_POOL_SIZE = 2;
    uint256 public maxAutopoolProcessingPerTx = 5;
    
    // === TEAM-BASED AUTOPOOL MAPPINGS ===
    mapping(address => address[]) public teamAutopoolQueue;
    mapping(address => address) public userTeamLeader;
    mapping(address => uint256) public autopoolPendingBalance;
    mapping(address => uint256) public autopoolTotalEarned;
    mapping(address => uint256) public autopoolPosition;
    mapping(address => bool) public isAutopoolActive;
    
    // === COMBINED PROFIT TRACKING ===
    mapping(address => uint256) public userPendingROI;
    mapping(address => uint256) public userLastROIUpdate;
    mapping(address => uint256) public userCombinedProfits;

    // Migration control
    mapping(address => bool) public hasBeenMigrated;
    bool public migrationCompleted = false;
    uint256 public migratedUsersCount = 0;
    uint256 public migrationCurrentIndex = 0;
    address[] public migratedUsers;

    // User Structure
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

    // Enhanced User Profile for return values
    struct UserProfileInfo {
        address referrer;
        uint256 totalEarned;
        uint256 lastJoinTime;
        bool isActive;
        bool reachedTotalLimit;
        uint256 rejoinCount;
        uint256 requiredActiveDirects;
        uint256 directReferralsCount;
    }

    // Combined Profit Info struct
    struct CombinedProfitInfo {
        uint256 pendingROI;
        uint256 autopoolEarnings;
        uint256 totalCombinedProfits;
        uint256 thresholdForRejoin;
        bool eligibleForCombinedRejoin;
        uint256 shortfallToThreshold;
        uint256 availableForClaim;
        string status;
    }

    // State Variables
    mapping(address => User) public users;
    mapping(address => uint256) public userTotalROIClaims;
    mapping(address => address[]) public userDownlines;

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
    event CombinedProfitUpdated(address indexed user, uint256 totalCombined, bool thresholdReached);
    event ProfitCapReached(address indexed user, uint256 totalProfits, uint256 timestamp);
    event MigrationStarted(uint256 totalUsers, uint256 timestamp);
    event MigrationCompleted(uint256 totalMigratedUsers, uint256 timestamp);
    event MigrationBatchCompleted(uint256 batchSize, uint256 currentIndex, uint256 timestamp);

    modifier noReentrant() {
        require(!locked, "No re-entrancy");
        locked = true;
        _;
        locked = false;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier migrationCompleteOnly() {
        require(migrationCompleted, "Migration in progress");
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

    // Main Join Function
    function join(address referrer) external migrationCompleteOnly noReentrant {
        User storage user = users[msg.sender];

        if (user.reachedTotalLimit) {
            require(usdt.transferFrom(msg.sender, address(this), REJOIN_FEE), "Transfer failed");

            user.rejoinCount += 1;
            user.reachedTotalLimit = false;
            user.isActive = true;
            user.lastJoinTime = block.timestamp;
            user.lastROITime = 0;
            user.joinCount += 1;
            
            userLastROIUpdate[msg.sender] = block.timestamp;

            require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN), "Admin fee failed");
            totalFundsReceived += REJOIN_FEE;

            _enterUserIntoAutopool(msg.sender);

            emit UserRejoined(msg.sender, user.referrer, REJOIN_FEE);
            return;
        }

        require(!user.isActive && user.joinCount == 0, "Already joined or active");
        require(usdt.transferFrom(msg.sender, address(this), ENTRY_FEE), "Fee transfer failed");

        address actualReferrer = admin;
        if (referrer != address(0) && referrer != msg.sender && users[referrer].isActive) {
            actualReferrer = referrer;
        }
        user.referrer = actualReferrer;
        addToDownlines(actualReferrer, msg.sender);
        users[actualReferrer].directReferrals += 1;

        user.isActive = true;
        user.lastJoinTime = block.timestamp;
        user.joinCount = 1;
        user.rejoinCount = 0;
        user.directReferrals = 0;
        
        userLastROIUpdate[msg.sender] = block.timestamp;
        userPendingROI[msg.sender] = 0;

        _enterUserIntoAutopool(msg.sender);

        totalUsers += 1;
        totalFundsReceived += ENTRY_FEE;

        require(usdt.transfer(admin, ADMIN_FEE_FROM_ENTRY), "Admin fee failed");
         
        emit UserJoined(msg.sender, user.referrer, ENTRY_FEE);
    }

    // Combined Profit Rejoin
    function rejoinWithCombinedProfits() external migrationCompleteOnly noReentrant {
        User storage user = users[msg.sender];
        require(user.reachedTotalLimit, "Not ready to rejoin");
        
        _updatePendingROI(msg.sender);
        
        uint256 pendingROI = userPendingROI[msg.sender];
        uint256 autopoolEarnings = autopoolPendingBalance[msg.sender];
        uint256 totalCombined = pendingROI + autopoolEarnings;
        
        require(totalCombined >= COMBINED_PROFIT_THRESHOLD, "Need 20 USDT combined");

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

        require(usdt.transfer(admin, ADMIN_FEE_PER_JOIN), "Admin fee failed");
        totalFundsReceived += REJOIN_FEE;
        totalCombinedProfitRejoins += 1;

        _enterUserIntoAutopool(msg.sender);

        emit CombinedProfitRejoin(msg.sender, roiDeduction, autopoolDeduction, block.timestamp);
        emit UserRejoined(msg.sender, user.referrer, REJOIN_FEE);
    }

    // ROI System
    function _updatePendingROI(address userAddr) internal {
        User storage user = users[userAddr];
        
        if (!user.isActive || user.reachedTotalLimit) {
            return;
        }
        
        uint256 currentCombined = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        if (currentCombined >= MAX_PROFIT_CAP) {
            return;
        }
        
        uint256 totalDirects = getTotalDirectReferrals(userAddr);
        uint256 activeDirects = getActiveDirectReferrals(userAddr);
        
        if (totalDirects < MIN_TOTAL_DIRECT_REFERRALS || activeDirects < MIN_ACTIVE_DIRECT_REFERRALS) {
            return;
        }
        
        (bool isChainActive,) = isUplineChainActive(userAddr);
        if (!isChainActive) {
            return;
        }
        
        uint256 lastUpdate = userLastROIUpdate[userAddr];
        if (lastUpdate == 0) {
            lastUpdate = user.lastJoinTime;
        }
        
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
                
                bool thresholdReached = userCombinedProfits[userAddr] >= COMBINED_PROFIT_THRESHOLD;
                emit CombinedProfitUpdated(userAddr, userCombinedProfits[userAddr], thresholdReached);
                
                if (userCombinedProfits[userAddr] >= MAX_PROFIT_CAP) {
                    emit ProfitCapReached(userAddr, userCombinedProfits[userAddr], block.timestamp);
                }
            }
        }
    }
    
    function updatePendingROI(address userAddr) external {
        _updatePendingROI(userAddr);
    }

    function claimROI() external migrationCompleteOnly noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE, "Low balance");
        
        uint256 totalDirects = getTotalDirectReferrals(msg.sender);
        uint256 activeDirects = getActiveDirectReferrals(msg.sender);
        require(totalDirects >= MIN_TOTAL_DIRECT_REFERRALS, "Need 2 direct refs");
        require(activeDirects >= MIN_ACTIVE_DIRECT_REFERRALS, "Need 1 active ref");
        
        _updatePendingROI(msg.sender);
        
        uint256 pending = userPendingROI[msg.sender];
        require(pending >= MIN_CLAIM_AMOUNT, "Min 20 USDT");
        require(usdt.balanceOf(address(this)) >= pending, "Insufficient balance");
        
        userPendingROI[msg.sender] = 0;
        userCombinedProfits[msg.sender] = autopoolPendingBalance[msg.sender];
        
        if (pending >= MIN_CLAIM_AMOUNT) {
            users[msg.sender].isActive = false;
            users[msg.sender].reachedTotalLimit = true;
        }
        
        require(usdt.transfer(msg.sender, pending), "Transfer failed");
        totalPaidOut += pending;
        
        emit ROIClaimed(msg.sender, pending);
    }

    // Autopool System
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
                        
                        bool thresholdReached = userCombinedProfits[payoutUser] >= COMBINED_PROFIT_THRESHOLD;
                        emit CombinedProfitUpdated(payoutUser, userCombinedProfits[payoutUser], thresholdReached);
                        
                        if (userCombinedProfits[payoutUser] >= MAX_PROFIT_CAP) {
                            emit ProfitCapReached(payoutUser, userCombinedProfits[payoutUser], block.timestamp);
                        }
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
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE, "Low balance");
        
        uint256 totalDirects = getTotalDirectReferrals(msg.sender);
        uint256 activeDirects = getActiveDirectReferrals(msg.sender);
        require(totalDirects >= MIN_TOTAL_DIRECT_REFERRALS, "Need 2 direct refs");
        require(activeDirects >= MIN_ACTIVE_DIRECT_REFERRALS, "Need 1 active ref");
        
        uint256 pending = autopoolPendingBalance[msg.sender];
        require(pending >= MIN_CLAIM_AMOUNT, "Min 20 USDT");
        require(usdt.balanceOf(address(this)) >= pending, "Insufficient balance");
        
        autopoolPendingBalance[msg.sender] = 0;
        
        _updatePendingROI(msg.sender);
        userCombinedProfits[msg.sender] = userPendingROI[msg.sender];
        
        if (pending >= MIN_CLAIM_AMOUNT) {
            users[msg.sender].isActive = false;
            users[msg.sender].reachedTotalLimit = true;
        }
        
        require(usdt.transfer(msg.sender, pending), "Transfer failed");
        totalPaidOut += pending;
        
        emit AutopoolClaimed(msg.sender, pending);
    }
    
    function claimCombinedEarnings() external noReentrant {
        require(usdt.balanceOf(address(this)) >= MIN_CONTRACT_BALANCE, "Low balance");
        
        uint256 totalDirects = getTotalDirectReferrals(msg.sender);
        uint256 activeDirects = getActiveDirectReferrals(msg.sender);
        require(totalDirects >= MIN_TOTAL_DIRECT_REFERRALS, "Need 2 direct refs");
        require(activeDirects >= MIN_ACTIVE_DIRECT_REFERRALS, "Need 1 active ref");
        
        _updatePendingROI(msg.sender);
        
        uint256 roiPending = userPendingROI[msg.sender];
        uint256 autopoolPending = autopoolPendingBalance[msg.sender];
        uint256 totalPending = roiPending + autopoolPending;
        
        require(totalPending >= MIN_CLAIM_AMOUNT, "Min 20 USDT total");
        require(usdt.balanceOf(address(this)) >= totalPending, "Insufficient balance");
        
        userPendingROI[msg.sender] = 0;
        autopoolPendingBalance[msg.sender] = 0;
        userCombinedProfits[msg.sender] = 0;
        
        users[msg.sender].isActive = false;
        users[msg.sender].reachedTotalLimit = true;
        
        require(usdt.transfer(msg.sender, totalPending), "Transfer failed");
        totalPaidOut += totalPending;
        
        emit CombinedProfitsClaimed(msg.sender, roiPending, autopoolPending, totalPending);
    }

    // ========== INTERNAL FUNCTIONS ==========
    function addToDownlines(address referrer, address user) internal {
        userDownlines[referrer].push(user);
    }

    function getTotalDirectReferrals(address userAddr) public view returns (uint256) {
        return users[userAddr].directReferrals;
    }

    function getActiveDirectReferrals(address userAddr) public view returns (uint256 activeCount) {
        activeCount = 0;
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
            if (currentUpline == admin) {
                return (true, address(0));
            }
            
            User memory uplineUser = users[currentUpline];
            
            if (!uplineUser.isActive || uplineUser.reachedTotalLimit) {
                return (false, currentUpline);
            }
            
            currentUpline = uplineUser.referrer;
            depth++;
        }
        
        return (true, address(0));
    }

    // ========== VIEW FUNCTIONS ==========
    function getUserInfo(address userAddr) external view returns (UserProfileInfo memory) {
        User storage user = users[userAddr];
        return UserProfileInfo(
            user.referrer,
            user.totalEarned,
            user.lastJoinTime,
            user.isActive,
            user.reachedTotalLimit,
            user.rejoinCount,
            MIN_ACTIVE_DIRECT_REFERRALS,
            user.directReferrals
        );
    }

    function getCombinedProfitInfo(address userAddr) external view returns (CombinedProfitInfo memory) {
        uint256 currentPendingROI = _calculatePendingROI(userAddr);
        uint256 autopoolEarnings = autopoolPendingBalance[userAddr];
        uint256 totalCombined = currentPendingROI + autopoolEarnings;
        bool eligible = (users[userAddr].reachedTotalLimit && totalCombined >= COMBINED_PROFIT_THRESHOLD);
        
        uint256 shortfall = 0;
        if (totalCombined < COMBINED_PROFIT_THRESHOLD) {
            shortfall = COMBINED_PROFIT_THRESHOLD - totalCombined;
        }
        
        uint256 availableForClaim = 0;
        if (totalCombined >= MIN_CLAIM_AMOUNT) {
            availableForClaim = totalCombined;
        }
        
        string memory status;
        if (eligible) {
            status = "Ready to rejoin with combined profits (20 USDT)";
        } else if (users[userAddr].reachedTotalLimit) {
            status = string(abi.encodePacked("Need ", toString(shortfall / 1e18), " more USDT combined profits"));
        } else if (totalCombined >= MAX_PROFIT_CAP) {
            status = "At maximum profit cap (20 USDT) - must claim or rejoin";
        } else if (currentPendingROI >= MIN_CLAIM_AMOUNT) {
            status = string(abi.encodePacked("Can claim ", toString(currentPendingROI / 1e18), " USDT ROI"));
        } else if (autopoolEarnings >= MIN_CLAIM_AMOUNT) {
            status = string(abi.encodePacked("Can claim ", toString(autopoolEarnings / 1e18), " USDT autopool"));
        } else if (totalCombined >= MIN_CLAIM_AMOUNT) {
            status = string(abi.encodePacked("Can claim ", toString(totalCombined / 1e18), " USDT combined"));
        } else {
            uint256 hoursToMinClaim = (MIN_CLAIM_AMOUNT - currentPendingROI) / HOURLY_ROI_AMOUNT;
            status = string(abi.encodePacked("Accumulating ROI - need ", toString(hoursToMinClaim), " more hours for 20 USDT minimum"));
        }
        
        return CombinedProfitInfo(
            currentPendingROI,
            autopoolEarnings,
            totalCombined,
            COMBINED_PROFIT_THRESHOLD,
            eligible,
            shortfall,
            availableForClaim,
            status
        );
    }
    
    function _calculatePendingROI(address userAddr) internal view returns (uint256) {
        User memory user = users[userAddr];
        
        if (!user.isActive || user.reachedTotalLimit) {
            return userPendingROI[userAddr];
        }
        
        uint256 currentCombined = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        if (currentCombined >= MAX_PROFIT_CAP) {
            return userPendingROI[userAddr];
        }
        
        uint256 totalDirects = getTotalDirectReferrals(userAddr);
        uint256 activeDirects = getActiveDirectReferrals(userAddr);
        
        if (totalDirects < MIN_TOTAL_DIRECT_REFERRALS || activeDirects < MIN_ACTIVE_DIRECT_REFERRALS) {
            return userPendingROI[userAddr];
        }
        
        (bool isChainActive,) = isUplineChainActive(userAddr);
        if (!isChainActive) {
            return userPendingROI[userAddr];
        }
        
        uint256 lastUpdate = userLastROIUpdate[userAddr];
        if (lastUpdate == 0) {
            lastUpdate = user.lastJoinTime;
        }
        
        uint256 hoursPassed = (block.timestamp - lastUpdate) / ROI_INTERVAL;
        uint256 additionalROI = hoursPassed * HOURLY_ROI_AMOUNT;
        
        uint256 projectedCombined = currentCombined + additionalROI;
        if (projectedCombined > MAX_PROFIT_CAP) {
            additionalROI = MAX_PROFIT_CAP - currentCombined;
        }
        
        return userPendingROI[userAddr] + additionalROI;
    }

    function simulateCombinedProfitRejoin(address userAddr) external view returns (
        uint256 totalCombinedProfits,
        uint256 roiDeduction,
        uint256 autopoolDeduction,
        uint256 remainingROI,
        uint256 remainingAutopool,
        bool canRejoin,
        string memory breakdown
    ) {
        uint256 pendingROI = _calculatePendingROI(userAddr);
        uint256 autopoolEarnings = autopoolPendingBalance[userAddr];
        totalCombinedProfits = pendingROI + autopoolEarnings;
        
        canRejoin = (users[userAddr].reachedTotalLimit && totalCombinedProfits >= COMBINED_PROFIT_THRESHOLD);
        
        if (canRejoin && totalCombinedProfits > 0) {
            roiDeduction = (REJOIN_FEE * pendingROI) / totalCombinedProfits;
            autopoolDeduction = REJOIN_FEE - roiDeduction;
            remainingROI = pendingROI - roiDeduction;
            remainingAutopool = autopoolEarnings - autopoolDeduction;
            
            breakdown = string(abi.encodePacked(
                "Deduct ", toString(roiDeduction / 1e18), " from ROI + ", 
                toString(autopoolDeduction / 1e18), " from autopool = 10 USDT rejoin fee"
            ));
        } else {
            breakdown = "Cannot rejoin - insufficient combined profits or not at ROI limit";
        }
    }

    function getEconomicsBreakdown() external pure returns (
        uint256 entryFee,
        uint256 rejoinFee,
        uint256 hourlyROI,
        uint256 autopoolCommission,
        uint256 combinedThreshold,
        uint256 minimumClaim,
        string memory model
    ) {
        entryFee = ENTRY_FEE;
        rejoinFee = REJOIN_FEE;
        hourlyROI = HOURLY_ROI_AMOUNT;
        autopoolCommission = AUTOPOOL_COMMISSION;
        combinedThreshold = COMBINED_PROFIT_THRESHOLD;
        minimumClaim = MIN_CLAIM_AMOUNT;
        
        model = "Auto-accumulate 5 USDT/hour + 5 USDT autopool - Manual claim min 20 USDT each - Max 20 USDT profit cap - Rejoin with 10 USDT when total reaches 20 USDT";
    }

    function getROIClaimStatus(address userAddr) external view returns (
        bool canClaim,
        uint256 currentPendingROI,
        uint256 minimumRequired,
        uint256 hoursAccumulated,
        uint256 hoursUntilClaimable,
        string memory status
    ) {
        currentPendingROI = _calculatePendingROI(userAddr);
        minimumRequired = MIN_CLAIM_AMOUNT;
        
        User memory user = users[userAddr];
        if (user.isActive && !user.reachedTotalLimit) {
            uint256 lastUpdate = userLastROIUpdate[userAddr];
            if (lastUpdate == 0) lastUpdate = user.lastJoinTime;
            hoursAccumulated = (block.timestamp - lastUpdate) / ROI_INTERVAL;
        }
        
        if (currentPendingROI >= minimumRequired) {
            canClaim = true;
            hoursUntilClaimable = 0;
            status = string(abi.encodePacked("Ready to claim ", toString(currentPendingROI / 1e18), " USDT ROI"));
        } else {
            canClaim = false;
            uint256 shortfall = minimumRequired - currentPendingROI;
            hoursUntilClaimable = shortfall / HOURLY_ROI_AMOUNT;
            if (shortfall % HOURLY_ROI_AMOUNT > 0) hoursUntilClaimable += 1;
            
            status = string(abi.encodePacked(
                "Need ", toString(hoursUntilClaimable), " more hours to reach 20 USDT minimum (currently ", 
                toString(currentPendingROI / 1e18), " USDT)"
            ));
        }
    }

    function getDirectReferralCounts(address userAddr) external view returns (
        uint256 totalDirectReferrals,
        uint256 activeDirectReferrals
    ) {
        return (
            getTotalDirectReferrals(userAddr),
            getActiveDirectReferrals(userAddr)
        );
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

    // ========== UTILITY FUNCTIONS ==========
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ========== ADMIN FUNCTIONS ==========
    function emergencyWithdraw() external onlyAdmin {
        require(usdt.balanceOf(address(this)) > 0, "No balance to withdraw");
        require(usdt.transfer(admin, usdt.balanceOf(address(this))), "Withdraw failed");
    }

    function completeMigration() external onlyAdmin {
        migrationCompleted = true;
        emit MigrationCompleted(migratedUsersCount, block.timestamp);
    }

    function resetMigrationCompletion() external onlyAdmin {
        migrationCompleted = false;
    }

    function setMigrationIndex(uint256 newIndex) external onlyAdmin {
        migrationCurrentIndex = newIndex;
    }

    function getMigrationStatus() external view returns (
        bool completed,
        uint256 migratedCount
    ) {
        return (migrationCompleted, migratedUsersCount);
    }

    function getMigrationProgress() external view returns (
        uint256 currentIndex,
        uint256 migratedCount,
        bool completed
    ) {
        return (
            migrationCurrentIndex,
            migratedUsersCount,
            migrationCompleted
        );
    }

    function getUserMigrationInfo(address userAddr) external view returns (
        bool isMigrated,
        uint256 preservedHourlyROI,
        uint256 oldTotalROIClaims,
        uint256 estimatedOldROICycles,
        uint256 currentCombinedProfits,
        string memory migrationStatus
    ) {
        isMigrated = hasBeenMigrated[userAddr];
        preservedHourlyROI = userPendingROI[userAddr];
        oldTotalROIClaims = userTotalROIClaims[userAddr];
        currentCombinedProfits = userCombinedProfits[userAddr];
        
        if (oldTotalROIClaims > 0) {
            estimatedOldROICycles = oldTotalROIClaims / (15 * 1e18);
        }
        
        if (isMigrated) {
            if (preservedHourlyROI > 0) {
                migrationStatus = string(abi.encodePacked(
                    "Migrated with ", 
                    toString(preservedHourlyROI / 1e18), 
                    " USDT preserved ROI from ", 
                    toString(estimatedOldROICycles), 
                    " V10 cycles. Active directs reset to 0."
                ));
            } else {
                migrationStatus = "Migrated - fresh start in V11 with active directs reset to 0";
            }
        } else {
            migrationStatus = "Not yet migrated from V10";
        }
    }

    // ========== OPTIMIZED V12 TO V12 MIGRATION FUNCTIONS ==========

    function setOldV12Contract(address oldV12Address) external onlyAdmin {
        require(oldV12Address != address(0), "Invalid contract address");
        oldV12Contract = IAutoPoolFundV12(oldV12Address);
    }

    /**
     * @dev Migrate single user from old V12 contract - OPTIMIZED
     * Gas optimized version with reduced external calls and stack depth
     */
    function migrateV12User(address userAddr) external onlyAdmin {
        require(address(oldV12Contract) != address(0), "Old V12 contract not set");
        require(!hasBeenMigrated[userAddr], "User already migrated");
        require(!migrationCompleted, "Migration completed");
        
        // Single external call to get all user data
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
        
        require(oldLastJoinTime > 0, "User does not exist in old V12 contract");
        
        // Migrate user data in single function call
        _migrateV12UserData(userAddr, oldReferrer, oldTotalEarned, oldLastJoinTime, 
                           oldLastROITime, oldJoinCount, oldRejoinCount, oldIsActive, 
                           oldReachedTotalLimit, oldDirectReferrals);
    }

    /**
     * @dev Batch migrate users - OPTIMIZED
     * Increased to 50 users max per batch for efficiency
     */
    function migrateV12UsersBatch(address[] calldata userAddrs) external onlyAdmin {
        require(address(oldV12Contract) != address(0), "Old V12 contract not set");
        require(!migrationCompleted, "Migration completed");
        require(userAddrs.length <= 50, "Max 50 users per batch");
        
        for (uint256 i = 0; i < userAddrs.length; i++) {
            address userAddr = userAddrs[i];
            if (!hasBeenMigrated[userAddr]) {
                _migrateV12UserQuick(userAddr);
            }
        }
    }

    /**
     * @dev Auto-migrate with optimized gas usage - 50 users per batch
     */
    function migrateV12UsersAuto(uint256 batchSize) external onlyAdmin {
        require(address(oldV12Contract) != address(0), "Old V12 contract not set");
        require(!migrationCompleted, "Migration completed");
        require(batchSize > 0 && batchSize <= 50, "Batch size must be 1-50");
        
        _processV12MigrationBatchOptimized(batchSize);
    }

    /**
     * @dev Manual migrate specific users - OPTIMIZED
     */
    function manualMigrateUsers(address[] calldata userAddresses) external onlyAdmin {
        require(userAddresses.length <= 25, "Max 25 users");
        
        for (uint256 i = 0; i < userAddresses.length; i++) {
            if (!hasBeenMigrated[userAddresses[i]]) {
                _migrateV12UserQuick(userAddresses[i]);
            }
        }
    }

    // ========== INTERNAL OPTIMIZED FUNCTIONS ==========

    /**
     * @dev Migrate user data in single internal call - OPTIMIZED
     * Combines all migration steps to reduce stack depth
     */
    function _migrateV12UserData(
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
        // Set basic user data
        User storage newUser = users[userAddr];
        newUser.referrer = referrer;
        newUser.totalEarned = totalEarned;
        newUser.lastJoinTime = lastJoinTime;
        newUser.lastROITime = lastROITime;
        newUser.joinCount = joinCount;
        newUser.rejoinCount = rejoinCount;
        newUser.isActive = isActive;
        newUser.reachedTotalLimit = reachedTotalLimit;
        newUser.directReferrals = directReferrals;
        
        // Get earnings data with single calls
        userPendingROI[userAddr] = _getOldPendingROI(userAddr);
        autopoolPendingBalance[userAddr] = _getOldAutopoolBalance(userAddr);
        userCombinedProfits[userAddr] = userPendingROI[userAddr] + autopoolPendingBalance[userAddr];
        userTotalROIClaims[userAddr] = _getOldROIClaims(userAddr);
        userLastROIUpdate[userAddr] = block.timestamp;
        
        // Enter autopool if active (simplified)
        if (isActive && !reachedTotalLimit) {
            address teamLeader = (referrer != address(0) && users[referrer].isActive) ? referrer : admin;
            userTeamLeader[userAddr] = teamLeader;
            teamAutopoolQueue[teamLeader].push(userAddr);
            autopoolPosition[userAddr] = teamAutopoolQueue[teamLeader].length - 1;
            isAutopoolActive[userAddr] = true;
        }
        
        // Finalize migration
        totalUsers++;
        migratedUsersCount++;
        hasBeenMigrated[userAddr] = true;
        migratedUsers.push(userAddr);
    }

    /**
     * @dev Quick migration without downline migration to save gas
     */
    function _migrateV12UserQuick(address userAddr) internal {
        if (hasBeenMigrated[userAddr]) return;
        
        try oldV12Contract.users(userAddr) returns (
            address oldReferrer,
            uint256 oldTotalEarned,
            uint256 oldLastJoinTime,
            uint256 oldLastROITime,
            uint256 oldJoinCount,
            uint256 oldRejoinCount,
            bool oldIsActive,
            bool oldReachedTotalLimit,
            uint256 oldDirectReferrals
        ) {
            if (oldLastJoinTime > 0) {
                _migrateV12UserData(userAddr, oldReferrer, oldTotalEarned, oldLastJoinTime, 
                                   oldLastROITime, oldJoinCount, oldRejoinCount, oldIsActive, 
                                   oldReachedTotalLimit, oldDirectReferrals);
            }
        } catch {
            // Skip failed migrations silently
        }
    }

    /**
     * @dev Optimized batch processing using migrated users array from old contract
     */
    function _processV12MigrationBatchOptimized(uint256 batchSize) internal {
        uint256 processed = 0;
        
        // Get total users from old contract for boundary check
        uint256 totalV12Users;
        try oldV12Contract.totalUsers() returns (uint256 total) {
            totalV12Users = total;
        } catch {
            return; // Exit if can't read total users
        }
        
        // First, try to get users from migrated users array (V10->V12 users)
        uint256 migratedUsersFromV10;
        try oldV12Contract.migratedUsersCount() returns (uint256 count) {
            migratedUsersFromV10 = count;
        } catch {
            migratedUsersFromV10 = 0;
        }
        
        // Process migrated users first (these are confirmed to exist)
        if (migrationCurrentIndex < migratedUsersFromV10) {
            for (uint256 i = migrationCurrentIndex; i < migratedUsersFromV10 && processed < batchSize; i++) {
                try oldV12Contract.migratedUsers(i) returns (address userAddr) {
                    if (userAddr != address(0) && !hasBeenMigrated[userAddr]) {
                        _migrateV12UserQuick(userAddr);
                        processed++;
                    }
                } catch {
                    // Skip invalid entries
                }
                migrationCurrentIndex++;
            }
        }
        
        // If we still need more users and haven't processed all, 
        // mark migration as requiring manual intervention
        if (processed == 0 && migrationCurrentIndex >= migratedUsersFromV10) {
            // All auto-discoverable users have been processed
            emit MigrationBatchCompleted(0, migrationCurrentIndex, block.timestamp);
            return;
        }
        
        emit MigrationBatchCompleted(processed, migrationCurrentIndex, block.timestamp);
    }

    /**
     * @dev Quick validation with single external call
     */
    function _isValidV12UserQuick(address userAddr) internal view returns (bool) {
        if (userAddr == address(0)) return false;
        
        try oldV12Contract.users(userAddr) returns (
            address,
            uint256,
            uint256 lastJoinTime,
            uint256,
            uint256,
            uint256,
            bool,
            bool,
            uint256
        ) {
            return lastJoinTime > 0;
        } catch {
            return false;
        }
    }

    // ========== SAFE GETTER FUNCTIONS ==========

    /**
     * @dev Safe getter for pending ROI
     */
    function _getOldPendingROI(address userAddr) internal view returns (uint256) {
        try oldV12Contract.userPendingROI(userAddr) returns (uint256 pending) {
            return pending;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Safe getter for autopool balance
     */
    function _getOldAutopoolBalance(address userAddr) internal view returns (uint256) {
        try oldV12Contract.autopoolPendingBalance(userAddr) returns (uint256 balance) {
            return balance;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Safe getter for ROI claims
     */
    function _getOldROIClaims(address userAddr) internal view returns (uint256) {
        try oldV12Contract.userTotalROIClaims(userAddr) returns (uint256 claims) {
            return claims;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Get simple migration stats
     */
    function getSimpleMigrationStats() external view returns (
        uint256 migratedCount,
        bool completed,
        uint256 currentIndex
    ) {
        return (migratedUsersCount, migrationCompleted, migrationCurrentIndex);
    }

    /**
     * @dev Get remaining users that need migration from old contract
     * Returns actual user addresses instead of searching randomly
     */
    function getRemainingUsersToMigrate() external view onlyAdmin returns (
        address[] memory remainingUsers,
        uint256 remainingCount,
        uint256 totalV12Users,
        uint256 migratedV10Users
    ) {
        // Get counts from old contract
        try oldV12Contract.totalUsers() returns (uint256 total) {
            totalV12Users = total;
        } catch {
            totalV12Users = 0;
        }
        
        try oldV12Contract.migratedUsersCount() returns (uint256 migrated) {
            migratedV10Users = migrated;
        } catch {
            migratedV10Users = 0;
        }
        
        // Create temporary array to collect remaining users
        address[] memory tempUsers = new address[](migratedV10Users);
        uint256 count = 0;
        
        // Check migrated users array from old contract
        for (uint256 i = 0; i < migratedV10Users; i++) {
            try oldV12Contract.migratedUsers(i) returns (address userAddr) {
                if (userAddr != address(0) && !hasBeenMigrated[userAddr]) {
                    tempUsers[count] = userAddr;
                    count++;
                }
            } catch {
                continue;
            }
        }
        
        // Create final array with exact count
        remainingUsers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            remainingUsers[i] = tempUsers[i];
        }
        
        remainingCount = count;
    }

    /**
     * @dev Migrate remaining users using the specific addresses found
     */
    function migrateRemainingUsers() external onlyAdmin {
        require(!migrationCompleted, "Migration already completed");
        
        (address[] memory remainingUsers, uint256 remainingCount,,) = this.getRemainingUsersToMigrate();
        
        require(remainingCount > 0, "No remaining users to migrate");
        require(remainingCount <= 50, "Too many users - use batch migration");
        
        for (uint256 i = 0; i < remainingCount; i++) {
            if (!hasBeenMigrated[remainingUsers[i]]) {
                _migrateV12UserQuick(remainingUsers[i]);
            }
        }
    }

    /**
     * @dev Check if all discoverable users have been migrated
     */
    function checkMigrationComplete() external view returns (
        bool allUsersMigrated,
        uint256 remainingUsers,
        string memory status
    ) {
        try this.getRemainingUsersToMigrate() returns (
            address[] memory /* remaining */,
            uint256 count,
            uint256 /* totalV12 */,
            uint256 migratedV10
        ) {
            remainingUsers = count;
            allUsersMigrated = (count == 0);
            
            if (allUsersMigrated) {
                status = "All discoverable users migrated - ready to complete migration";
            } else {
                status = string(abi.encodePacked(
                    toString(count), 
                    " users remaining from discoverable ",
                    toString(migratedV10),
                    " V10->V12 migrated users"
                ));
            }
        } catch {
            allUsersMigrated = false;
            remainingUsers = 0;
            status = "Unable to check remaining users";
        }
    }

    /**
     * @dev Get V12 migration status
     */
    function getV12MigrationInfo() external view returns (
        address oldV12ContractAddress,
        bool isV12ContractSet,
        uint256 estimatedV12Users
    ) {
        oldV12ContractAddress = address(oldV12Contract);
        isV12ContractSet = oldV12ContractAddress != address(0);
        
        if (isV12ContractSet) {
            try oldV12Contract.totalUsers() returns (uint256 v12TotalUsers) {
                estimatedV12Users = v12TotalUsers;
            } catch {
                estimatedV12Users = 0;
            }
        } else {
            estimatedV12Users = 0;
        }
    }
}
const { Web3 } = require('web3');
const config = require('./config-ankr');

async function testV12FinalConnection() {
    console.log('🧪 Testing V12 Final Contract Connection...');
    console.log('📝 Contract Address:', config.blockchain.contractAddress);
    
    try {
        // Initialize Web3 with Ankr
        const web3 = new Web3(config.blockchain.rpcUrls[0]);
        
        // Test basic connection
        console.log('\n🔗 Testing basic connection...');
        const blockNumber = await web3.eth.getBlockNumber();
        console.log('✅ Current block number:', blockNumber.toString());
        
        // Test contract connection
        console.log('\n📋 Testing contract connection...');
        const contract = new web3.eth.Contract(config.contractABI, config.blockchain.contractAddress);
        
        // Test getContractStats function
        console.log('\n📊 Testing getContractStats function...');
        const contractStats = await contract.methods.getContractStats().call();
        
        console.log('📊 Raw contract stats:', contractStats);
        console.log('📊 V12 Final Contract stats breakdown:');
        console.log('   - Index 0 (totalUsersCount):', contractStats[0]);
        console.log('   - Index 1 (contractBalance):', (parseFloat(contractStats[1]) / 1e18).toFixed(4), 'USDT');
        console.log('   - Index 2 (totalFundsReceivedAmount):', (parseFloat(contractStats[2]) / 1e18).toFixed(4), 'USDT');
        console.log('   - Index 3 (totalPaidOutAmount):', (parseFloat(contractStats[3]) / 1e18).toFixed(4), 'USDT');
        
        // Test recent events
        console.log('\n📰 Testing recent events...');
        const currentBlock = Number(await web3.eth.getBlockNumber());
        const fromBlock = Math.max(0, currentBlock - 1000);
        
        console.log(`🔍 Searching for events from block ${fromBlock} to ${currentBlock}...`);
        
        const joinEvents = await contract.getPastEvents('Join', {
            fromBlock: fromBlock,
            toBlock: currentBlock
        });
        
        const rejoinEvents = await contract.getPastEvents('Rejoin', {
            fromBlock: fromBlock,
            toBlock: currentBlock
        });
        
        console.log(`✅ Found ${joinEvents.length} Join events`);
        console.log(`✅ Found ${rejoinEvents.length} Rejoin events`);
        
        if (joinEvents.length > 0) {
            console.log('\n📝 Sample Join event:');
            const sampleEvent = joinEvents[0];
            console.log('   - User:', sampleEvent.returnValues.user);
            console.log('   - Referrer:', sampleEvent.returnValues.referrer);
            console.log('   - Fee:', (parseFloat(sampleEvent.returnValues.fee) / 1e18).toFixed(2), 'USDT');
            console.log('   - TX Hash:', sampleEvent.transactionHash);
        }
        
        if (rejoinEvents.length > 0) {
            console.log('\n📝 Sample Rejoin event:');
            const sampleEvent = rejoinEvents[0];
            console.log('   - User:', sampleEvent.returnValues.user);
            console.log('   - Referrer:', sampleEvent.returnValues.referrer);
            console.log('   - Fee:', (parseFloat(sampleEvent.returnValues.fee) / 1e18).toFixed(2), 'USDT');
            console.log('   - TX Hash:', sampleEvent.transactionHash);
        }
        
        console.log('\n✅ V12 Final Contract test completed successfully!');
        console.log('📊 Bot will display total deposited as:', (parseFloat(contractStats[2]) / 1e18).toFixed(0), 'USDT');
        
    } catch (error) {
        console.error('❌ V12 Final Contract test failed:', error.message);
        console.error('📍 Error details:', error);
    }
}

// Run the test
testV12FinalConnection().catch(console.error); 
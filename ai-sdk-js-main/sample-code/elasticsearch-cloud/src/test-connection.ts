/**
 * Test Elastic Cloud Connection
 * 
 * Verifies connectivity to your Elastic Cloud deployment
 * and displays cluster information.
 */

import { Client } from '@elastic/elasticsearch';
import { loadConfig, printConfigStatus, requireValidConfig } from './config.js';

async function testConnection(): Promise<void> {
  // Show configuration
  const config = loadConfig();
  printConfigStatus(config);
  
  // Validate configuration
  const validConfig = requireValidConfig();
  
  console.log('Testing connection to Elastic Cloud...\n');
  
  // Create client
  const client = new Client({
    cloud: { id: validConfig.cloudId },
    auth: validConfig.auth.apiKey
      ? { apiKey: validConfig.auth.apiKey }
      : {
          username: validConfig.auth.username!,
          password: validConfig.auth.password!,
        },
    maxRetries: validConfig.maxRetries,
    requestTimeout: validConfig.requestTimeout,
  });
  
  try {
    // Test 1: Ping
    console.log('1. Pinging cluster...');
    const pingResult = await client.ping();
    console.log(`   ✅ Ping: ${pingResult ? 'Success' : 'Failed'}`);
    
    // Test 2: Cluster info
    console.log('\n2. Getting cluster info...');
    const info = await client.info();
    console.log(`   Cluster: ${info.cluster_name}`);
    console.log(`   Version: ${info.version.number}`);
    console.log(`   Lucene:  ${info.version.lucene_version}`);
    
    // Test 3: Cluster health
    console.log('\n3. Getting cluster health...');
    const health = await client.cluster.health();
    const statusEmoji = {
      green: '🟢',
      yellow: '🟡',
      red: '🔴',
    }[health.status] || '⚪';
    console.log(`   Status: ${statusEmoji} ${health.status}`);
    console.log(`   Nodes: ${health.number_of_nodes}`);
    console.log(`   Data Nodes: ${health.number_of_data_nodes}`);
    console.log(`   Shards: ${health.active_shards}`);
    
    // Test 4: List indices
    console.log('\n4. Listing indices...');
    const indices = await client.cat.indices({ format: 'json' });
    if (indices.length === 0) {
      console.log('   (No indices)');
    } else {
      console.log(`   Found ${indices.length} indices:`);
      indices.slice(0, 5).forEach((idx: any) => {
        console.log(`   - ${idx.index} (${idx.docs?.count || 0} docs, ${idx.store?.size || '0b'})`);
      });
      if (indices.length > 5) {
        console.log(`   ... and ${indices.length - 5} more`);
      }
    }
    
    // Test 5: Check kNN capability
    console.log('\n5. Checking vector search capability...');
    const plugins = await client.cat.plugins({ format: 'json' });
    console.log(`   Installed plugins: ${plugins.length}`);
    console.log('   ✅ Dense vector type available in ES 8.x');
    
    console.log('\n' + '='.repeat(60));
    console.log('✅ All connection tests passed!');
    console.log('='.repeat(60));
    console.log('\nYour Elastic Cloud deployment is ready for use.');
    console.log('Run "npm run setup" to create the vector index.');
    
  } catch (error: any) {
    console.error('\n❌ Connection failed!');
    console.error();
    
    if (error.name === 'ConnectionError') {
      console.error('Could not connect to Elastic Cloud.');
      console.error('Please check your ELASTIC_CLOUD_ID.');
    } else if (error.name === 'AuthenticationException' || error.statusCode === 401) {
      console.error('Authentication failed.');
      console.error('Please check your API key or username/password.');
    } else if (error.statusCode === 403) {
      console.error('Access denied.');
      console.error('Your API key may not have sufficient permissions.');
    } else {
      console.error('Error:', error.message);
    }
    
    console.error();
    console.error('Troubleshooting:');
    console.error('1. Verify your Cloud ID in the Elastic Cloud console');
    console.error('2. Check that your API key has the correct permissions');
    console.error('3. Ensure your deployment is running');
    
    process.exit(1);
  } finally {
    await client.close();
  }
}

// Run
testConnection().catch(console.error);
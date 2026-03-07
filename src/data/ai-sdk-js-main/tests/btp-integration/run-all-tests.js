#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAP BTP Integration Tests
 * 
 * Tests all three BTP services: HANA Cloud, AI Core, and Object Store
 * 
 * Usage:
 *   1. Copy .env.example to .env and fill in credentials
 *   2. Run: node run-all-tests.js
 */

// Load environment variables
try {
  require('dotenv').config({ path: __dirname + '/.env' });
} catch (e) {
  console.log('Note: dotenv not installed, using environment variables directly');
}

// =============================================================================
// Test Configuration
// =============================================================================

const testConfig = {
  hana: process.env.TEST_HANA !== 'false',
  aiCore: process.env.TEST_AICORE !== 'false',
  objectStore: process.env.TEST_OBJECTSTORE !== 'false',
  prefix: process.env.TEST_PREFIX || 'TEST_',
};

// =============================================================================
// Test Utilities
// =============================================================================

let passedTests = 0;
let failedTests = 0;
let skippedTests = 0;

function log(message) {
  console.log(`[${new Date().toISOString().slice(11, 19)}] ${message}`);
}

function section(title) {
  console.log('\n' + '═'.repeat(60));
  console.log(`  ${title}`);
  console.log('═'.repeat(60) + '\n');
}

async function test(name, fn) {
  try {
    await fn();
    log(`✅ ${name}`);
    passedTests++;
  } catch (error) {
    log(`❌ ${name}`);
    log(`   Error: ${error.message}`);
    failedTests++;
  }
}

function skip(name, reason) {
  log(`⏭️  ${name} (${reason})`);
  skippedTests++;
}

// =============================================================================
// 1. HANA Cloud Tests
// =============================================================================

async function testHANA() {
  section('1. SAP HANA Cloud Tests');

  const { HANA_HOST, HANA_USER, HANA_PASSWORD, HANA_PORT, HANA_SCHEMA } = process.env;

  if (!HANA_HOST || !HANA_USER || !HANA_PASSWORD) {
    skip('HANA Cloud tests', 'Missing credentials (HANA_HOST, HANA_USER, HANA_PASSWORD)');
    return;
  }

  const hana = require('@sap/hana-client');
  const conn = hana.createConnection();

  const config = {
    serverNode: `${HANA_HOST}:${HANA_PORT || 443}`,
    uid: HANA_USER,
    pwd: HANA_PASSWORD,
    encrypt: 'true',
    sslValidateCertificate: 'true',
  };

  // Connect
  await test('HANA: Connect to database', () => {
    return new Promise((resolve, reject) => {
      conn.connect(config, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  });

  // Query
  await test('HANA: Execute simple query', () => {
    return new Promise((resolve, reject) => {
      conn.exec('SELECT 1 AS VAL FROM DUMMY', (err, result) => {
        if (err) reject(err);
        else if (result[0].VAL !== 1) reject(new Error('Unexpected result'));
        else resolve();
      });
    });
  });

  // Version
  await test('HANA: Check version', () => {
    return new Promise((resolve, reject) => {
      conn.exec('SELECT VERSION FROM SYS.M_DATABASE', (err, result) => {
        if (err) reject(err);
        else {
          log(`   Version: ${result[0].VERSION}`);
          resolve();
        }
      });
    });
  });

  // Vector Engine
  await test('HANA: Check Vector Engine support', () => {
    return new Promise((resolve, reject) => {
      conn.exec(`SELECT COUNT(*) AS CNT FROM SYS.DATA_TYPES WHERE TYPE_NAME = 'REAL_VECTOR'`, (err, result) => {
        if (err) reject(err);
        else if (result[0].CNT > 0) {
          log('   ✓ REAL_VECTOR type available');
          resolve();
        } else {
          reject(new Error('REAL_VECTOR type not found'));
        }
      });
    });
  });

  // Create test table with vector column
  const testTable = `${testConfig.prefix}VECTORS_${Date.now()}`;
  
  await test('HANA: Create vector table', () => {
    return new Promise((resolve, reject) => {
      conn.exec(`
        CREATE TABLE "${testTable}" (
          "ID" NVARCHAR(255) PRIMARY KEY,
          "CONTENT" NCLOB,
          "EMBEDDING" REAL_VECTOR(3),
          "METADATA" NCLOB
        )
      `, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  });

  await test('HANA: Insert vector data', () => {
    return new Promise((resolve, reject) => {
      conn.exec(`
        INSERT INTO "${testTable}" ("ID", "CONTENT", "EMBEDDING") 
        VALUES ('test1', 'Hello World', TO_REAL_VECTOR('[0.1, 0.2, 0.3]'))
      `, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  });

  await test('HANA: Cosine similarity search', () => {
    return new Promise((resolve, reject) => {
      conn.exec(`
        SELECT "ID", COSINE_SIMILARITY("EMBEDDING", TO_REAL_VECTOR('[0.1, 0.2, 0.3]')) AS SCORE
        FROM "${testTable}"
      `, (err, result) => {
        if (err) reject(err);
        else {
          log(`   Score: ${result[0].SCORE}`);
          resolve();
        }
      });
    });
  });

  await test('HANA: Drop test table', () => {
    return new Promise((resolve, reject) => {
      conn.exec(`DROP TABLE "${testTable}"`, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  });

  // Disconnect
  conn.disconnect();
}

// =============================================================================
// 2. AI Core Tests
// =============================================================================

async function testAICore() {
  section('2. SAP AI Core Tests');

  const {
    AICORE_CLIENT_ID,
    AICORE_CLIENT_SECRET,
    AICORE_AUTH_URL,
    AICORE_SERVICE_URL,
    AICORE_BASE_URL,
    AICORE_RESOURCE_GROUP,
    AICORE_EMBEDDING_DEPLOYMENT_ID,
    AICORE_CHAT_DEPLOYMENT_ID,
  } = process.env;

  // Support both AICORE_SERVICE_URL and AICORE_BASE_URL
  const serviceUrl = AICORE_SERVICE_URL || AICORE_BASE_URL;

  if (!AICORE_CLIENT_ID || !AICORE_CLIENT_SECRET || !AICORE_AUTH_URL || !serviceUrl) {
    skip('AI Core tests', 'Missing credentials (AICORE_CLIENT_ID, AICORE_CLIENT_SECRET, etc.)');
    return;
  }

  const https = require('https');
  const url = require('url');
  let accessToken = null;

  // Get OAuth token
  await test('AI Core: Authenticate (OAuth)', async () => {
    return new Promise((resolve, reject) => {
      const authUrl = new URL(AICORE_AUTH_URL);
      const auth = Buffer.from(`${AICORE_CLIENT_ID}:${AICORE_CLIENT_SECRET}`).toString('base64');
      
      const postData = 'grant_type=client_credentials';
      
      const options = {
        hostname: authUrl.hostname,
        port: 443,
        path: authUrl.pathname,
        method: 'POST',
        headers: {
          'Authorization': `Basic ${auth}`,
          'Content-Type': 'application/x-www-form-urlencoded',
          'Content-Length': postData.length,
        },
      };

      const req = https.request(options, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          if (res.statusCode === 200) {
            const json = JSON.parse(data);
            accessToken = json.access_token;
            log(`   Token obtained (expires in ${json.expires_in}s)`);
            resolve();
          } else {
            reject(new Error(`Auth failed: ${res.statusCode} - ${data}`));
          }
        });
      });

      req.on('error', reject);
      req.write(postData);
      req.end();
    });
  });

  if (!accessToken) {
    skip('AI Core API tests', 'No access token');
    return;
  }

  // Helper for API calls
  async function aiCoreRequest(method, path, body = null) {
    return new Promise((resolve, reject) => {
      const apiUrl = new URL(serviceUrl);
      
      const options = {
        hostname: apiUrl.hostname,
        port: 443,
        path: path,
        method: method,
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'AI-Resource-Group': AICORE_RESOURCE_GROUP || 'default',
          'Content-Type': 'application/json',
        },
      };

      const req = https.request(options, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(JSON.parse(data));
          } else {
            reject(new Error(`${res.statusCode}: ${data}`));
          }
        });
      });

      req.on('error', reject);
      if (body) req.write(JSON.stringify(body));
      req.end();
    });
  }

  // List deployments
  let deployments = [];
  await test('AI Core: List deployments', async () => {
    const result = await aiCoreRequest('GET', '/v2/lm/deployments');
    deployments = result.resources || [];
    log(`   Found ${result.count} deployments:`);
    for (const dep of deployments) {
      const model = dep.details?.resources?.backend_details?.model?.name || 'unknown';
      const status = dep.status || 'unknown';
      log(`   - ${dep.id} (${model}) [${status}]`);
    }
  });

  // Test embedding (if deployment configured)
  if (AICORE_EMBEDDING_DEPLOYMENT_ID && !AICORE_EMBEDDING_DEPLOYMENT_ID.includes('xxx')) {
    await test('AI Core: Generate embedding', async () => {
      // Try text-embedding-ada-002 style first
      try {
        const result = await aiCoreRequest('POST', `/v2/inference/deployments/${AICORE_EMBEDDING_DEPLOYMENT_ID}/embeddings`, {
          input: 'Hello, world!'
        });
        if (result.data && result.data[0] && result.data[0].embedding) {
          log(`   Embedding dimensions: ${result.data[0].embedding.length}`);
          return;
        }
      } catch (e) {
        // Try alternative format
        const result = await aiCoreRequest('POST', `/v2/inference/deployments/${AICORE_EMBEDDING_DEPLOYMENT_ID}/invoke`, {
          input: 'Hello, world!'
        });
        log(`   Response: ${JSON.stringify(result).slice(0, 100)}...`);
      }
    });
  } else {
    skip('AI Core: Generate embedding', 'AICORE_EMBEDDING_DEPLOYMENT_ID not configured (set a real deployment ID)');
  }

  // Test chat (if deployment configured)
  if (AICORE_CHAT_DEPLOYMENT_ID && !AICORE_CHAT_DEPLOYMENT_ID.includes('xxx')) {
    // Check if it's an Anthropic model
    const isAnthropic = deployments.some(d => 
      d.id === AICORE_CHAT_DEPLOYMENT_ID && 
      (d.details?.resources?.backend_details?.model?.name || '').includes('anthropic')
    );

    await test('AI Core: Chat completion', async () => {
      if (isAnthropic) {
        // Anthropic Claude format
        const result = await aiCoreRequest('POST', `/v2/inference/deployments/${AICORE_CHAT_DEPLOYMENT_ID}/invoke`, {
          anthropic_version: "bedrock-2023-05-31",
          max_tokens: 50,
          messages: [
            { role: 'user', content: 'Say hello in 3 words.' }
          ]
        });
        if (result.content && result.content[0]) {
          log(`   Response: ${result.content[0].text.slice(0, 50)}...`);
        } else {
          log(`   Response: ${JSON.stringify(result).slice(0, 100)}`);
        }
      } else {
        // OpenAI format
        const result = await aiCoreRequest('POST', `/v2/inference/deployments/${AICORE_CHAT_DEPLOYMENT_ID}/chat/completions`, {
          messages: [
            { role: 'user', content: 'Say hello in 3 words.' }
          ],
          max_tokens: 50
        });
        if (result.choices && result.choices[0]) {
          log(`   Response: ${result.choices[0].message.content.slice(0, 50)}...`);
        }
      }
    });
  } else {
    skip('AI Core: Chat completion', 'AICORE_CHAT_DEPLOYMENT_ID not configured (set a real deployment ID)');
  }
}

// =============================================================================
// 3. Object Store Tests
// =============================================================================

async function testObjectStore() {
  section('3. BTP Object Store (S3) Tests');

  const {
    OBJECT_STORE_ACCESS_KEY,
    OBJECT_STORE_SECRET_KEY,
    OBJECT_STORE_BUCKET,
    OBJECT_STORE_ENDPOINT,
    OBJECT_STORE_REGION,
  } = process.env;

  if (!OBJECT_STORE_ACCESS_KEY || !OBJECT_STORE_SECRET_KEY || !OBJECT_STORE_BUCKET) {
    skip('Object Store tests', 'Missing credentials (OBJECT_STORE_ACCESS_KEY, etc.)');
    return;
  }

  // Try to use AWS SDK if available, otherwise use manual signing
  let S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand, ListObjectsV2Command;
  
  try {
    const s3 = require('@aws-sdk/client-s3');
    S3Client = s3.S3Client;
    PutObjectCommand = s3.PutObjectCommand;
    GetObjectCommand = s3.GetObjectCommand;
    DeleteObjectCommand = s3.DeleteObjectCommand;
    ListObjectsV2Command = s3.ListObjectsV2Command;
  } catch (e) {
    skip('Object Store tests', 'AWS SDK not installed (npm install @aws-sdk/client-s3)');
    return;
  }

  const client = new S3Client({
    endpoint: OBJECT_STORE_ENDPOINT,
    region: OBJECT_STORE_REGION || 'us-east-1',
    credentials: {
      accessKeyId: OBJECT_STORE_ACCESS_KEY,
      secretAccessKey: OBJECT_STORE_SECRET_KEY,
    },
    forcePathStyle: true,
  });

  const testKey = `${testConfig.prefix}test-object-${Date.now()}.txt`;
  const testContent = 'Hello from BTP Object Store integration test!';

  // List objects
  await test('Object Store: List objects', async () => {
    const result = await client.send(new ListObjectsV2Command({
      Bucket: OBJECT_STORE_BUCKET,
      MaxKeys: 10,
    }));
    log(`   Found ${result.KeyCount || 0} objects in bucket`);
  });

  // Put object
  await test('Object Store: Put object', async () => {
    await client.send(new PutObjectCommand({
      Bucket: OBJECT_STORE_BUCKET,
      Key: testKey,
      Body: testContent,
      ContentType: 'text/plain',
    }));
    log(`   Uploaded: ${testKey}`);
  });

  // Get object
  await test('Object Store: Get object', async () => {
    const result = await client.send(new GetObjectCommand({
      Bucket: OBJECT_STORE_BUCKET,
      Key: testKey,
    }));
    const body = await result.Body.transformToString();
    if (body !== testContent) {
      throw new Error('Content mismatch');
    }
    log(`   Content matches (${body.length} bytes)`);
  });

  // Delete object
  await test('Object Store: Delete object', async () => {
    await client.send(new DeleteObjectCommand({
      Bucket: OBJECT_STORE_BUCKET,
      Key: testKey,
    }));
    log(`   Deleted: ${testKey}`);
  });
}

// =============================================================================
// Main
// =============================================================================

async function main() {
  console.log('\n');
  console.log('╔══════════════════════════════════════════════════════════╗');
  console.log('║                                                          ║');
  console.log('║       SAP BTP Integration Tests                          ║');
  console.log('║       HANA Cloud + AI Core + Object Store                ║');
  console.log('║                                                          ║');
  console.log('╚══════════════════════════════════════════════════════════╝');

  const startTime = Date.now();

  if (testConfig.hana) {
    try {
      await testHANA();
    } catch (e) {
      log(`HANA tests failed: ${e.message}`);
    }
  } else {
    skip('HANA Cloud tests', 'TEST_HANA=false');
  }

  if (testConfig.aiCore) {
    try {
      await testAICore();
    } catch (e) {
      log(`AI Core tests failed: ${e.message}`);
    }
  } else {
    skip('AI Core tests', 'TEST_AICORE=false');
  }

  if (testConfig.objectStore) {
    try {
      await testObjectStore();
    } catch (e) {
      log(`Object Store tests failed: ${e.message}`);
    }
  } else {
    skip('Object Store tests', 'TEST_OBJECTSTORE=false');
  }

  const duration = ((Date.now() - startTime) / 1000).toFixed(1);

  section('Test Summary');

  console.log(`  ✅ Passed:  ${passedTests}`);
  console.log(`  ❌ Failed:  ${failedTests}`);
  console.log(`  ⏭️  Skipped: ${skippedTests}`);
  console.log(`  ⏱️  Time:    ${duration}s`);
  console.log();

  if (failedTests > 0) {
    console.log('  ⚠️  Some tests failed. Check the output above.');
    process.exit(1);
  } else if (passedTests > 0) {
    console.log('  🎉 All executed tests passed!');
  } else {
    console.log('  ℹ️  No tests were executed. Check your .env file.');
  }

  console.log();
  process.exit(0);
}

main().catch((e) => {
  console.error('Fatal error:', e);
  process.exit(1);
});
#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Quick HANA Connection Test
 * 
 * This is a simple Node.js script that tests your HANA Cloud connection.
 * No TypeScript compilation required - runs directly with Node.js.
 * 
 * Usage:
 *   1. Set environment variables or create a .env file
 *   2. Run: node tests/integration/quick-test.js
 * 
 * Or run with inline credentials:
 *   HANA_HOST=xxx HANA_USER=xxx HANA_PASSWORD=xxx node tests/integration/quick-test.js
 */

// Try to load dotenv if available
try {
  require('dotenv').config({ path: __dirname + '/.env' });
} catch (e) {
  // dotenv not installed, use environment variables directly
}

const hana = require('@sap/hana-client');

// Configuration from environment
const config = {
  serverNode: `${process.env.HANA_HOST}:${process.env.HANA_PORT || 443}`,
  uid: process.env.HANA_USER,
  pwd: process.env.HANA_PASSWORD,
  encrypt: 'true',
  sslValidateCertificate: 'true',
};

console.log('\n=== HANA Cloud Quick Connection Test ===\n');

// Validate configuration
if (!process.env.HANA_HOST || !process.env.HANA_USER || !process.env.HANA_PASSWORD) {
  console.log('❌ Missing required environment variables!\n');
  console.log('Please set:');
  console.log('  - HANA_HOST (e.g., xxx.hana.prod-us10.hanacloud.ondemand.com)');
  console.log('  - HANA_USER (e.g., DBADMIN)');
  console.log('  - HANA_PASSWORD');
  console.log('\nExample:');
  console.log('  HANA_HOST=xxx HANA_USER=DBADMIN HANA_PASSWORD=secret node quick-test.js');
  console.log('\nOr create a .env file in this directory.');
  process.exit(1);
}

console.log(`Host: ${process.env.HANA_HOST}`);
console.log(`User: ${process.env.HANA_USER}`);
console.log(`Port: ${process.env.HANA_PORT || 443}`);
console.log();

const conn = hana.createConnection();

console.log('🔌 Connecting...');

conn.connect(config, (err) => {
  if (err) {
    console.log('❌ Connection failed!\n');
    console.log('Error:', err.message);
    if (err.code) console.log('Code:', err.code);
    if (err.sqlState) console.log('SQL State:', err.sqlState);
    process.exit(1);
  }

  console.log('✅ Connected successfully!\n');

  // Test 1: Simple query
  console.log('📝 Test 1: Simple query (SELECT 1 FROM DUMMY)');
  conn.exec('SELECT 1 AS "VAL" FROM DUMMY', (err, result) => {
    if (err) {
      console.log('   ❌ Failed:', err.message);
    } else {
      console.log('   ✅ Result:', result[0].VAL);
    }

    // Test 2: HANA version
    console.log('\n📝 Test 2: HANA Version');
    conn.exec('SELECT VERSION FROM SYS.M_DATABASE', (err, result) => {
      if (err) {
        console.log('   ❌ Failed:', err.message);
      } else {
        console.log('   ✅ Version:', result[0].VERSION);
      }

      // Test 3: Check Vector Engine support
      console.log('\n📝 Test 3: Vector Engine Support');
      conn.exec(`
        SELECT COUNT(*) AS CNT FROM SYS.DATA_TYPES 
        WHERE TYPE_NAME = 'REAL_VECTOR'
      `, (err, result) => {
        if (err) {
          console.log('   ⚠️  Could not check:', err.message);
        } else if (result[0].CNT > 0) {
          console.log('   ✅ REAL_VECTOR type available');
        } else {
          console.log('   ⚠️  REAL_VECTOR type not found (older HANA version?)');
        }

        // Test 4: Current schema
        console.log('\n📝 Test 4: Current Schema');
        conn.exec('SELECT CURRENT_SCHEMA FROM DUMMY', (err, result) => {
          if (err) {
            console.log('   ❌ Failed:', err.message);
          } else {
            console.log('   ✅ Schema:', result[0].CURRENT_SCHEMA);
          }

          // Test 5: User privileges
          console.log('\n📝 Test 5: User Privileges');
          conn.exec(`
            SELECT COUNT(*) AS CNT FROM SYS.GRANTED_PRIVILEGES 
            WHERE GRANTEE = CURRENT_USER
          `, (err, result) => {
            if (err) {
              console.log('   ⚠️  Could not check:', err.message);
            } else {
              console.log(`   ✅ User has ${result[0].CNT} privileges`);
            }

            // Clean up
            conn.disconnect();
            
            console.log('\n=== Connection Test Complete ===\n');
            console.log('✅ All basic tests passed!');
            console.log('   Your HANA Cloud credentials are working.\n');
            console.log('Next steps:');
            console.log('  1. Install dependencies: npm install dotenv');
            console.log('  2. Run full tests: npx ts-node tests/integration/run-tests.ts\n');
            
            process.exit(0);
          });
        });
      });
    });
  });
});
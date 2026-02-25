/**
 * Setup Vector Index in Elastic Cloud
 * 
 * Creates an optimized vector index with:
 * - Dense vector field for embeddings
 * - Text field for hybrid search
 * - Metadata fields for filtering
 * - Optimized settings for production
 */

import { Client } from '@elastic/elasticsearch';
import { requireValidConfig } from './config.js';

async function setupIndex(): Promise<void> {
  const config = requireValidConfig();
  
  console.log('='.repeat(60));
  console.log('Setting up Vector Index');
  console.log('='.repeat(60));
  console.log();
  console.log(`Index: ${config.indexName}`);
  console.log(`Dimension: ${config.embeddingDimension}`);
  console.log(`Similarity: ${config.similarity}`);
  console.log();
  
  // Create client
  const client = new Client({
    cloud: { id: config.cloudId },
    auth: config.auth.apiKey
      ? { apiKey: config.auth.apiKey }
      : {
          username: config.auth.username!,
          password: config.auth.password!,
        },
    maxRetries: config.maxRetries,
    requestTimeout: config.requestTimeout,
  });
  
  try {
    // Check if index exists
    const indexExists = await client.indices.exists({ index: config.indexName });
    
    if (indexExists) {
      console.log(`Index "${config.indexName}" already exists.`);
      console.log('Delete it first if you want to recreate.');
      console.log();
      
      // Get current mapping
      const mapping = await client.indices.getMapping({ index: config.indexName });
      console.log('Current mapping:');
      console.log(JSON.stringify(mapping[config.indexName].mappings, null, 2).slice(0, 500));
      console.log();
      
      // Get document count
      const count = await client.count({ index: config.indexName });
      console.log(`Document count: ${count.count}`);
      
      await client.close();
      return;
    }
    
    // Create index with optimized settings
    console.log('Creating index...');
    
    await client.indices.create({
      index: config.indexName,
      settings: {
        // Optimize for search performance
        number_of_shards: 1,
        number_of_replicas: 1,
        'index.knn': true,
        'index.knn.space_type': config.similarity === 'cosine' ? 'cosinesimil' : 
                                config.similarity === 'dot_product' ? 'innerproduct' : 'l2',
        // Refresh interval for near real-time search
        refresh_interval: '1s',
        // Analysis settings for text search
        analysis: {
          analyzer: {
            default: {
              type: 'standard',
            },
          },
        },
      },
      mappings: {
        properties: {
          // Document content
          content: {
            type: 'text',
            analyzer: 'standard',
          },
          
          // Vector embedding
          embedding: {
            type: 'dense_vector',
            dims: config.embeddingDimension,
            index: true,
            similarity: config.similarity,
          },
          
          // Metadata fields
          metadata: {
            type: 'object',
            properties: {
              title: { type: 'keyword' },
              source: { type: 'keyword' },
              category: { type: 'keyword' },
              author: { type: 'keyword' },
              createdAt: { type: 'date' },
              updatedAt: { type: 'date' },
              tags: { type: 'keyword' },
              chunkIndex: { type: 'integer' },
              totalChunks: { type: 'integer' },
            },
            dynamic: true,
          },
          
          // Timestamps
          indexedAt: { type: 'date' },
        },
        // Allow dynamic fields in metadata
        dynamic: 'strict',
      },
    });
    
    console.log('✅ Index created successfully!');
    console.log();
    
    // Create ILM policy (optional, for production)
    console.log('Creating index lifecycle policy...');
    try {
      await client.ilm.putLifecycle({
        name: `${config.indexName}-policy`,
        policy: {
          phases: {
            hot: {
              actions: {
                rollover: {
                  max_size: '50gb',
                  max_age: '30d',
                },
              },
            },
            warm: {
              min_age: '7d',
              actions: {
                shrink: {
                  number_of_shards: 1,
                },
                forcemerge: {
                  max_num_segments: 1,
                },
              },
            },
            delete: {
              min_age: '90d',
              actions: {
                delete: {},
              },
            },
          },
        },
      });
      console.log('✅ ILM policy created');
    } catch (e) {
      console.log('⚠️  ILM policy not created (may require higher license tier)');
    }
    
    // Display index info
    console.log();
    console.log('Index Information:');
    const settings = await client.indices.getSettings({ index: config.indexName });
    const settingsObj = settings[config.indexName].settings as any;
    console.log(`  Shards: ${settingsObj.index?.number_of_shards || 1}`);
    console.log(`  Replicas: ${settingsObj.index?.number_of_replicas || 1}`);
    
    console.log();
    console.log('='.repeat(60));
    console.log('Setup complete!');
    console.log('='.repeat(60));
    console.log();
    console.log('Next steps:');
    console.log('  npm run ingest    - Ingest sample documents');
    console.log('  npm run query     - Run queries');
    console.log('  npm run rag       - Run RAG pipeline');
    
  } catch (error: any) {
    console.error('❌ Failed to create index:', error.message);
    
    if (error.meta?.body?.error) {
      console.error('Details:', JSON.stringify(error.meta.body.error, null, 2));
    }
    
    process.exit(1);
  } finally {
    await client.close();
  }
}

// Run
setupIndex().catch(console.error);
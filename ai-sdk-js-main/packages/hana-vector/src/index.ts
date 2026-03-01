// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAP HANA Cloud Vector Engine
 * 
 * Vector storage and similarity search for SAP HANA Cloud
 * 
 * @packageDocumentation
 */

// HANA Client
export {
  HANAClient,
  createHANAClient,
  createHANAClientFromEnv,
  TransactionClient,
} from './hana-client.js';

// Vector Store
export {
  HANAVectorStore,
  createHANAVectorStore,
  type HnswIndexConfig,
  type InternalEmbeddingConfig,
} from './vector-store.js';

// Knowledge Graph (RDF/SPARQL)
export {
  HANARdfGraph,
  createHANARdfGraph,
  type RdfGraphConfig,
  type SparqlContentType,
  type SparqlQueryOptions,
  type RdfTriple,
  type SparqlResultRow,
  type SparqlSelectResult,
  type OntologyClass,
  type OntologyProperty,
  type OntologySchema,
} from './knowledge-graph.js';

// Types
export type {
  HANAConfig,
  HANAServiceBinding,
  PoolConfig,
  VectorDocument,
  ScoredDocument,
  VectorStoreConfig,
  SearchOptions,
  DistanceMetric,
  VectorColumnType,
  TableDefinition,
  ColumnDefinition,
  QueryResult,
  ColumnMetadata,
  BatchOptions,
} from './types.js';

// Error handling
export {
  HANAError,
  HANAErrorCode,
} from './types.js';

// Utility functions
export {
  parseBinding,
  getConfigFromVcap,
  buildConnectionString,
  validateEmbedding,
  embeddingToVectorString,
  vectorStringToEmbedding,
  escapeIdentifier,
  escapeString,
} from './types.js';
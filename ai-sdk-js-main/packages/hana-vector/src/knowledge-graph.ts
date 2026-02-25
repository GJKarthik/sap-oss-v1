/**
 * SAP HANA Cloud Knowledge Graph (RDF/SPARQL)
 * 
 * Provides RDF graph querying via SPARQL for knowledge graph applications
 */

import { HANAClient } from './hana-client.js';
import { HANAError, HANAErrorCode, escapeIdentifier } from './types.js';

// ============================================================================
// Types
// ============================================================================

/**
 * Configuration for the HANA RDF Graph
 */
export interface RdfGraphConfig {
  /**
   * The URI of the RDF graph to query.
   * Use empty string or 'DEFAULT' for the default graph.
   */
  graphUri?: string;
  
  /**
   * SPARQL CONSTRUCT query to load the schema/ontology
   */
  ontologyQuery?: string;
  
  /**
   * URI of an ontology graph to load
   */
  ontologyUri?: string;
  
  /**
   * If true, automatically extract ontology from instance data
   */
  autoExtractOntology?: boolean;
}

/**
 * SPARQL query result types
 */
export type SparqlContentType = 
  | 'application/sparql-results+json'
  | 'application/sparql-results+xml'
  | 'application/sparql-results+csv'
  | 'text/turtle'
  | 'application/rdf+xml';

/**
 * SPARQL query options
 */
export interface SparqlQueryOptions {
  /**
   * Content type for the response
   * @default 'application/sparql-results+json'
   */
  contentType?: SparqlContentType;
  
  /**
   * Whether to inject FROM clause for the configured graph
   * @default true
   */
  injectFromClause?: boolean;
}

/**
 * RDF Triple
 */
export interface RdfTriple {
  subject: string;
  predicate: string;
  object: string;
}

/**
 * SPARQL SELECT result row
 */
export type SparqlResultRow = Record<string, string | number | boolean | null>;

/**
 * Parsed SPARQL SELECT results
 */
export interface SparqlSelectResult {
  variables: string[];
  results: SparqlResultRow[];
}

/**
 * Ontology class definition
 */
export interface OntologyClass {
  uri: string;
  label: string;
}

/**
 * Ontology property definition
 */
export interface OntologyProperty {
  uri: string;
  label: string;
  type: 'ObjectProperty' | 'DatatypeProperty';
  domain?: string;
  range?: string;
}

/**
 * Extracted ontology schema
 */
export interface OntologySchema {
  classes: OntologyClass[];
  properties: OntologyProperty[];
  raw?: string;
}

// ============================================================================
// HANA RDF Graph
// ============================================================================

/**
 * SAP HANA Cloud Knowledge Graph (RDF/SPARQL)
 * 
 * Provides RDF graph querying via SPARQL for knowledge graph applications
 * 
 * @example
 * ```typescript
 * import { createHANAClient, HANARdfGraph } from '@sap-ai-sdk/hana-vector';
 * 
 * const client = createHANAClient(config);
 * await client.init();
 * 
 * const graph = new HANARdfGraph(client, {
 *   graphUri: 'http://example.com/graph',
 *   autoExtractOntology: true,
 * });
 * 
 * // Execute SPARQL SELECT query
 * const results = await graph.query('SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10');
 * 
 * // Get schema
 * const schema = await graph.getSchema();
 * console.log(schema.classes, schema.properties);
 * ```
 */
export class HANARdfGraph {
  private client: HANAClient;
  private config: RdfGraphConfig;
  private fromClause: string;
  private schema: OntologySchema | null = null;

  constructor(client: HANAClient, config: RdfGraphConfig = {}) {
    this.client = client;
    this.config = config;
    
    // Determine FROM clause
    const graphUri = config.graphUri?.toUpperCase();
    if (!graphUri || graphUri === '' || graphUri === 'DEFAULT') {
      this.fromClause = 'FROM DEFAULT';
    } else {
      this.fromClause = `FROM <${config.graphUri}>`;
    }
  }

  // ==========================================================================
  // SPARQL Query Execution
  // ==========================================================================

  /**
   * Execute a SPARQL query and return raw response
   * 
   * @param sparqlQuery - The SPARQL query string
   * @param options - Query options
   * @returns Raw response string from HANA
   */
  async query(
    sparqlQuery: string,
    options: SparqlQueryOptions = {}
  ): Promise<string> {
    const contentType = options.contentType || 'application/sparql-results+json';
    const injectFrom = options.injectFromClause ?? true;

    // Inject FROM clause if needed
    let query = sparqlQuery;
    if (injectFrom) {
      query = this.injectFromClause(query);
    }

    const requestHeaders = `Accept: ${contentType}\r\nContent-Type: application/sparql-query`;

    try {
      // Execute via stored procedure SYS.SPARQL_EXECUTE
      const results = await this.client.query<{
        OUT_RESULT: string;
        OUT_RESULT_TYPE: string;
      }>(
        `CALL SYS.SPARQL_EXECUTE(?, ?, ?, ?)`,
        [query, requestHeaders, '', '']
      );

      if (results.length === 0) {
        return '';
      }

      return results[0].OUT_RESULT || '';
    } catch (error: any) {
      throw new HANAError(
        `SPARQL query failed: ${error.message}`,
        HANAErrorCode.QUERY_FAILED,
        error.sqlCode,
        error.sqlState,
        error
      );
    }
  }

  /**
   * Execute a SPARQL SELECT query and return parsed results
   * 
   * @param sparqlQuery - The SPARQL SELECT query
   * @returns Parsed SELECT results with variables and rows
   */
  async select(sparqlQuery: string): Promise<SparqlSelectResult> {
    const response = await this.query(sparqlQuery, {
      contentType: 'application/sparql-results+json',
    });

    if (!response) {
      return { variables: [], results: [] };
    }

    try {
      const json = JSON.parse(response);
      const variables = json.head?.vars || [];
      const bindings = json.results?.bindings || [];

      const results = bindings.map((binding: Record<string, { value: string; type: string; datatype?: string }>) => {
        const row: SparqlResultRow = {};
        for (const variable of variables) {
          const cell = binding[variable];
          if (cell) {
            // Convert based on type
            if (cell.type === 'typed-literal' && cell.datatype?.includes('integer')) {
              row[variable] = parseInt(cell.value, 10);
            } else if (cell.type === 'typed-literal' && cell.datatype?.includes('decimal')) {
              row[variable] = parseFloat(cell.value);
            } else if (cell.type === 'typed-literal' && cell.datatype?.includes('boolean')) {
              row[variable] = cell.value === 'true';
            } else {
              row[variable] = cell.value;
            }
          } else {
            row[variable] = null;
          }
        }
        return row;
      });

      return { variables, results };
    } catch {
      throw new HANAError(
        'Failed to parse SPARQL results',
        HANAErrorCode.QUERY_FAILED
      );
    }
  }

  /**
   * Execute a SPARQL CONSTRUCT query and return triples
   * 
   * @param sparqlQuery - The SPARQL CONSTRUCT query
   * @returns Array of RDF triples
   */
  async construct(sparqlQuery: string): Promise<RdfTriple[]> {
    const response = await this.query(sparqlQuery, {
      contentType: 'text/turtle',
      injectFromClause: false,
    });

    // Parse simple turtle format
    // Note: For full turtle parsing, use a dedicated library
    const triples: RdfTriple[] = [];
    const lines = response.split('\n').filter(line => 
      line.trim() && 
      !line.startsWith('@prefix') && 
      !line.startsWith('#')
    );

    for (const line of lines) {
      const match = line.match(/<([^>]+)>\s+<([^>]+)>\s+(<([^>]+)>|"([^"]+)")/);
      if (match) {
        triples.push({
          subject: match[1],
          predicate: match[2],
          object: match[4] || match[5],
        });
      }
    }

    return triples;
  }

  // ==========================================================================
  // Schema / Ontology
  // ==========================================================================

  /**
   * Get or extract the ontology schema
   * 
   * @param forceRefresh - Force re-extraction of schema
   * @returns Ontology schema with classes and properties
   */
  async getSchema(forceRefresh = false): Promise<OntologySchema> {
    if (this.schema && !forceRefresh) {
      return this.schema;
    }

    // Determine which method to use for schema
    if (this.config.ontologyQuery) {
      this.schema = await this.loadSchemaFromQuery(this.config.ontologyQuery);
    } else if (this.config.ontologyUri) {
      const query = `CONSTRUCT {?s ?p ?o} FROM <${this.config.ontologyUri}> WHERE {?s ?p ?o .}`;
      this.schema = await this.loadSchemaFromQuery(query);
    } else if (this.config.autoExtractOntology) {
      this.schema = await this.extractOntologyFromData();
    } else {
      throw new HANAError(
        'No ontology source specified. Use ontologyQuery, ontologyUri, or autoExtractOntology.',
        HANAErrorCode.INVALID_INPUT
      );
    }

    return this.schema;
  }

  /**
   * Load schema from a SPARQL CONSTRUCT query
   */
  private async loadSchemaFromQuery(query: string): Promise<OntologySchema> {
    const response = await this.query(query, {
      contentType: 'text/turtle',
      injectFromClause: false,
    });

    return this.parseOntologyFromTurtle(response);
  }

  /**
   * Auto-extract ontology from instance data
   */
  private async extractOntologyFromData(): Promise<OntologySchema> {
    const query = this.getGenericOntologyQuery();
    const response = await this.query(query, {
      contentType: 'text/turtle',
      injectFromClause: false,
    });

    return this.parseOntologyFromTurtle(response);
  }

  /**
   * Parse ontology from Turtle format
   */
  private parseOntologyFromTurtle(turtle: string): OntologySchema {
    const classes: OntologyClass[] = [];
    const properties: OntologyProperty[] = [];

    const lines = turtle.split('\n');
    const subjects: Map<string, { types: string[]; labels: string[]; domain?: string; range?: string }> = new Map();

    // Simple turtle parsing - extract subjects and their properties
    for (const line of lines) {
      // Match class declarations
      const classMatch = line.match(/<([^>]+)>\s+a\s+owl:Class/);
      if (classMatch) {
        const uri = classMatch[1];
        if (!subjects.has(uri)) {
          subjects.set(uri, { types: [], labels: [] });
        }
        subjects.get(uri)!.types.push('Class');
      }

      // Match property declarations
      const propMatch = line.match(/<([^>]+)>\s+a\s+owl:(ObjectProperty|DatatypeProperty)/);
      if (propMatch) {
        const uri = propMatch[1];
        const type = propMatch[2] as 'ObjectProperty' | 'DatatypeProperty';
        if (!subjects.has(uri)) {
          subjects.set(uri, { types: [], labels: [] });
        }
        subjects.get(uri)!.types.push(type);
      }

      // Match labels
      const labelMatch = line.match(/<([^>]+)>\s+rdfs:label\s+"([^"]+)"/);
      if (labelMatch) {
        const uri = labelMatch[1];
        const label = labelMatch[2];
        if (!subjects.has(uri)) {
          subjects.set(uri, { types: [], labels: [] });
        }
        subjects.get(uri)!.labels.push(label);
      }

      // Match domain
      const domainMatch = line.match(/<([^>]+)>\s+rdfs:domain\s+<([^>]+)>/);
      if (domainMatch) {
        const uri = domainMatch[1];
        if (!subjects.has(uri)) {
          subjects.set(uri, { types: [], labels: [] });
        }
        subjects.get(uri)!.domain = domainMatch[2];
      }

      // Match range
      const rangeMatch = line.match(/<([^>]+)>\s+rdfs:range\s+<([^>]+)>/);
      if (rangeMatch) {
        const uri = rangeMatch[1];
        if (!subjects.has(uri)) {
          subjects.set(uri, { types: [], labels: [] });
        }
        subjects.get(uri)!.range = rangeMatch[2];
      }
    }

    // Build classes and properties arrays
    for (const [uri, data] of subjects.entries()) {
      if (data.types.includes('Class')) {
        classes.push({
          uri,
          label: data.labels[0] || this.extractLocalName(uri),
        });
      }
      if (data.types.includes('ObjectProperty') || data.types.includes('DatatypeProperty')) {
        properties.push({
          uri,
          label: data.labels[0] || this.extractLocalName(uri),
          type: data.types.includes('ObjectProperty') ? 'ObjectProperty' : 'DatatypeProperty',
          domain: data.domain,
          range: data.range,
        });
      }
    }

    return { classes, properties, raw: turtle };
  }

  /**
   * Extract local name from URI
   */
  private extractLocalName(uri: string): string {
    const hashIdx = uri.lastIndexOf('#');
    const slashIdx = uri.lastIndexOf('/');
    const idx = Math.max(hashIdx, slashIdx);
    return idx >= 0 ? uri.slice(idx + 1) : uri;
  }

  /**
   * Generate generic ontology extraction query
   */
  private getGenericOntologyQuery(): string {
    return `
      PREFIX owl: <http://www.w3.org/2002/07/owl#>
      PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
      PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
      PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
      CONSTRUCT {
        ?cls rdf:type owl:Class .
        ?cls rdfs:label ?clsLabel .
        ?rel rdf:type ?propertyType .
        ?rel rdfs:label ?relLabel .
        ?rel rdfs:domain ?domain .
        ?rel rdfs:range ?range .
      }
      ${this.fromClause}
      WHERE {
        {
          SELECT DISTINCT ?domain ?rel ?relLabel ?propertyType ?range
          WHERE {
            ?subj ?rel ?obj .
            ?subj a ?domain .
            OPTIONAL { ?obj a ?rangeClass . }
            FILTER(?rel != rdf:type)
            BIND(IF(isIRI(?obj) = true, owl:ObjectProperty, owl:DatatypeProperty) AS ?propertyType)
            BIND(COALESCE(?rangeClass, DATATYPE(?obj)) AS ?range)
            BIND(STR(?rel) AS ?uriStr)
            BIND(REPLACE(?uriStr, "^.*[/#]", "") AS ?relLabel)
          }
        }
        UNION {
          SELECT DISTINCT ?cls ?clsLabel
          WHERE {
            ?instance a/rdfs:subClassOf* ?cls .
            FILTER (isIRI(?cls)) .
            BIND(STR(?cls) AS ?uriStr)
            BIND(REPLACE(?uriStr, "^.*[/#]", "") AS ?clsLabel)
          }
        }
      }
    `;
  }

  // ==========================================================================
  // Utility Methods
  // ==========================================================================

  /**
   * Inject FROM clause into a SPARQL query
   * 
   * @param query - The SPARQL query
   * @returns Query with FROM clause injected
   */
  private injectFromClause(query: string): string {
    // Check if FROM already exists
    const fromPattern = /\bFROM\b/i;
    if (fromPattern.test(query)) {
      return query;
    }

    // Find WHERE clause and inject before it
    const wherePattern = /\bWHERE\b/i;
    const match = wherePattern.exec(query);
    if (match) {
      return query.slice(0, match.index) + `\n${this.fromClause}\n` + query.slice(match.index);
    }

    throw new HANAError(
      "The SPARQL query does not contain a 'WHERE' clause.",
      HANAErrorCode.INVALID_INPUT
    );
  }

  /**
   * Get the configured graph URI
   */
  getGraphUri(): string | undefined {
    return this.config.graphUri;
  }

  /**
   * Get the FROM clause being used
   */
  getFromClause(): string {
    return this.fromClause;
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a HANA RDF Graph instance
 * 
 * @param client - HANA client instance
 * @param config - RDF graph configuration
 * @returns HANARdfGraph instance
 */
export function createHANARdfGraph(
  client: HANAClient,
  config: RdfGraphConfig = {}
): HANARdfGraph {
  return new HANARdfGraph(client, config);
}
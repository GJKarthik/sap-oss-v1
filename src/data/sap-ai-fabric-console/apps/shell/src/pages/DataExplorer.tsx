import { useState } from 'react';
import './DataExplorer.css';

interface DataSource {
  id: string;
  name: string;
  type: 'hana' | 'vector' | 's3' | 'blob';
  status: 'connected' | 'disconnected' | 'error';
  tables?: number;
  collections?: number;
  lastSync: string;
}

interface TableInfo {
  name: string;
  type: 'table' | 'view' | 'collection';
  rows: number;
  columns: number;
  size: string;
  lastModified: string;
}

interface ColumnInfo {
  name: string;
  type: string;
  nullable: boolean;
  primaryKey: boolean;
}

const dataSources: DataSource[] = [
  { id: 'ds-1', name: 'HANA Cloud Production', type: 'hana', status: 'connected', tables: 156, lastSync: '2m ago' },
  { id: 'ds-2', name: 'Vector Store - Embeddings', type: 'vector', status: 'connected', collections: 12, lastSync: '5m ago' },
  { id: 'ds-3', name: 'S3 Data Lake', type: 's3', status: 'connected', tables: 89, lastSync: '1h ago' },
  { id: 'ds-4', name: 'Azure Blob Storage', type: 'blob', status: 'disconnected', tables: 45, lastSync: '2d ago' },
];

const sampleTables: TableInfo[] = [
  { name: 'PRODUCT_EMBEDDINGS', type: 'collection', rows: 245678, columns: 4, size: '1.2 GB', lastModified: '10m ago' },
  { name: 'CUSTOMER_VECTORS', type: 'collection', rows: 89234, columns: 5, size: '456 MB', lastModified: '1h ago' },
  { name: 'DOCUMENT_CHUNKS', type: 'collection', rows: 156789, columns: 6, size: '789 MB', lastModified: '30m ago' },
  { name: 'FAQ_EMBEDDINGS', type: 'collection', rows: 12345, columns: 4, size: '67 MB', lastModified: '2h ago' },
  { name: 'SALES_DATA', type: 'table', rows: 1234567, columns: 25, size: '2.3 GB', lastModified: '5m ago' },
  { name: 'CUSTOMER_PROFILES', type: 'table', rows: 456789, columns: 18, size: '890 MB', lastModified: '15m ago' },
];

const sampleColumns: ColumnInfo[] = [
  { name: 'ID', type: 'NVARCHAR(36)', nullable: false, primaryKey: true },
  { name: 'EMBEDDING', type: 'REAL_VECTOR(1536)', nullable: false, primaryKey: false },
  { name: 'CONTENT', type: 'NCLOB', nullable: true, primaryKey: false },
  { name: 'METADATA', type: 'NCLOB', nullable: true, primaryKey: false },
  { name: 'CREATED_AT', type: 'TIMESTAMP', nullable: false, primaryKey: false },
  { name: 'SOURCE_DOC', type: 'NVARCHAR(255)', nullable: true, primaryKey: false },
];

const sampleData = [
  { ID: 'emb-001', CONTENT: 'SAP AI Core provides a managed runtime...', SOURCE_DOC: 'guide.pdf', CREATED_AT: '2024-03-15 10:30:00' },
  { ID: 'emb-002', CONTENT: 'Vector embeddings enable semantic search...', SOURCE_DOC: 'docs.md', CREATED_AT: '2024-03-15 10:31:00' },
  { ID: 'emb-003', CONTENT: 'The deployment process involves creating...', SOURCE_DOC: 'api.json', CREATED_AT: '2024-03-15 10:32:00' },
  { ID: 'emb-004', CONTENT: 'HANA Cloud Vector Engine supports multiple...', SOURCE_DOC: 'hana.pdf', CREATED_AT: '2024-03-15 10:33:00' },
  { ID: 'emb-005', CONTENT: 'RAG applications combine retrieval with...', SOURCE_DOC: 'rag.md', CREATED_AT: '2024-03-15 10:34:00' },
];

export function DataExplorerPage() {
  const [selectedSource, setSelectedSource] = useState<DataSource>(dataSources[1]); // Vector store selected by default
  const [selectedTable, setSelectedTable] = useState<TableInfo | null>(sampleTables[0]);
  const [activeView, setActiveView] = useState<'schema' | 'data' | 'query'>('data');
  const [sqlQuery, setSqlQuery] = useState('SELECT * FROM PRODUCT_EMBEDDINGS LIMIT 100');
  const [searchTerm, setSearchTerm] = useState('');

  const getTypeIcon = (type: string) => {
    switch (type) {
      case 'hana': return '🗄️';
      case 'vector': return '🧮';
      case 's3': return '☁️';
      case 'blob': return '📦';
      default: return '💾';
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'connected': return '#22c55e';
      case 'disconnected': return '#6b7280';
      case 'error': return '#ef4444';
      default: return '#6b7280';
    }
  };

  const filteredTables = sampleTables.filter(t => 
    t.name.toLowerCase().includes(searchTerm.toLowerCase())
  );

  return (
    <div className="data-explorer">
      {/* Sidebar - Data Sources & Tables */}
      <div className="explorer-sidebar">
        <div className="sidebar-section">
          <h3>Data Sources</h3>
          <div className="sources-list">
            {dataSources.map((source) => (
              <div 
                key={source.id}
                className={`source-item ${selectedSource.id === source.id ? 'selected' : ''}`}
                onClick={() => setSelectedSource(source)}
              >
                <span className="source-icon">{getTypeIcon(source.type)}</span>
                <div className="source-info">
                  <span className="source-name">{source.name}</span>
                  <span className="source-meta">
                    {source.tables ? `${source.tables} tables` : `${source.collections} collections`}
                  </span>
                </div>
                <span 
                  className="status-dot"
                  style={{ backgroundColor: getStatusColor(source.status) }}
                  title={source.status}
                />
              </div>
            ))}
          </div>
        </div>

        <div className="sidebar-section tables-section">
          <div className="section-header">
            <h3>Tables & Collections</h3>
            <span className="count">{filteredTables.length}</span>
          </div>
          <div className="search-box">
            <input
              type="text"
              placeholder="Search tables..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
            />
          </div>
          <div className="tables-list">
            {filteredTables.map((table) => (
              <div 
                key={table.name}
                className={`table-item ${selectedTable?.name === table.name ? 'selected' : ''}`}
                onClick={() => setSelectedTable(table)}
              >
                <span className="table-icon">
                  {table.type === 'collection' ? '🔷' : table.type === 'view' ? '👁' : '📋'}
                </span>
                <div className="table-info">
                  <span className="table-name">{table.name}</span>
                  <span className="table-meta">{table.rows.toLocaleString()} rows</span>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Main Content */}
      <div className="explorer-main">
        {selectedTable ? (
          <>
            <div className="main-header">
              <div className="header-info">
                <h2>{selectedTable.name}</h2>
                <div className="header-meta">
                  <span className="badge">{selectedTable.type}</span>
                  <span>{selectedTable.rows.toLocaleString()} rows</span>
                  <span>{selectedTable.columns} columns</span>
                  <span>{selectedTable.size}</span>
                  <span>Modified {selectedTable.lastModified}</span>
                </div>
              </div>
              <div className="header-actions">
                <button className="btn-secondary">⬇️ Export</button>
                <button className="btn-secondary">🔄 Refresh</button>
                <button className="btn-primary">✨ AI Analyze</button>
              </div>
            </div>

            {/* View Tabs */}
            <div className="view-tabs">
              <button 
                className={`view-tab ${activeView === 'data' ? 'active' : ''}`}
                onClick={() => setActiveView('data')}
              >
                📊 Data Preview
              </button>
              <button 
                className={`view-tab ${activeView === 'schema' ? 'active' : ''}`}
                onClick={() => setActiveView('schema')}
              >
                🔧 Schema
              </button>
              <button 
                className={`view-tab ${activeView === 'query' ? 'active' : ''}`}
                onClick={() => setActiveView('query')}
              >
                💻 SQL Query
              </button>
            </div>

            {/* Data Preview */}
            {activeView === 'data' && (
              <div className="data-preview">
                <div className="preview-toolbar">
                  <span className="preview-info">Showing 5 of {selectedTable.rows.toLocaleString()} rows</span>
                  <div className="toolbar-actions">
                    <select defaultValue="100">
                      <option value="10">10 rows</option>
                      <option value="50">50 rows</option>
                      <option value="100">100 rows</option>
                      <option value="500">500 rows</option>
                    </select>
                    <button className="btn-icon">⬅️</button>
                    <span>Page 1 of 2457</span>
                    <button className="btn-icon">➡️</button>
                  </div>
                </div>
                <div className="data-table-container">
                  <table className="data-table">
                    <thead>
                      <tr>
                        <th>ID</th>
                        <th>CONTENT</th>
                        <th>SOURCE_DOC</th>
                        <th>CREATED_AT</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleData.map((row, idx) => (
                        <tr key={idx}>
                          <td className="mono">{row.ID}</td>
                          <td className="content-cell" title={row.CONTENT}>
                            {row.CONTENT.substring(0, 50)}...
                          </td>
                          <td>{row.SOURCE_DOC}</td>
                          <td className="mono">{row.CREATED_AT}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* Schema View */}
            {activeView === 'schema' && (
              <div className="schema-view">
                <div className="schema-stats">
                  <div className="stat-card">
                    <span className="stat-value">{sampleColumns.length}</span>
                    <span className="stat-label">Columns</span>
                  </div>
                  <div className="stat-card">
                    <span className="stat-value">1</span>
                    <span className="stat-label">Primary Key</span>
                  </div>
                  <div className="stat-card">
                    <span className="stat-value">1</span>
                    <span className="stat-label">Vector Column</span>
                  </div>
                  <div className="stat-card">
                    <span className="stat-value">{selectedTable.size}</span>
                    <span className="stat-label">Total Size</span>
                  </div>
                </div>
                <div className="schema-table-container">
                  <table className="schema-table">
                    <thead>
                      <tr>
                        <th>Column Name</th>
                        <th>Data Type</th>
                        <th>Nullable</th>
                        <th>Key</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sampleColumns.map((col, idx) => (
                        <tr key={idx}>
                          <td className="mono">{col.name}</td>
                          <td>
                            <span className={`type-badge ${col.type.includes('VECTOR') ? 'vector' : ''}`}>
                              {col.type}
                            </span>
                          </td>
                          <td>{col.nullable ? '✓' : '✗'}</td>
                          <td>{col.primaryKey ? '🔑 PK' : '-'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* SQL Query View */}
            {activeView === 'query' && (
              <div className="query-view">
                <div className="query-editor">
                  <div className="editor-header">
                    <span>SQL Query</span>
                    <div className="editor-actions">
                      <button className="btn-secondary btn-sm">Format</button>
                      <button className="btn-secondary btn-sm">Save</button>
                      <button className="btn-primary btn-sm">▶️ Run Query</button>
                    </div>
                  </div>
                  <textarea
                    className="sql-input"
                    value={sqlQuery}
                    onChange={(e) => setSqlQuery(e.target.value)}
                    rows={6}
                    placeholder="Enter your SQL query..."
                  />
                </div>
                <div className="query-templates">
                  <span className="templates-label">Quick Templates:</span>
                  <button 
                    className="template-btn"
                    onClick={() => setSqlQuery(`SELECT * FROM ${selectedTable.name} LIMIT 100`)}
                  >
                    Select All
                  </button>
                  <button 
                    className="template-btn"
                    onClick={() => setSqlQuery(`SELECT COUNT(*) FROM ${selectedTable.name}`)}
                  >
                    Count Rows
                  </button>
                  <button 
                    className="template-btn"
                    onClick={() => setSqlQuery(`SELECT TOP 10 * FROM ${selectedTable.name}\nORDER BY COSINE_SIMILARITY(EMBEDDING, TO_REAL_VECTOR('[0.1, 0.2, ...]')) DESC`)}
                  >
                    Vector Search
                  </button>
                </div>
                <div className="query-results">
                  <div className="results-header">
                    <span>Results</span>
                    <span className="results-info">5 rows returned in 0.045s</span>
                  </div>
                  <div className="data-table-container">
                    <table className="data-table">
                      <thead>
                        <tr>
                          <th>ID</th>
                          <th>CONTENT</th>
                          <th>SOURCE_DOC</th>
                          <th>CREATED_AT</th>
                        </tr>
                      </thead>
                      <tbody>
                        {sampleData.map((row, idx) => (
                          <tr key={idx}>
                            <td className="mono">{row.ID}</td>
                            <td className="content-cell" title={row.CONTENT}>
                              {row.CONTENT.substring(0, 50)}...
                            </td>
                            <td>{row.SOURCE_DOC}</td>
                            <td className="mono">{row.CREATED_AT}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            )}
          </>
        ) : (
          <div className="no-selection">
            <div className="no-selection-icon">📋</div>
            <p>Select a table or collection to explore</p>
          </div>
        )}
      </div>
    </div>
  );
}
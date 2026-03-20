import { useState } from 'react';
import './RAGStudio.css';

interface Document {
  id: string;
  name: string;
  type: string;
  size: string;
  chunks: number;
  status: 'indexed' | 'processing' | 'error';
  uploadedAt: string;
}

interface Pipeline {
  id: string;
  name: string;
  description: string;
  vectorStore: string;
  embeddingModel: string;
  documents: number;
  queries: number;
  status: 'active' | 'paused' | 'error';
}

const initialPipelines: Pipeline[] = [
  { 
    id: 'pipe-1', 
    name: 'Product Knowledge Base', 
    description: 'SAP product documentation and guides',
    vectorStore: 'HANA Cloud Vector',
    embeddingModel: 'text-embedding-ada-002',
    documents: 245,
    queries: 1523,
    status: 'active'
  },
  { 
    id: 'pipe-2', 
    name: 'Customer Support FAQ', 
    description: 'Support tickets and FAQ responses',
    vectorStore: 'HANA Cloud Vector',
    embeddingModel: 'text-embedding-3-small',
    documents: 89,
    queries: 456,
    status: 'active'
  },
  { 
    id: 'pipe-3', 
    name: 'Technical Documentation', 
    description: 'API docs and technical specs',
    vectorStore: 'HANA Cloud Vector',
    embeddingModel: 'text-embedding-ada-002',
    documents: 167,
    queries: 789,
    status: 'paused'
  },
];

const initialDocuments: Document[] = [
  { id: 'doc-1', name: 'SAP_AI_Core_Guide.pdf', type: 'PDF', size: '2.4 MB', chunks: 156, status: 'indexed', uploadedAt: '2h ago' },
  { id: 'doc-2', name: 'API_Reference.md', type: 'Markdown', size: '345 KB', chunks: 42, status: 'indexed', uploadedAt: '5h ago' },
  { id: 'doc-3', name: 'User_Manual.docx', type: 'Word', size: '1.2 MB', chunks: 89, status: 'processing', uploadedAt: '10m ago' },
  { id: 'doc-4', name: 'FAQ_Collection.json', type: 'JSON', size: '567 KB', chunks: 234, status: 'indexed', uploadedAt: '1d ago' },
];

export function RAGStudioPage() {
  const [pipelines] = useState(initialPipelines);
  const [documents] = useState(initialDocuments);
  const [selectedPipeline, setSelectedPipeline] = useState<Pipeline | null>(pipelines[0]);
  const [activeTab, setActiveTab] = useState<'pipelines' | 'documents' | 'query'>('pipelines');
  const [queryInput, setQueryInput] = useState('');
  const [queryResults, setQueryResults] = useState<Array<{text: string; score: number; source: string}>>([]);
  const [isQuerying, setIsQuerying] = useState(false);

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'active': case 'indexed': return '#22c55e';
      case 'paused': case 'processing': return '#eab308';
      case 'error': return '#ef4444';
      default: return '#6b7280';
    }
  };

  const handleQuery = async () => {
    if (!queryInput.trim()) return;
    
    setIsQuerying(true);
    // Simulate RAG query
    await new Promise(resolve => setTimeout(resolve, 1500));
    
    setQueryResults([
      {
        text: "SAP AI Core provides a managed runtime for AI models with built-in support for training and inference workflows. It integrates seamlessly with SAP BTP services.",
        score: 0.94,
        source: "SAP_AI_Core_Guide.pdf"
      },
      {
        text: "The deployment process involves creating a serving template, building a Docker image, and registering it with the AI Core service using the AI API.",
        score: 0.87,
        source: "API_Reference.md"
      },
      {
        text: "Vector embeddings are stored in HANA Cloud's vector engine, enabling efficient similarity search for RAG applications.",
        score: 0.82,
        source: "User_Manual.docx"
      },
    ]);
    setIsQuerying(false);
  };

  return (
    <div className="rag-studio">
      <div className="page-header">
        <div>
          <h2>RAG Studio</h2>
          <p className="subtitle">Build and manage Retrieval Augmented Generation pipelines</p>
        </div>
        <button className="btn-primary">+ New Pipeline</button>
      </div>

      {/* Tabs */}
      <div className="tabs">
        <button 
          className={`tab ${activeTab === 'pipelines' ? 'active' : ''}`}
          onClick={() => setActiveTab('pipelines')}
        >
          📊 Pipelines
        </button>
        <button 
          className={`tab ${activeTab === 'documents' ? 'active' : ''}`}
          onClick={() => setActiveTab('documents')}
        >
          📄 Documents
        </button>
        <button 
          className={`tab ${activeTab === 'query' ? 'active' : ''}`}
          onClick={() => setActiveTab('query')}
        >
          🔍 Test Query
        </button>
      </div>

      {/* Pipelines Tab */}
      {activeTab === 'pipelines' && (
        <div className="pipelines-section">
          <div className="pipelines-grid">
            {pipelines.map((pipeline) => (
              <div 
                key={pipeline.id} 
                className={`pipeline-card ${selectedPipeline?.id === pipeline.id ? 'selected' : ''}`}
                onClick={() => setSelectedPipeline(pipeline)}
              >
                <div className="pipeline-header">
                  <h3>{pipeline.name}</h3>
                  <span 
                    className="status-badge"
                    style={{ 
                      backgroundColor: `${getStatusColor(pipeline.status)}20`,
                      color: getStatusColor(pipeline.status)
                    }}
                  >
                    {pipeline.status}
                  </span>
                </div>
                <p className="pipeline-desc">{pipeline.description}</p>
                
                <div className="pipeline-stats">
                  <div className="stat">
                    <span className="stat-value">{pipeline.documents}</span>
                    <span className="stat-label">Documents</span>
                  </div>
                  <div className="stat">
                    <span className="stat-value">{pipeline.queries}</span>
                    <span className="stat-label">Queries</span>
                  </div>
                </div>

                <div className="pipeline-config">
                  <div className="config-row">
                    <span className="config-label">Vector Store</span>
                    <span className="config-value">{pipeline.vectorStore}</span>
                  </div>
                  <div className="config-row">
                    <span className="config-label">Embedding</span>
                    <span className="config-value">{pipeline.embeddingModel}</span>
                  </div>
                </div>

                <div className="pipeline-actions">
                  <button className="btn-sm">Configure</button>
                  <button className="btn-sm">Test</button>
                  {pipeline.status === 'active' ? (
                    <button className="btn-sm warning">Pause</button>
                  ) : (
                    <button className="btn-sm success">Activate</button>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Documents Tab */}
      {activeTab === 'documents' && (
        <div className="documents-section">
          <div className="upload-zone">
            <div className="upload-icon">📤</div>
            <p className="upload-text">Drag and drop files here, or click to browse</p>
            <p className="upload-hint">Supported: PDF, DOCX, MD, TXT, JSON (max 50MB)</p>
            <button className="btn-primary">Browse Files</button>
          </div>

          <div className="documents-list">
            <h3>Uploaded Documents ({documents.length})</h3>
            <div className="documents-table">
              <div className="table-header">
                <span>Name</span>
                <span>Type</span>
                <span>Size</span>
                <span>Chunks</span>
                <span>Status</span>
                <span>Uploaded</span>
                <span>Actions</span>
              </div>
              {documents.map((doc) => (
                <div key={doc.id} className="table-row">
                  <span className="doc-name">📄 {doc.name}</span>
                  <span>{doc.type}</span>
                  <span>{doc.size}</span>
                  <span>{doc.chunks}</span>
                  <span>
                    <span 
                      className="status-indicator"
                      style={{ 
                        backgroundColor: `${getStatusColor(doc.status)}20`,
                        color: getStatusColor(doc.status)
                      }}
                    >
                      {doc.status === 'processing' && '⏳ '}
                      {doc.status}
                    </span>
                  </span>
                  <span className="upload-time">{doc.uploadedAt}</span>
                  <span className="actions">
                    <button className="btn-icon" title="View chunks">👁</button>
                    <button className="btn-icon" title="Re-index">🔄</button>
                    <button className="btn-icon delete" title="Delete">🗑</button>
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Query Test Tab */}
      {activeTab === 'query' && (
        <div className="query-section">
          <div className="query-panel">
            <div className="query-config">
              <h3>Test Your RAG Pipeline</h3>
              <div className="form-group">
                <label>Select Pipeline</label>
                <select 
                  value={selectedPipeline?.id || ''} 
                  onChange={(e) => setSelectedPipeline(pipelines.find(p => p.id === e.target.value) || null)}
                >
                  {pipelines.map(p => (
                    <option key={p.id} value={p.id}>{p.name}</option>
                  ))}
                </select>
              </div>
              
              <div className="form-group">
                <label>Query</label>
                <textarea
                  value={queryInput}
                  onChange={(e) => setQueryInput(e.target.value)}
                  placeholder="Enter your question to test the RAG pipeline..."
                  rows={4}
                />
              </div>

              <div className="query-options">
                <div className="option-row">
                  <label>Top K Results</label>
                  <input type="number" defaultValue={3} min={1} max={10} />
                </div>
                <div className="option-row">
                  <label>Min Similarity</label>
                  <input type="number" defaultValue={0.7} min={0} max={1} step={0.1} />
                </div>
              </div>

              <button 
                className="btn-primary btn-query" 
                onClick={handleQuery}
                disabled={isQuerying || !queryInput.trim()}
              >
                {isQuerying ? '🔄 Querying...' : '🔍 Run Query'}
              </button>

              <div className="sample-queries">
                <p className="sample-label">Sample Queries:</p>
                <button className="sample-btn" onClick={() => setQueryInput('How do I deploy a model to SAP AI Core?')}>
                  How do I deploy a model to SAP AI Core?
                </button>
                <button className="sample-btn" onClick={() => setQueryInput('What is the process for creating vector embeddings?')}>
                  What is the process for creating vector embeddings?
                </button>
              </div>
            </div>

            <div className="query-results">
              <h3>Retrieved Chunks ({queryResults.length})</h3>
              {queryResults.length === 0 ? (
                <div className="empty-results">
                  <p>Run a query to see retrieved document chunks</p>
                </div>
              ) : (
                <div className="results-list">
                  {queryResults.map((result, idx) => (
                    <div key={idx} className="result-card">
                      <div className="result-header">
                        <span className="result-rank">#{idx + 1}</span>
                        <span className="result-score" style={{ color: result.score > 0.9 ? '#22c55e' : result.score > 0.8 ? '#eab308' : '#ef4444' }}>
                          Score: {(result.score * 100).toFixed(1)}%
                        </span>
                        <span className="result-source">📄 {result.source}</span>
                      </div>
                      <p className="result-text">{result.text}</p>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
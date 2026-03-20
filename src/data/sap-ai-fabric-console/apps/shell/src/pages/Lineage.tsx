import { useState } from 'react';
import './Lineage.css';

interface LineageNode {
  id: string;
  name: string;
  type: 'source' | 'transform' | 'model' | 'output' | 'storage';
  status: 'active' | 'stale' | 'error';
  lastUpdated: string;
  details?: string;
}

interface LineageEdge {
  from: string;
  to: string;
  label?: string;
}

interface Pipeline {
  id: string;
  name: string;
  description: string;
  nodes: LineageNode[];
  edges: LineageEdge[];
}

const samplePipelines: Pipeline[] = [
  {
    id: 'p1',
    name: 'Product RAG Pipeline',
    description: 'End-to-end RAG pipeline for product documentation',
    nodes: [
      { id: 'n1', name: 'S3: product-docs/', type: 'source', status: 'active', lastUpdated: '2h ago', details: '245 documents' },
      { id: 'n2', name: 'PDF Parser', type: 'transform', status: 'active', lastUpdated: '2h ago', details: 'Extracted 1,234 pages' },
      { id: 'n3', name: 'Text Chunker', type: 'transform', status: 'active', lastUpdated: '2h ago', details: '512 token chunks' },
      { id: 'n4', name: 'Embedding Model', type: 'model', status: 'active', lastUpdated: '2h ago', details: 'text-embedding-ada-002' },
      { id: 'n5', name: 'HANA Vector Store', type: 'storage', status: 'active', lastUpdated: '2h ago', details: '15,678 vectors' },
      { id: 'n6', name: 'RAG Endpoint', type: 'output', status: 'active', lastUpdated: '1h ago', details: '/v1/rag/query' },
    ],
    edges: [
      { from: 'n1', to: 'n2', label: 'raw docs' },
      { from: 'n2', to: 'n3', label: 'text' },
      { from: 'n3', to: 'n4', label: 'chunks' },
      { from: 'n4', to: 'n5', label: 'embeddings' },
      { from: 'n5', to: 'n6', label: 'retrieval' },
    ],
  },
  {
    id: 'p2',
    name: 'Customer Support FAQ',
    description: 'FAQ knowledge base for customer support chatbot',
    nodes: [
      { id: 'm1', name: 'Confluence: Support KB', type: 'source', status: 'active', lastUpdated: '1d ago', details: '89 articles' },
      { id: 'm2', name: 'Zendesk Tickets', type: 'source', status: 'stale', lastUpdated: '3d ago', details: '1,234 resolved' },
      { id: 'm3', name: 'Data Merger', type: 'transform', status: 'active', lastUpdated: '1d ago', details: 'Combined sources' },
      { id: 'm4', name: 'QA Extractor', type: 'transform', status: 'active', lastUpdated: '1d ago', details: '456 QA pairs' },
      { id: 'm5', name: 'Embedding Model', type: 'model', status: 'active', lastUpdated: '1d ago', details: 'text-embedding-3-small' },
      { id: 'm6', name: 'HANA Vector Store', type: 'storage', status: 'active', lastUpdated: '1d ago', details: '2,345 vectors' },
    ],
    edges: [
      { from: 'm1', to: 'm3' },
      { from: 'm2', to: 'm3' },
      { from: 'm3', to: 'm4', label: 'merged data' },
      { from: 'm4', to: 'm5', label: 'QA pairs' },
      { from: 'm5', to: 'm6', label: 'embeddings' },
    ],
  },
  {
    id: 'p3',
    name: 'Financial Analysis Pipeline',
    description: 'Real-time financial data processing and analysis',
    nodes: [
      { id: 'f1', name: 'Market Data API', type: 'source', status: 'active', lastUpdated: '5m ago', details: 'Real-time feed' },
      { id: 'f2', name: 'News Feed', type: 'source', status: 'error', lastUpdated: '2h ago', details: 'Connection failed' },
      { id: 'f3', name: 'Sentiment Analyzer', type: 'model', status: 'active', lastUpdated: '5m ago', details: 'FinBERT model' },
      { id: 'f4', name: 'Risk Calculator', type: 'transform', status: 'active', lastUpdated: '5m ago', details: 'VaR computation' },
      { id: 'f5', name: 'Predictions DB', type: 'storage', status: 'active', lastUpdated: '5m ago', details: 'PostgreSQL' },
      { id: 'f6', name: 'Dashboard API', type: 'output', status: 'active', lastUpdated: '5m ago', details: '/v1/finance/metrics' },
    ],
    edges: [
      { from: 'f1', to: 'f3' },
      { from: 'f2', to: 'f3' },
      { from: 'f1', to: 'f4' },
      { from: 'f3', to: 'f4', label: 'sentiment' },
      { from: 'f4', to: 'f5', label: 'predictions' },
      { from: 'f5', to: 'f6', label: 'query' },
    ],
  },
];

const nodeTypeColors: Record<string, { bg: string; border: string; icon: string }> = {
  source: { bg: '#dbeafe', border: '#3b82f6', icon: '📥' },
  transform: { bg: '#fef3c7', border: '#f59e0b', icon: '⚙️' },
  model: { bg: '#f3e8ff', border: '#a855f7', icon: '🤖' },
  storage: { bg: '#dcfce7', border: '#22c55e', icon: '💾' },
  output: { bg: '#fce7f3', border: '#ec4899', icon: '📤' },
};

export function LineagePage() {
  const [selectedPipeline, setSelectedPipeline] = useState<Pipeline>(samplePipelines[0]);
  const [selectedNode, setSelectedNode] = useState<LineageNode | null>(null);
  const [viewMode, setViewMode] = useState<'graph' | 'table'>('graph');

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'active': return '#22c55e';
      case 'stale': return '#f59e0b';
      case 'error': return '#ef4444';
      default: return '#6b7280';
    }
  };

  const getNodePosition = (index: number, total: number, type: string) => {
    // Simple horizontal layout with some vertical variation by type
    const typeOffsets: Record<string, number> = {
      source: 0,
      transform: 80,
      model: 160,
      storage: 240,
      output: 320,
    };
    const x = 50 + index * 140;
    const y = 100 + (typeOffsets[type] || 0) % 200;
    return { x, y };
  };

  return (
    <div className="lineage-page">
      {/* Header */}
      <div className="lineage-header">
        <div className="header-left">
          <h1>🌳 Data Lineage</h1>
          <p>Track data flow and dependencies across AI pipelines</p>
        </div>
        <div className="header-actions">
          <div className="view-toggle">
            <button 
              className={viewMode === 'graph' ? 'active' : ''}
              onClick={() => setViewMode('graph')}
            >
              Graph View
            </button>
            <button 
              className={viewMode === 'table' ? 'active' : ''}
              onClick={() => setViewMode('table')}
            >
              Table View
            </button>
          </div>
          <button className="btn-primary">+ Add Pipeline</button>
        </div>
      </div>

      <div className="lineage-content">
        {/* Pipeline Selector */}
        <div className="pipeline-sidebar">
          <h3>Pipelines</h3>
          <div className="pipeline-list">
            {samplePipelines.map((pipeline) => {
              const hasError = pipeline.nodes.some(n => n.status === 'error');
              const hasStale = pipeline.nodes.some(n => n.status === 'stale');
              return (
                <div
                  key={pipeline.id}
                  className={`pipeline-item ${selectedPipeline.id === pipeline.id ? 'selected' : ''}`}
                  onClick={() => {
                    setSelectedPipeline(pipeline);
                    setSelectedNode(null);
                  }}
                >
                  <div className="pipeline-item-header">
                    <span className="pipeline-name">{pipeline.name}</span>
                    {hasError && <span className="status-badge error">Error</span>}
                    {hasStale && !hasError && <span className="status-badge stale">Stale</span>}
                    {!hasError && !hasStale && <span className="status-badge active">Active</span>}
                  </div>
                  <span className="pipeline-desc">{pipeline.nodes.length} nodes</span>
                </div>
              );
            })}
          </div>
        </div>

        {/* Main Visualization */}
        <div className="lineage-main">
          {viewMode === 'graph' ? (
            <div className="graph-container">
              <div className="graph-header">
                <h2>{selectedPipeline.name}</h2>
                <p>{selectedPipeline.description}</p>
              </div>
              
              {/* SVG Graph */}
              <div className="graph-canvas">
                <svg viewBox="0 0 900 400" preserveAspectRatio="xMidYMid meet">
                  {/* Draw edges first */}
                  <defs>
                    <marker
                      id="arrowhead"
                      markerWidth="10"
                      markerHeight="7"
                      refX="9"
                      refY="3.5"
                      orient="auto"
                    >
                      <polygon points="0 0, 10 3.5, 0 7" fill="#94a3b8" />
                    </marker>
                  </defs>
                  
                  {selectedPipeline.edges.map((edge, idx) => {
                    const fromNode = selectedPipeline.nodes.find(n => n.id === edge.from);
                    const toNode = selectedPipeline.nodes.find(n => n.id === edge.to);
                    if (!fromNode || !toNode) return null;
                    
                    const fromIdx = selectedPipeline.nodes.indexOf(fromNode);
                    const toIdx = selectedPipeline.nodes.indexOf(toNode);
                    const fromPos = getNodePosition(fromIdx, selectedPipeline.nodes.length, fromNode.type);
                    const toPos = getNodePosition(toIdx, selectedPipeline.nodes.length, toNode.type);
                    
                    return (
                      <g key={idx}>
                        <line
                          x1={fromPos.x + 50}
                          y1={fromPos.y + 30}
                          x2={toPos.x - 10}
                          y2={toPos.y + 30}
                          stroke="#94a3b8"
                          strokeWidth="2"
                          markerEnd="url(#arrowhead)"
                        />
                        {edge.label && (
                          <text
                            x={(fromPos.x + toPos.x) / 2 + 20}
                            y={(fromPos.y + toPos.y) / 2 + 20}
                            fill="#6b7280"
                            fontSize="10"
                          >
                            {edge.label}
                          </text>
                        )}
                      </g>
                    );
                  })}
                  
                  {/* Draw nodes */}
                  {selectedPipeline.nodes.map((node, idx) => {
                    const pos = getNodePosition(idx, selectedPipeline.nodes.length, node.type);
                    const colors = nodeTypeColors[node.type];
                    
                    return (
                      <g
                        key={node.id}
                        transform={`translate(${pos.x}, ${pos.y})`}
                        onClick={() => setSelectedNode(node)}
                        style={{ cursor: 'pointer' }}
                      >
                        <rect
                          width="100"
                          height="60"
                          rx="8"
                          fill={colors.bg}
                          stroke={selectedNode?.id === node.id ? '#0070f3' : colors.border}
                          strokeWidth={selectedNode?.id === node.id ? 3 : 2}
                        />
                        <circle
                          cx="90"
                          cy="10"
                          r="5"
                          fill={getStatusColor(node.status)}
                        />
                        <text x="10" y="25" fontSize="14">{colors.icon}</text>
                        <text x="30" y="25" fontSize="11" fontWeight="500" fill="#1f2937">
                          {node.name.length > 12 ? node.name.substring(0, 12) + '...' : node.name}
                        </text>
                        <text x="10" y="45" fontSize="9" fill="#6b7280">
                          {node.details?.substring(0, 18) || node.type}
                        </text>
                      </g>
                    );
                  })}
                </svg>
              </div>

              {/* Legend */}
              <div className="graph-legend">
                {Object.entries(nodeTypeColors).map(([type, colors]) => (
                  <div key={type} className="legend-item">
                    <span 
                      className="legend-color" 
                      style={{ backgroundColor: colors.bg, borderColor: colors.border }}
                    >
                      {colors.icon}
                    </span>
                    <span className="legend-label">{type.charAt(0).toUpperCase() + type.slice(1)}</span>
                  </div>
                ))}
              </div>
            </div>
          ) : (
            <div className="table-container">
              <table className="lineage-table">
                <thead>
                  <tr>
                    <th>Node</th>
                    <th>Type</th>
                    <th>Status</th>
                    <th>Details</th>
                    <th>Upstream</th>
                    <th>Downstream</th>
                    <th>Last Updated</th>
                  </tr>
                </thead>
                <tbody>
                  {selectedPipeline.nodes.map((node) => {
                    const upstream = selectedPipeline.edges
                      .filter(e => e.to === node.id)
                      .map(e => selectedPipeline.nodes.find(n => n.id === e.from)?.name)
                      .filter(Boolean);
                    const downstream = selectedPipeline.edges
                      .filter(e => e.from === node.id)
                      .map(e => selectedPipeline.nodes.find(n => n.id === e.to)?.name)
                      .filter(Boolean);

                    return (
                      <tr 
                        key={node.id}
                        className={selectedNode?.id === node.id ? 'selected' : ''}
                        onClick={() => setSelectedNode(node)}
                      >
                        <td>
                          <span className="node-icon">{nodeTypeColors[node.type].icon}</span>
                          {node.name}
                        </td>
                        <td>
                          <span 
                            className="type-badge"
                            style={{ 
                              backgroundColor: nodeTypeColors[node.type].bg,
                              color: nodeTypeColors[node.type].border
                            }}
                          >
                            {node.type}
                          </span>
                        </td>
                        <td>
                          <span 
                            className="status-dot"
                            style={{ backgroundColor: getStatusColor(node.status) }}
                          />
                          {node.status}
                        </td>
                        <td>{node.details}</td>
                        <td>{upstream.length > 0 ? upstream.join(', ') : '-'}</td>
                        <td>{downstream.length > 0 ? downstream.join(', ') : '-'}</td>
                        <td>{node.lastUpdated}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Node Details Panel */}
        {selectedNode && (
          <div className="node-details">
            <div className="details-header">
              <h3>{nodeTypeColors[selectedNode.type].icon} {selectedNode.name}</h3>
              <button className="close-btn" onClick={() => setSelectedNode(null)}>✕</button>
            </div>
            <div className="details-content">
              <div className="detail-row">
                <span className="detail-label">Type</span>
                <span 
                  className="type-badge"
                  style={{ 
                    backgroundColor: nodeTypeColors[selectedNode.type].bg,
                    color: nodeTypeColors[selectedNode.type].border
                  }}
                >
                  {selectedNode.type}
                </span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Status</span>
                <span className="status-with-dot">
                  <span 
                    className="status-dot"
                    style={{ backgroundColor: getStatusColor(selectedNode.status) }}
                  />
                  {selectedNode.status}
                </span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Last Updated</span>
                <span>{selectedNode.lastUpdated}</span>
              </div>
              {selectedNode.details && (
                <div className="detail-row">
                  <span className="detail-label">Details</span>
                  <span>{selectedNode.details}</span>
                </div>
              )}
              <div className="detail-row">
                <span className="detail-label">Dependencies</span>
                <span>
                  {selectedPipeline.edges.filter(e => e.to === selectedNode.id).length} upstream,{' '}
                  {selectedPipeline.edges.filter(e => e.from === selectedNode.id).length} downstream
                </span>
              </div>
              <div className="details-actions">
                <button className="btn-secondary">🔄 Refresh</button>
                <button className="btn-secondary">📊 View Metrics</button>
                <button className="btn-secondary">📋 View Logs</button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
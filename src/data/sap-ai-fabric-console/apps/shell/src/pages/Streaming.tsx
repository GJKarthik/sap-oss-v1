import { useState } from 'react';
import './Streaming.css';

interface StreamConfig {
  id: string;
  name: string;
  model: string;
  maxTokens: number;
  temperature: number;
  status: 'active' | 'paused' | 'stopped';
  connections: number;
  throughput: string;
}

const initialConfigs: StreamConfig[] = [
  { id: 'stream-1', name: 'Production Chat', model: 'gpt-4o', maxTokens: 4096, temperature: 0.7, status: 'active', connections: 23, throughput: '1.2K/min' },
  { id: 'stream-2', name: 'Code Assistant', model: 'gpt-4o', maxTokens: 8192, temperature: 0.2, status: 'active', connections: 12, throughput: '800/min' },
  { id: 'stream-3', name: 'Support Bot', model: 'gpt-4o-mini', maxTokens: 2048, temperature: 0.5, status: 'paused', connections: 0, throughput: '0/min' },
  { id: 'stream-4', name: 'Analytics Helper', model: 'gpt-4o-mini', maxTokens: 4096, temperature: 0.3, status: 'active', connections: 8, throughput: '450/min' },
];

export function StreamingPage() {
  const [configs, setConfigs] = useState(initialConfigs);
  const [selectedConfig, setSelectedConfig] = useState<StreamConfig | null>(null);
  const [, setShowNewModal] = useState(false);

  const toggleStatus = (id: string) => {
    setConfigs(prev => prev.map(c => {
      if (c.id === id) {
        const newStatus = c.status === 'active' ? 'paused' : 'active';
        return { ...c, status: newStatus, connections: newStatus === 'active' ? c.connections : 0 };
      }
      return c;
    }));
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'active': return '#22c55e';
      case 'paused': return '#eab308';
      case 'stopped': return '#ef4444';
      default: return '#6b7280';
    }
  };

  const totalConnections = configs.filter(c => c.status === 'active').reduce((sum, c) => sum + c.connections, 0);
  const activeStreams = configs.filter(c => c.status === 'active').length;

  return (
    <div className="streaming-page">
      <div className="page-header">
        <h2>Streaming Management</h2>
        <button className="btn-primary" onClick={() => setShowNewModal(true)}>
          + New Stream Config
        </button>
      </div>

      <div className="stats-bar">
        <div className="stat">
          <span className="stat-value">{activeStreams}</span>
          <span className="stat-label">Active Streams</span>
        </div>
        <div className="stat">
          <span className="stat-value">{totalConnections}</span>
          <span className="stat-label">Total Connections</span>
        </div>
        <div className="stat">
          <span className="stat-value">2.45K</span>
          <span className="stat-label">Req/min</span>
        </div>
        <div className="stat">
          <span className="stat-value">45ms</span>
          <span className="stat-label">Avg Latency</span>
        </div>
      </div>

      <div className="configs-grid">
        {configs.map((config) => (
          <div 
            key={config.id} 
            className={`config-card ${selectedConfig?.id === config.id ? 'selected' : ''}`}
            onClick={() => setSelectedConfig(config)}
          >
            <div className="config-header">
              <h3>{config.name}</h3>
              <span 
                className="status-indicator"
                style={{ backgroundColor: getStatusColor(config.status) }}
              />
            </div>
            
            <div className="config-details">
              <div className="detail-row">
                <span className="detail-label">Model</span>
                <span className="detail-value">{config.model}</span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Max Tokens</span>
                <span className="detail-value">{config.maxTokens}</span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Temperature</span>
                <span className="detail-value">{config.temperature}</span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Connections</span>
                <span className="detail-value">{config.connections}</span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Throughput</span>
                <span className="detail-value">{config.throughput}</span>
              </div>
            </div>

            <div className="config-actions">
              <button 
                className={`btn-toggle ${config.status === 'active' ? 'active' : ''}`}
                onClick={(e) => { e.stopPropagation(); toggleStatus(config.id); }}
              >
                {config.status === 'active' ? '⏸ Pause' : '▶ Resume'}
              </button>
              <button className="btn-edit" onClick={(e) => { e.stopPropagation(); setSelectedConfig(config); }}>
                ⚙ Configure
              </button>
            </div>
          </div>
        ))}
      </div>

      {/* Configuration Panel */}
      {selectedConfig && (
        <div className="config-panel">
          <div className="panel-header">
            <h3>Configure: {selectedConfig.name}</h3>
            <button className="btn-close" onClick={() => setSelectedConfig(null)}>×</button>
          </div>
          <div className="panel-content">
            <div className="form-group">
              <label>Stream Name</label>
              <input type="text" defaultValue={selectedConfig.name} />
            </div>
            <div className="form-group">
              <label>Model</label>
              <select defaultValue={selectedConfig.model}>
                <option value="gpt-4o">gpt-4o</option>
                <option value="gpt-4o-mini">gpt-4o-mini</option>
                <option value="gpt-4-turbo">gpt-4-turbo</option>
              </select>
            </div>
            <div className="form-row">
              <div className="form-group">
                <label>Max Tokens</label>
                <input type="number" defaultValue={selectedConfig.maxTokens} />
              </div>
              <div className="form-group">
                <label>Temperature</label>
                <input type="number" step="0.1" min="0" max="2" defaultValue={selectedConfig.temperature} />
              </div>
            </div>
            <div className="form-group">
              <label>System Prompt</label>
              <textarea rows={4} placeholder="Optional system prompt..." />
            </div>
            <div className="panel-actions">
              <button className="btn-secondary" onClick={() => setSelectedConfig(null)}>Cancel</button>
              <button className="btn-primary">Save Changes</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
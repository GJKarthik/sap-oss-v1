import { useState, useEffect } from 'react';
import './Dashboard.css';

interface ServiceStatus {
  name: string;
  status: 'healthy' | 'warning' | 'error';
  endpoint: string;
  lastCheck: string;
  latency: number;
  requests: number;
}

interface Metric {
  label: string;
  value: string;
  trend: 'up' | 'down' | 'stable';
  change: string;
}

const initialServices: ServiceStatus[] = [
  { name: 'AI Core Streaming', status: 'healthy', endpoint: '/v1/chat/completions', lastCheck: '2s ago', latency: 45, requests: 1234 },
  { name: 'AI SDK JS', status: 'healthy', endpoint: '/v1/models', lastCheck: '5s ago', latency: 32, requests: 567 },
  { name: 'CAP LLM RAG', status: 'healthy', endpoint: '/v1/chat/completions', lastCheck: '3s ago', latency: 89, requests: 890 },
  { name: 'LangChain HANA', status: 'warning', endpoint: '/v1/embeddings', lastCheck: '10s ago', latency: 234, requests: 234 },
  { name: 'OData Vocabularies', status: 'healthy', endpoint: '/v1/chat/completions', lastCheck: '1s ago', latency: 28, requests: 456 },
];

const initialMetrics: Metric[] = [
  { label: 'Requests / min', value: '1,234', trend: 'up', change: '+12%' },
  { label: 'Active Streams', value: '45', trend: 'stable', change: '0%' },
  { label: 'Token Usage', value: '2.3M', trend: 'up', change: '+8%' },
  { label: 'Error Rate', value: '0.02%', trend: 'down', change: '-5%' },
  { label: 'Avg Latency', value: '86ms', trend: 'down', change: '-15%' },
  { label: 'Active Users', value: '23', trend: 'up', change: '+2' },
];

interface RecentRequest {
  id: string;
  service: string;
  model: string;
  tokens: number;
  latency: number;
  status: 'success' | 'error';
  time: string;
}

const recentRequests: RecentRequest[] = [
  { id: 'req-001', service: 'AI Core Streaming', model: 'gpt-4o', tokens: 1234, latency: 456, status: 'success', time: '2s ago' },
  { id: 'req-002', service: 'CAP LLM RAG', model: 'gpt-4o-mini', tokens: 567, latency: 234, status: 'success', time: '5s ago' },
  { id: 'req-003', service: 'LangChain HANA', model: 'text-embedding', tokens: 89, latency: 12, status: 'success', time: '8s ago' },
  { id: 'req-004', service: 'AI Core Streaming', model: 'gpt-4o', tokens: 2345, latency: 789, status: 'error', time: '12s ago' },
  { id: 'req-005', service: 'OData Vocabularies', model: 'gpt-4o-mini', tokens: 345, latency: 123, status: 'success', time: '15s ago' },
];

export function Dashboard() {
  const [services, setServices] = useState(initialServices);
  const [metrics] = useState(initialMetrics);
  const [selectedService, setSelectedService] = useState<string | null>(null);

  // Simulate real-time updates
  useEffect(() => {
    const interval = setInterval(() => {
      setServices(prev => prev.map(s => ({
        ...s,
        latency: Math.max(10, s.latency + Math.floor(Math.random() * 20) - 10),
        requests: s.requests + Math.floor(Math.random() * 5),
      })));
    }, 3000);
    return () => clearInterval(interval);
  }, []);

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'healthy': return '#22c55e';
      case 'warning': return '#eab308';
      case 'error': return '#ef4444';
      default: return '#6b7280';
    }
  };

  const getTrendIcon = (trend: string) => {
    switch (trend) {
      case 'up': return '↑';
      case 'down': return '↓';
      default: return '→';
    }
  };

  const getTrendColor = (trend: string, isPositive: boolean) => {
    if (trend === 'stable') return '#6b7280';
    if (trend === 'up') return isPositive ? '#22c55e' : '#ef4444';
    return isPositive ? '#ef4444' : '#22c55e';
  };

  const healthyCount = services.filter(s => s.status === 'healthy').length;
  const totalCount = services.length;

  return (
    <div className="dashboard">
      <div className="dashboard-header">
        <h2>Dashboard</h2>
        <div className="health-summary">
          <span className="health-count">{healthyCount}/{totalCount}</span>
          <span className="health-label">Services Healthy</span>
        </div>
      </div>
      
      {/* Metrics Grid */}
      <div className="metrics-grid">
        {metrics.map((metric) => (
          <div key={metric.label} className="metric-card">
            <div className="metric-header">
              <span className="metric-label">{metric.label}</span>
              <span 
                className="metric-trend"
                style={{ color: getTrendColor(metric.trend, metric.label !== 'Error Rate') }}
              >
                {getTrendIcon(metric.trend)} {metric.change}
              </span>
            </div>
            <div className="metric-value">{metric.value}</div>
          </div>
        ))}
      </div>
      
      {/* Service Status */}
      <div className="section">
        <h3>Service Status</h3>
        <div className="services-table">
          <div className="table-header">
            <span>Service</span>
            <span>Status</span>
            <span>Endpoint</span>
            <span>Latency</span>
            <span>Requests</span>
            <span>Last Check</span>
          </div>
          {services.map((service) => (
            <div 
              key={service.name} 
              className={`table-row ${selectedService === service.name ? 'selected' : ''}`}
              onClick={() => setSelectedService(service.name === selectedService ? null : service.name)}
            >
              <span className="service-name">{service.name}</span>
              <span>
                <span 
                  className="status-badge"
                  style={{ 
                    backgroundColor: `${getStatusColor(service.status)}20`,
                    color: getStatusColor(service.status)
                  }}
                >
                  <span className="status-dot" style={{ backgroundColor: getStatusColor(service.status) }} />
                  {service.status}
                </span>
              </span>
              <span><code>{service.endpoint}</code></span>
              <span className={service.latency > 200 ? 'latency-warning' : ''}>{service.latency}ms</span>
              <span>{service.requests.toLocaleString()}</span>
              <span className="last-check">{service.lastCheck}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Recent Requests */}
      <div className="section">
        <h3>Recent Requests</h3>
        <div className="requests-table">
          <div className="table-header">
            <span>ID</span>
            <span>Service</span>
            <span>Model</span>
            <span>Tokens</span>
            <span>Latency</span>
            <span>Status</span>
            <span>Time</span>
          </div>
          {recentRequests.map((req) => (
            <div key={req.id} className="table-row">
              <span><code>{req.id}</code></span>
              <span>{req.service}</span>
              <span>{req.model}</span>
              <span>{req.tokens}</span>
              <span>{req.latency}ms</span>
              <span>
                <span className={`request-status ${req.status}`}>
                  {req.status === 'success' ? '✓' : '✗'} {req.status}
                </span>
              </span>
              <span className="last-check">{req.time}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Quick Actions */}
      <div className="section">
        <h3>Quick Actions</h3>
        <div className="actions-grid">
          <button className="action-btn primary">🚀 New Deployment</button>
          <button className="action-btn">🔍 Create RAG Pipeline</button>
          <button className="action-btn">🎮 Open Playground</button>
          <button className="action-btn">📊 View Full Logs</button>
          <button className="action-btn">🛡️ Manage Governance</button>
          <button className="action-btn">⚙️ Settings</button>
        </div>
      </div>
    </div>
  );
}
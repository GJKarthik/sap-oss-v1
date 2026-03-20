import { useState } from 'react';
import './Governance.css';

interface Rule {
  id: string;
  name: string;
  description: string;
  category: 'content' | 'access' | 'cost' | 'compliance' | 'quality';
  severity: 'critical' | 'high' | 'medium' | 'low';
  status: 'active' | 'disabled' | 'testing';
  appliedTo: string[];
  conditions: string;
  action: string;
  triggeredCount: number;
  lastTriggered?: string;
  createdAt: string;
}

const sampleRules: Rule[] = [
  {
    id: 'r1',
    name: 'PII Detection & Masking',
    description: 'Automatically detect and mask personally identifiable information in prompts and responses',
    category: 'compliance',
    severity: 'critical',
    status: 'active',
    appliedTo: ['All Models', 'All Endpoints'],
    conditions: 'IF prompt OR response CONTAINS [SSN, credit_card, phone, email, address]',
    action: 'MASK sensitive data, LOG incident, ALERT compliance team',
    triggeredCount: 1234,
    lastTriggered: '2m ago',
    createdAt: '2024-01-15',
  },
  {
    id: 'r2',
    name: 'Rate Limit Per User',
    description: 'Prevent individual users from exceeding request limits to ensure fair usage',
    category: 'cost',
    severity: 'high',
    status: 'active',
    appliedTo: ['Production Endpoints'],
    conditions: 'IF user_requests_per_minute > 60',
    action: 'THROTTLE requests, RETURN 429, NOTIFY user',
    triggeredCount: 567,
    lastTriggered: '15m ago',
    createdAt: '2024-02-01',
  },
  {
    id: 'r3',
    name: 'Toxic Content Filter',
    description: 'Block responses containing harmful, offensive, or inappropriate content',
    category: 'content',
    severity: 'critical',
    status: 'active',
    appliedTo: ['Customer-facing Models'],
    conditions: 'IF response toxicity_score > 0.7 OR contains_profanity = true',
    action: 'BLOCK response, RETURN safe_fallback, LOG for review',
    triggeredCount: 89,
    lastTriggered: '1h ago',
    createdAt: '2024-01-20',
  },
  {
    id: 'r4',
    name: 'Model Access Control',
    description: 'Restrict access to premium models based on user tier and permissions',
    category: 'access',
    severity: 'medium',
    status: 'active',
    appliedTo: ['GPT-4', 'Claude-3-Opus', 'Premium Models'],
    conditions: 'IF user_tier NOT IN [enterprise, premium] AND model IN [gpt-4, claude-3-opus]',
    action: 'DENY request, REDIRECT to standard_model, SUGGEST upgrade',
    triggeredCount: 456,
    lastTriggered: '30m ago',
    createdAt: '2024-02-15',
  },
  {
    id: 'r5',
    name: 'Output Quality Threshold',
    description: 'Ensure model outputs meet minimum quality standards before delivery',
    category: 'quality',
    severity: 'medium',
    status: 'testing',
    appliedTo: ['RAG Endpoints'],
    conditions: 'IF confidence_score < 0.6 OR relevance_score < 0.5',
    action: 'FLAG for review, ADD disclaimer, TRIGGER fallback retrieval',
    triggeredCount: 234,
    lastTriggered: '5m ago',
    createdAt: '2024-03-01',
  },
  {
    id: 'r6',
    name: 'Cost Budget Alert',
    description: 'Monitor and alert when API costs approach budget thresholds',
    category: 'cost',
    severity: 'high',
    status: 'active',
    appliedTo: ['All API Calls'],
    conditions: 'IF monthly_spend > 80% of budget OR daily_spend > $1000',
    action: 'ALERT admins, SEND email, UPDATE dashboard',
    triggeredCount: 12,
    lastTriggered: '2d ago',
    createdAt: '2024-02-20',
  },
  {
    id: 'r7',
    name: 'GDPR Data Retention',
    description: 'Ensure conversation logs are deleted after retention period expires',
    category: 'compliance',
    severity: 'critical',
    status: 'active',
    appliedTo: ['EU Region Data'],
    conditions: 'IF data_age > 90_days AND region = EU',
    action: 'DELETE data, LOG deletion, NOTIFY data_officer',
    triggeredCount: 45678,
    lastTriggered: '1d ago',
    createdAt: '2024-01-10',
  },
  {
    id: 'r8',
    name: 'Prompt Injection Detection',
    description: 'Detect and block potential prompt injection attacks',
    category: 'content',
    severity: 'critical',
    status: 'active',
    appliedTo: ['All Models'],
    conditions: 'IF prompt MATCHES injection_patterns OR contains_system_override',
    action: 'BLOCK request, LOG attack, ALERT security team, BAN repeated offenders',
    triggeredCount: 23,
    lastTriggered: '6h ago',
    createdAt: '2024-03-05',
  },
];

const categoryConfig = {
  content: { icon: '📝', color: '#f59e0b', label: 'Content Moderation' },
  access: { icon: '🔐', color: '#8b5cf6', label: 'Access Control' },
  cost: { icon: '💰', color: '#22c55e', label: 'Cost Management' },
  compliance: { icon: '⚖️', color: '#3b82f6', label: 'Compliance' },
  quality: { icon: '✨', color: '#ec4899', label: 'Quality Assurance' },
};

const severityConfig = {
  critical: { color: '#dc2626', bg: '#fee2e2' },
  high: { color: '#f59e0b', bg: '#fef3c7' },
  medium: { color: '#3b82f6', bg: '#dbeafe' },
  low: { color: '#6b7280', bg: '#f3f4f6' },
};

export function GovernancePage() {
  const [rules, setRules] = useState<Rule[]>(sampleRules);
  const [selectedRule, setSelectedRule] = useState<Rule | null>(null);
  const [filterCategory, setFilterCategory] = useState<string>('all');
  const [filterStatus, setFilterStatus] = useState<string>('all');
  const [searchQuery, setSearchQuery] = useState('');

  const filteredRules = rules.filter(rule => {
    const matchesCategory = filterCategory === 'all' || rule.category === filterCategory;
    const matchesStatus = filterStatus === 'all' || rule.status === filterStatus;
    const matchesSearch = rule.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
                         rule.description.toLowerCase().includes(searchQuery.toLowerCase());
    return matchesCategory && matchesStatus && matchesSearch;
  });

  const toggleRuleStatus = (ruleId: string) => {
    setRules(rules.map(r => {
      if (r.id === ruleId) {
        return { ...r, status: r.status === 'active' ? 'disabled' : 'active' };
      }
      return r;
    }));
  };

  const stats = {
    total: rules.length,
    active: rules.filter(r => r.status === 'active').length,
    critical: rules.filter(r => r.severity === 'critical' && r.status === 'active').length,
    triggered24h: rules.reduce((sum, r) => sum + (r.lastTriggered?.includes('ago') ? 1 : 0), 0),
  };

  return (
    <div className="governance-page">
      {/* Header */}
      <div className="governance-header">
        <div className="header-left">
          <h1>🛡️ Governance Rules</h1>
          <p>Define and manage AI safety, compliance, and quality policies</p>
        </div>
        <div className="header-actions">
          <button className="btn-secondary">📥 Import Rules</button>
          <button className="btn-secondary">📤 Export</button>
          <button className="btn-primary">+ Create Rule</button>
        </div>
      </div>

      {/* Stats Cards */}
      <div className="stats-grid">
        <div className="stat-card">
          <span className="stat-icon">📋</span>
          <div className="stat-content">
            <span className="stat-value">{stats.total}</span>
            <span className="stat-label">Total Rules</span>
          </div>
        </div>
        <div className="stat-card">
          <span className="stat-icon">✅</span>
          <div className="stat-content">
            <span className="stat-value">{stats.active}</span>
            <span className="stat-label">Active Rules</span>
          </div>
        </div>
        <div className="stat-card critical">
          <span className="stat-icon">🚨</span>
          <div className="stat-content">
            <span className="stat-value">{stats.critical}</span>
            <span className="stat-label">Critical Active</span>
          </div>
        </div>
        <div className="stat-card">
          <span className="stat-icon">⚡</span>
          <div className="stat-content">
            <span className="stat-value">{stats.triggered24h}</span>
            <span className="stat-label">Triggered Today</span>
          </div>
        </div>
      </div>

      {/* Filters */}
      <div className="filters-bar">
        <div className="search-box">
          <span className="search-icon">🔍</span>
          <input
            type="text"
            placeholder="Search rules..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
        </div>
        <div className="filter-group">
          <label>Category:</label>
          <select value={filterCategory} onChange={(e) => setFilterCategory(e.target.value)}>
            <option value="all">All Categories</option>
            {Object.entries(categoryConfig).map(([key, cfg]) => (
              <option key={key} value={key}>{cfg.icon} {cfg.label}</option>
            ))}
          </select>
        </div>
        <div className="filter-group">
          <label>Status:</label>
          <select value={filterStatus} onChange={(e) => setFilterStatus(e.target.value)}>
            <option value="all">All Status</option>
            <option value="active">Active</option>
            <option value="disabled">Disabled</option>
            <option value="testing">Testing</option>
          </select>
        </div>
      </div>

      <div className="governance-content">
        {/* Rules List */}
        <div className="rules-list">
          {filteredRules.map((rule) => (
            <div
              key={rule.id}
              className={`rule-card ${selectedRule?.id === rule.id ? 'selected' : ''} ${rule.status}`}
              onClick={() => setSelectedRule(rule)}
            >
              <div className="rule-header">
                <div className="rule-title">
                  <span 
                    className="category-icon"
                    style={{ backgroundColor: categoryConfig[rule.category].color + '20', color: categoryConfig[rule.category].color }}
                  >
                    {categoryConfig[rule.category].icon}
                  </span>
                  <span className="rule-name">{rule.name}</span>
                </div>
                <div className="rule-badges">
                  <span 
                    className="severity-badge"
                    style={{ 
                      backgroundColor: severityConfig[rule.severity].bg,
                      color: severityConfig[rule.severity].color
                    }}
                  >
                    {rule.severity}
                  </span>
                  <span className={`status-badge ${rule.status}`}>
                    {rule.status}
                  </span>
                </div>
              </div>
              <p className="rule-description">{rule.description}</p>
              <div className="rule-footer">
                <span className="applied-to">
                  Applied to: {rule.appliedTo.slice(0, 2).join(', ')}
                  {rule.appliedTo.length > 2 && ` +${rule.appliedTo.length - 2}`}
                </span>
                <span className="triggered-count">
                  ⚡ {rule.triggeredCount.toLocaleString()} triggers
                </span>
              </div>
            </div>
          ))}
        </div>

        {/* Rule Details */}
        {selectedRule && (
          <div className="rule-details">
            <div className="details-header">
              <h2>
                <span 
                  className="category-icon large"
                  style={{ backgroundColor: categoryConfig[selectedRule.category].color + '20', color: categoryConfig[selectedRule.category].color }}
                >
                  {categoryConfig[selectedRule.category].icon}
                </span>
                {selectedRule.name}
              </h2>
              <button className="close-btn" onClick={() => setSelectedRule(null)}>✕</button>
            </div>

            <div className="details-content">
              <div className="detail-section">
                <h4>Description</h4>
                <p>{selectedRule.description}</p>
              </div>

              <div className="detail-row-grid">
                <div className="detail-item">
                  <label>Category</label>
                  <span style={{ color: categoryConfig[selectedRule.category].color }}>
                    {categoryConfig[selectedRule.category].icon} {categoryConfig[selectedRule.category].label}
                  </span>
                </div>
                <div className="detail-item">
                  <label>Severity</label>
                  <span 
                    className="severity-badge"
                    style={{ 
                      backgroundColor: severityConfig[selectedRule.severity].bg,
                      color: severityConfig[selectedRule.severity].color
                    }}
                  >
                    {selectedRule.severity}
                  </span>
                </div>
                <div className="detail-item">
                  <label>Status</label>
                  <div className="status-toggle">
                    <span className={`status-badge ${selectedRule.status}`}>{selectedRule.status}</span>
                    <button 
                      className="toggle-btn"
                      onClick={() => toggleRuleStatus(selectedRule.id)}
                    >
                      {selectedRule.status === 'active' ? '⏸ Disable' : '▶ Enable'}
                    </button>
                  </div>
                </div>
                <div className="detail-item">
                  <label>Created</label>
                  <span>{selectedRule.createdAt}</span>
                </div>
              </div>

              <div className="detail-section">
                <h4>Applied To</h4>
                <div className="tags">
                  {selectedRule.appliedTo.map((target, idx) => (
                    <span key={idx} className="tag">{target}</span>
                  ))}
                </div>
              </div>

              <div className="detail-section">
                <h4>Conditions</h4>
                <code className="code-block">{selectedRule.conditions}</code>
              </div>

              <div className="detail-section">
                <h4>Action</h4>
                <code className="code-block action">{selectedRule.action}</code>
              </div>

              <div className="detail-section metrics">
                <h4>Metrics</h4>
                <div className="metrics-grid">
                  <div className="metric">
                    <span className="metric-value">{selectedRule.triggeredCount.toLocaleString()}</span>
                    <span className="metric-label">Total Triggers</span>
                  </div>
                  <div className="metric">
                    <span className="metric-value">{selectedRule.lastTriggered || 'Never'}</span>
                    <span className="metric-label">Last Triggered</span>
                  </div>
                </div>
              </div>

              <div className="details-actions">
                <button className="btn-secondary">✏️ Edit Rule</button>
                <button className="btn-secondary">📊 View Logs</button>
                <button className="btn-secondary">🧪 Test Rule</button>
                <button className="btn-danger">🗑️ Delete</button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
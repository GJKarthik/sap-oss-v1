import { useState } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import './Shell.css';

interface NavItem {
  path: string;
  label: string;
  icon: string;
}

const navItems: NavItem[] = [
  { path: '/', label: 'Dashboard', icon: '📊' },
  { path: '/streaming', label: 'Streaming', icon: '📡' },
  { path: '/deployments', label: 'Deployments', icon: '🚀' },
  { path: '/rag', label: 'RAG Studio', icon: '🔍' },
  { path: '/governance', label: 'Governance', icon: '🛡️' },
  { path: '/data', label: 'Data Explorer', icon: '💾' },
  { path: '/playground', label: 'Playground', icon: '🎮' },
  { path: '/lineage', label: 'Lineage', icon: '🌳' },
];

interface ShellProps {
  children: React.ReactNode;
}

export function Shell({ children }: ShellProps) {
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const navigate = useNavigate();
  const location = useLocation();
  const { user, logout } = useAuth();

  return (
    <div className={`shell ${sidebarCollapsed ? 'sidebar-collapsed' : ''}`}>
      {/* Top Bar */}
      <header className="topbar">
        <div className="topbar-left">
          <button
            className="sidebar-toggle"
            onClick={() => setSidebarCollapsed(!sidebarCollapsed)}
          >
            ☰
          </button>
          <h1 className="app-title">SAP AI Fabric Console</h1>
        </div>
        <div className="topbar-right">
          <span className="user-name">{user?.name || 'User'}</span>
          <button className="logout-btn" onClick={logout}>
            Logout
          </button>
        </div>
      </header>

      {/* Sidebar */}
      <nav className="sidebar">
        <ul className="nav-list">
          {navItems.map((item) => (
            <li
              key={item.path}
              className={`nav-item ${location.pathname === item.path ? 'active' : ''}`}
              onClick={() => navigate(item.path)}
            >
              <span className="nav-icon">{item.icon}</span>
              {!sidebarCollapsed && <span className="nav-label">{item.label}</span>}
            </li>
          ))}
        </ul>
      </nav>

      {/* Main Content */}
      <main className="content">{children}</main>
    </div>
  );
}
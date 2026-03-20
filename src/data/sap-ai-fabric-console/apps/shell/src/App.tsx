import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { Shell } from './components/Shell';
import { Dashboard } from './pages/Dashboard';
import { StreamingPage } from './pages/Streaming';
import { PlaygroundPage } from './pages/Playground';
import { RAGStudioPage } from './pages/RAGStudio';
import { DataExplorerPage } from './pages/DataExplorer';
import { LineagePage } from './pages/Lineage';
import { GovernancePage } from './pages/Governance';
import { AuthProvider, useAuth } from './contexts/AuthContext';
import { LoginPage } from './pages/Login';

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth();
  
  if (isLoading) {
    return <div className="loading">Loading...</div>;
  }
  
  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }
  
  return <>{children}</>;
}

function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route
            path="/*"
            element={
              <ProtectedRoute>
                <Shell>
                  <Routes>
                    <Route path="/" element={<Dashboard />} />
                    <Route path="/streaming" element={<StreamingPage />} />
                    <Route path="/deployments" element={<PlaceholderPage title="Deployments" icon="🚀" />} />
                    <Route path="/rag" element={<RAGStudioPage />} />
                    <Route path="/governance" element={<GovernancePage />} />
                    <Route path="/data" element={<DataExplorerPage />} />
                    <Route path="/playground" element={<PlaygroundPage />} />
                    <Route path="/lineage" element={<LineagePage />} />
                  </Routes>
                </Shell>
              </ProtectedRoute>
            }
          />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}

// Placeholder component for pages not yet implemented
function PlaceholderPage({ title, icon }: { title: string; icon: string }) {
  return (
    <div style={{ textAlign: 'center', padding: '4rem 2rem' }}>
      <div style={{ fontSize: '4rem', marginBottom: '1rem' }}>{icon}</div>
      <h2 style={{ marginBottom: '0.5rem' }}>{title}</h2>
      <p style={{ color: '#6b7280' }}>This page is under development.</p>
    </div>
  );
}

export default App;
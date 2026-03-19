/**
 * Adaptive Layout — React Component
 * 
 * A layout container that adapts grid, spacing, and sidebar based on context.
 * 
 * Features:
 * - Responsive grid columns from adaptation decisions
 * - Adaptive spacing from CSS variables
 * - Collapsible sidebar with learned state
 * - Panel ordering from user preferences
 */

import React, { useState, useEffect, useCallback } from 'react';
import { useAdaptation, useAdaptiveLayout } from '../../core/adaptation/react/use-adaptation';
import { createCaptureHooks } from '../../core/capture/capture-service';
import './AdaptiveLayout.css';

// ============================================================================
// TYPES
// ============================================================================

export interface Panel {
  id: string;
  title: string;
  content: React.ReactNode;
  defaultCollapsed?: boolean;
}

export interface AdaptiveLayoutProps {
  children: React.ReactNode;
  layoutId?: string;
  sidebar?: React.ReactNode;
  panels?: Panel[];
  className?: string;
}

// ============================================================================
// COMPONENT
// ============================================================================

export function AdaptiveLayout({
  children,
  layoutId = 'main-layout',
  sidebar,
  panels,
  className = '',
}: AdaptiveLayoutProps) {
  const { layout, confidence } = useAdaptation();
  const { gridStyle, densityClass, spacing } = useAdaptiveLayout();
  
  const capture = React.useMemo(
    () => createCaptureHooks({ componentType: 'layout', componentId: layoutId }),
    [layoutId]
  );
  
  // Sidebar state from adaptation
  const [sidebarState, setSidebarState] = useState(layout.sidebarState);
  
  useEffect(() => {
    if (confidence > 0.3) {
      setSidebarState(layout.sidebarState);
    }
  }, [layout.sidebarState, confidence]);
  
  const toggleSidebar = useCallback(() => {
    const newState = sidebarState === 'expanded' ? 'collapsed' : 'expanded';
    setSidebarState(newState);
    capture.captureClick(`sidebar-${newState}`);
  }, [sidebarState, capture]);
  
  // Panel collapse states from adaptation
  const [collapsedPanels, setCollapsedPanels] = useState<Set<string>>(
    new Set(layout.autoCollapsePanels)
  );
  
  useEffect(() => {
    if (confidence > 0.3 && layout.autoCollapsePanels.length > 0) {
      setCollapsedPanels(new Set(layout.autoCollapsePanels));
    }
  }, [layout.autoCollapsePanels, confidence]);
  
  const togglePanel = useCallback((panelId: string) => {
    setCollapsedPanels(prev => {
      const next = new Set(prev);
      if (next.has(panelId)) {
        next.delete(panelId);
        capture.captureExpand(panelId);
      } else {
        next.add(panelId);
        capture.captureCollapse(panelId);
      }
      return next;
    });
  }, [capture]);
  
  // Order panels based on adaptation
  const orderedPanels = React.useMemo(() => {
    if (!panels || layout.panelOrder.length === 0) return panels;
    
    return [...panels].sort((a, b) => {
      const aIndex = layout.panelOrder.indexOf(a.id);
      const bIndex = layout.panelOrder.indexOf(b.id);
      if (aIndex === -1) return 1;
      if (bIndex === -1) return -1;
      return aIndex - bIndex;
    });
  }, [panels, layout.panelOrder]);

  return (
    <div 
      className={`adaptive-layout ${densityClass} ${className}`}
      data-sidebar={sidebarState}
      style={{
        '--grid-columns': layout.gridColumns,
        '--spacing': `${spacing}px`,
      } as React.CSSProperties}
    >
      {/* Sidebar */}
      {sidebar && (
        <aside 
          className={`layout-sidebar ${sidebarState}`}
          aria-label="Sidebar"
        >
          <button
            className="sidebar-toggle"
            onClick={toggleSidebar}
            aria-expanded={sidebarState === 'expanded'}
            aria-label={sidebarState === 'expanded' ? 'Collapse sidebar' : 'Expand sidebar'}
          >
            <span className="toggle-icon" aria-hidden="true">
              {sidebarState === 'expanded' ? '◀' : '▶'}
            </span>
          </button>
          
          <div className="sidebar-content">
            {sidebar}
          </div>
        </aside>
      )}
      
      {/* Main Content */}
      <main className="layout-main" style={gridStyle}>
        {children}
      </main>
      
      {/* Panels */}
      {orderedPanels && orderedPanels.length > 0 && (
        <aside className="layout-panels" aria-label="Panels">
          {orderedPanels.map(panel => (
            <section
              key={panel.id}
              className={`panel ${collapsedPanels.has(panel.id) ? 'collapsed' : 'expanded'}`}
              aria-labelledby={`panel-title-${panel.id}`}
            >
              <header className="panel-header">
                <button
                  className="panel-toggle"
                  onClick={() => togglePanel(panel.id)}
                  aria-expanded={!collapsedPanels.has(panel.id)}
                  aria-controls={`panel-content-${panel.id}`}
                >
                  <span className="toggle-icon" aria-hidden="true">
                    {collapsedPanels.has(panel.id) ? '▶' : '▼'}
                  </span>
                  <h2 id={`panel-title-${panel.id}`}>{panel.title}</h2>
                </button>
              </header>

              <div
                id={`panel-content-${panel.id}`}
                className="panel-content"
                hidden={collapsedPanels.has(panel.id)}
              >
                {panel.content}
              </div>
            </section>
          ))}
        </aside>
      )}
    </div>
  );
}

// ============================================================================
// ADAPTIVE GRID COMPONENT
// ============================================================================

export interface AdaptiveGridProps {
  children: React.ReactNode;
  minColumnWidth?: string;
  className?: string;
}

/**
 * A grid container that adapts its columns based on adaptation decisions.
 */
export function AdaptiveGrid({
  children,
  minColumnWidth = '250px',
  className = '',
}: AdaptiveGridProps) {
  const { gridStyle, densityClass } = useAdaptiveLayout();

  return (
    <div
      className={`adaptive-grid ${densityClass} ${className}`}
      style={{
        ...gridStyle,
        gridTemplateColumns: `repeat(auto-fit, minmax(${minColumnWidth}, 1fr))`,
      }}
    >
      {children}
    </div>
  );
}

// ============================================================================
// ADAPTIVE CARD COMPONENT
// ============================================================================

export interface AdaptiveCardProps {
  children: React.ReactNode;
  title?: string;
  collapsible?: boolean;
  defaultCollapsed?: boolean;
  className?: string;
}

/**
 * A card that respects density and spacing adaptations.
 */
export function AdaptiveCard({
  children,
  title,
  collapsible = false,
  defaultCollapsed = false,
  className = '',
}: AdaptiveCardProps) {
  const { densityClass, spacing } = useAdaptiveLayout();
  const [collapsed, setCollapsed] = useState(defaultCollapsed);

  return (
    <div
      className={`adaptive-card ${densityClass} ${className}`}
      style={{ '--spacing': `${spacing}px` } as React.CSSProperties}
    >
      {title && (
        <header className="card-header">
          {collapsible ? (
            <button
              className="card-toggle"
              onClick={() => setCollapsed(!collapsed)}
              aria-expanded={!collapsed}
            >
              <span className="toggle-icon" aria-hidden="true">
                {collapsed ? '▶' : '▼'}
              </span>
              <h3>{title}</h3>
            </button>
          ) : (
            <h3>{title}</h3>
          )}
        </header>
      )}

      <div className="card-content" hidden={collapsible && collapsed}>
        {children}
      </div>
    </div>
  );
}


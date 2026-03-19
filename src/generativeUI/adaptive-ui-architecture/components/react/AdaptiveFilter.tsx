/**
 * Adaptive Filter Panel — React Component
 * 
 * A filter panel that adapts to user behavior.
 * 
 * Features:
 * - Shows frequently used filters first
 * - Suggests filter values from patterns
 * - Adapts density based on preferences
 * - Accessible with WCAG AA compliance
 */

import React, { useState, useMemo, useCallback } from 'react';
import { useAdaptation, useAdaptiveLayout } from '../../core/adaptation/react/use-adaptation';
import { createCaptureHooks } from '../../core/capture/capture-service';
import './AdaptiveFilter.css';

// ============================================================================
// TYPES
// ============================================================================

export interface FilterField {
  id: string;
  label: string;
  type: 'text' | 'select' | 'date' | 'number' | 'boolean';
  options?: Array<{ value: string; label: string }>;
  placeholder?: string;
}

export interface AdaptiveFilterProps {
  fields: FilterField[];
  filterId: string;
  values: Record<string, unknown>;
  onChange: (field: string, value: unknown) => void;
  onApply?: () => void;
  onClear?: () => void;
  autoApply?: boolean;
}

// ============================================================================
// COMPONENT
// ============================================================================

export function AdaptiveFilter({
  fields,
  filterId,
  values,
  onChange,
  onApply,
  onClear,
  autoApply: autoApplyProp,
}: AdaptiveFilterProps) {
  const { content, interaction, confidence } = useAdaptation();
  const { densityClass, spacing } = useAdaptiveLayout();
  
  const capture = useMemo(
    () => createCaptureHooks({ componentType: 'filter', componentId: filterId }),
    [filterId]
  );
  
  const [expanded, setExpanded] = useState(true);
  
  // Get auto-apply preference from model or prop
  const autoApply = autoApplyProp ?? (confidence > 0.3 ? true : false);
  
  // Get frequent filter values for suggestions
  const frequentFilters = content.suggestedFilters || [];
  
  // Order fields: frequently used first
  const orderedFields = useMemo(() => {
    const frequentFieldIds = frequentFilters.map(f => f.field);
    return [...fields].sort((a, b) => {
      const aFreq = frequentFieldIds.indexOf(a.id);
      const bFreq = frequentFieldIds.indexOf(b.id);
      if (aFreq !== -1 && bFreq === -1) return -1;
      if (aFreq === -1 && bFreq !== -1) return 1;
      if (aFreq !== -1 && bFreq !== -1) return aFreq - bFreq;
      return 0;
    });
  }, [fields, frequentFilters]);
  
  // Handle field change
  const handleChange = useCallback((fieldId: string, value: unknown) => {
    capture.captureFilter(fieldId, value);
    onChange(fieldId, value);
    
    if (autoApply) {
      onApply?.();
    }
  }, [capture, onChange, onApply, autoApply]);
  
  // Handle clear
  const handleClear = useCallback(() => {
    capture.captureClick('clear-filters');
    onClear?.();
  }, [capture, onClear]);
  
  // Get suggestions for a specific field
  const getSuggestions = useCallback((fieldId: string) => {
    return frequentFilters
      .filter(f => f.field === fieldId)
      .map(f => ({ value: f.value, reason: f.reason }));
  }, [frequentFilters]);

  return (
    <div 
      className={`adaptive-filter ${densityClass}`}
      style={{ '--spacing': `${spacing}px` } as React.CSSProperties}
    >
      <div className="filter-header">
        <button
          className="filter-toggle"
          onClick={() => setExpanded(!expanded)}
          aria-expanded={expanded}
          aria-controls={`filter-panel-${filterId}`}
        >
          <span className="toggle-icon" aria-hidden="true">
            {expanded ? '▼' : '▶'}
          </span>
          <span className="filter-title">Filters</span>
          {Object.values(values).filter(Boolean).length > 0 && (
            <span className="active-count" aria-label="Active filters">
              {Object.values(values).filter(Boolean).length}
            </span>
          )}
        </button>
        
        {Object.values(values).filter(Boolean).length > 0 && (
          <button
            className="clear-btn"
            onClick={handleClear}
            aria-label="Clear all filters"
          >
            Clear all
          </button>
        )}
      </div>
      
      <div
        id={`filter-panel-${filterId}`}
        className={`filter-fields ${expanded ? 'expanded' : 'collapsed'}`}
        role="group"
        aria-label="Filter options"
      >
        {orderedFields.map(field => (
          <FilterFieldComponent
            key={field.id}
            field={field}
            value={values[field.id]}
            onChange={(value) => handleChange(field.id, value)}
            suggestions={getSuggestions(field.id)}
            interaction={interaction}
          />
        ))}
        
        {!autoApply && (
          <button
            className="apply-btn"
            onClick={onApply}
            aria-label="Apply filters"
          >
            Apply Filters
          </button>
        )}
      </div>
    </div>
  );
}

// ============================================================================
// FIELD COMPONENT
// ============================================================================

interface FilterFieldComponentProps {
  field: FilterField;
  value: unknown;
  onChange: (value: unknown) => void;
  suggestions: Array<{ value: unknown; reason?: string }>;
  interaction: { touchTargetScale: number };
}

function FilterFieldComponent({
  field,
  value,
  onChange,
  suggestions,
  interaction,
}: FilterFieldComponentProps) {
  const inputId = `filter-${field.id}`;

  return (
    <div className="filter-field">
      <label htmlFor={inputId}>{field.label}</label>

      {field.type === 'select' ? (
        <select
          id={inputId}
          value={String(value || '')}
          onChange={(e) => onChange(e.target.value)}
          style={{ minHeight: `${44 * interaction.touchTargetScale}px` }}
        >
          <option value="">{field.placeholder || 'Select...'}</option>
          {field.options?.map(opt => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
      ) : field.type === 'boolean' ? (
        <div className="checkbox-wrapper">
          <input
            type="checkbox"
            id={inputId}
            checked={Boolean(value)}
            onChange={(e) => onChange(e.target.checked)}
          />
          <span className="checkbox-label">{field.placeholder || 'Yes'}</span>
        </div>
      ) : (
        <input
          type={field.type === 'number' ? 'number' : field.type === 'date' ? 'date' : 'text'}
          id={inputId}
          value={String(value || '')}
          onChange={(e) => onChange(e.target.value)}
          placeholder={field.placeholder}
          style={{ minHeight: `${44 * interaction.touchTargetScale}px` }}
        />
      )}

      {/* Suggestions */}
      {suggestions.length > 0 && (
        <div className="field-suggestions">
          {suggestions.slice(0, 3).map((sug, i) => (
            <button
              key={i}
              className="suggestion-chip"
              onClick={() => onChange(sug.value)}
              aria-label={`Quick select: ${sug.value}`}
            >
              {String(sug.value)}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}


import React from 'react';

export interface StatusBadgeProps {
  status: 'healthy' | 'warning' | 'error' | 'unknown';
  label?: string;
}

const statusColors: Record<string, { bg: string; text: string }> = {
  healthy: { bg: '#dcfce7', text: '#16a34a' },
  warning: { bg: '#fef3c7', text: '#d97706' },
  error: { bg: '#fee2e2', text: '#dc2626' },
  unknown: { bg: '#f3f4f6', text: '#6b7280' },
};

export function StatusBadge({ status, label }: StatusBadgeProps) {
  const colors = statusColors[status] || statusColors.unknown;
  
  const style: React.CSSProperties = {
    display: 'inline-flex',
    alignItems: 'center',
    gap: '0.375rem',
    padding: '0.25rem 0.5rem',
    borderRadius: '9999px',
    fontSize: '0.75rem',
    fontWeight: 500,
    background: colors.bg,
    color: colors.text,
  };

  const dotStyle: React.CSSProperties = {
    width: '8px',
    height: '8px',
    borderRadius: '50%',
    background: colors.text,
  };

  return (
    <span style={style}>
      <span style={dotStyle} />
      {label || status}
    </span>
  );
}
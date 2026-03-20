import React from 'react';

export interface InputProps extends React.InputHTMLAttributes<HTMLInputElement> {
  label?: string;
  error?: string;
}

export function Input({ label, error, style, ...props }: InputProps) {
  const inputStyle: React.CSSProperties = {
    width: '100%',
    padding: '0.75rem',
    border: `1px solid ${error ? '#ef4444' : '#e5e7eb'}`,
    borderRadius: '6px',
    fontSize: '1rem',
    ...style,
  };

  return (
    <div style={{ marginBottom: '1rem' }}>
      {label && <label style={{ display: 'block', marginBottom: '0.5rem', fontWeight: 500 }}>{label}</label>}
      <input style={inputStyle} {...props} />
      {error && <span style={{ color: '#ef4444', fontSize: '0.875rem', marginTop: '0.25rem', display: 'block' }}>{error}</span>}
    </div>
  );
}
import React from 'react';

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'danger';
  size?: 'sm' | 'md' | 'lg';
  loading?: boolean;
}

export function Button({
  variant = 'primary',
  size = 'md',
  loading = false,
  children,
  disabled,
  style,
  ...props
}: ButtonProps) {
  const baseStyle: React.CSSProperties = {
    border: 'none',
    borderRadius: '6px',
    cursor: disabled || loading ? 'not-allowed' : 'pointer',
    fontWeight: 500,
    display: 'inline-flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: '0.5rem',
    transition: 'all 0.15s ease',
    opacity: disabled || loading ? 0.6 : 1,
  };

  const variantStyles: Record<string, React.CSSProperties> = {
    primary: { background: '#0070f3', color: 'white' },
    secondary: { background: '#e5e7eb', color: '#1a1a1a' },
    danger: { background: '#ef4444', color: 'white' },
  };

  const sizeStyles: Record<string, React.CSSProperties> = {
    sm: { padding: '0.375rem 0.75rem', fontSize: '0.875rem' },
    md: { padding: '0.5rem 1rem', fontSize: '1rem' },
    lg: { padding: '0.75rem 1.5rem', fontSize: '1.125rem' },
  };

  return (
    <button
      style={{ ...baseStyle, ...variantStyles[variant], ...sizeStyles[size], ...style }}
      disabled={disabled || loading}
      {...props}
    >
      {loading && <span>⏳</span>}
      {children}
    </button>
  );
}
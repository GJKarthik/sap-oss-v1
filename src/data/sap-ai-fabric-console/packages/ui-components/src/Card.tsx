import React from 'react';

export interface CardProps {
  children: React.ReactNode;
  title?: string;
  style?: React.CSSProperties;
}

export function Card({ children, title, style }: CardProps) {
  const cardStyle: React.CSSProperties = {
    background: 'white',
    borderRadius: '8px',
    border: '1px solid #e5e7eb',
    padding: '1rem',
    ...style,
  };

  return (
    <div style={cardStyle}>
      {title && <h3 style={{ margin: '0 0 1rem', fontSize: '1rem' }}>{title}</h3>}
      {children}
    </div>
  );
}
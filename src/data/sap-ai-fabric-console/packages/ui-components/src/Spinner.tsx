import React from 'react';

export function Spinner() {
  const style: React.CSSProperties = {
    width: '24px',
    height: '24px',
    border: '3px solid #e5e7eb',
    borderTopColor: '#0070f3',
    borderRadius: '50%',
    animation: 'spin 0.8s linear infinite',
  };

  return (
    <>
      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
      <div style={style} />
    </>
  );
}
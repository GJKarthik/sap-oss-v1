// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

import { assertSafeCollaborationWebSocketUrl } from './collab-url-validation';

describe('assertSafeCollaborationWebSocketUrl', () => {
  it('allows public wss and ws hosts', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('wss://collab.example.com/path')).not.toThrow();
    expect(() => assertSafeCollaborationWebSocketUrl('ws://example.com:9090/collab')).not.toThrow();
  });

  it('allows same-origin path-only URLs', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('/collab')).not.toThrow();
    expect(() => assertSafeCollaborationWebSocketUrl('/api/ws')).not.toThrow();
  });

  it('rejects protocol-relative and path traversal', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('//evil.example/ws')).toThrow();
    expect(() => assertSafeCollaborationWebSocketUrl('/../admin')).toThrow();
  });

  it('rejects empty', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('')).toThrow(/required/);
  });

  it('rejects non-ws protocols', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('http://example.com/ws')).toThrow(/ws or wss/);
    expect(() => assertSafeCollaborationWebSocketUrl('https://example.com/ws')).toThrow(/ws or wss/);
  });

  it('rejects localhost and loopback', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('ws://localhost:9090')).toThrow(/blocked host/);
    expect(() => assertSafeCollaborationWebSocketUrl('ws://127.0.0.1:9090')).toThrow(/blocked host/);
  });

  it('rejects private IPv4 ranges', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('ws://10.0.0.1/x')).toThrow(/blocked host/);
    expect(() => assertSafeCollaborationWebSocketUrl('ws://192.168.1.1/x')).toThrow(/blocked host/);
    expect(() => assertSafeCollaborationWebSocketUrl('ws://172.16.0.1/x')).toThrow(/blocked host/);
    expect(() => assertSafeCollaborationWebSocketUrl('ws://172.31.255.1/x')).toThrow(/blocked host/);
    expect(() => assertSafeCollaborationWebSocketUrl('ws://172.15.0.1/x')).not.toThrow();
  });

  it('rejects link-local and metadata-style prefixes', () => {
    expect(() => assertSafeCollaborationWebSocketUrl('ws://169.254.169.254/')).toThrow(/blocked host/);
    expect(() => assertSafeCollaborationWebSocketUrl('ws://100.100.100.200/')).toThrow(/blocked host/);
  });
});

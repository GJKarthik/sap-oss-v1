import { describe, expect, it } from 'vitest';

import {
  SacAiSessionService,
  SacAiAuditEntry,
  SacAiReplayEntry,
} from '../libs/sac-ai-widget/session/sac-ai-session.service';

describe('SacAiSessionService', () => {
  // ---------------------------------------------------------------------------
  // threadId
  // ---------------------------------------------------------------------------

  it('generates a threadId on first access and returns the same value on subsequent calls', () => {
    const service = new SacAiSessionService();
    const first = service.getThreadId();
    const second = service.getThreadId();

    expect(first).toBe(second);
    expect(first).toMatch(/^sac-\d+-[a-z0-9]+$/);
  });

  it('reset() produces a new threadId and accepts an explicit override', () => {
    const service = new SacAiSessionService();
    const original = service.getThreadId();

    const generated = service.reset();
    expect(generated).not.toBe(original);
    expect(generated).toMatch(/^sac-/);

    const explicit = service.reset('custom-thread');
    expect(explicit).toBe('custom-thread');
    expect(service.getThreadId()).toBe('custom-thread');
  });

  it('reset() trims whitespace from explicit threadId', () => {
    const service = new SacAiSessionService();
    const id = service.reset('  padded  ');
    expect(id).toBe('padded');
  });

  it('reset() generates a new id when given an empty or whitespace-only string', () => {
    const service = new SacAiSessionService();
    const id = service.reset('   ');
    expect(id).toMatch(/^sac-/);
  });

  // ---------------------------------------------------------------------------
  // traceId
  // ---------------------------------------------------------------------------

  it('generates a W3C-compatible traceId (32 hex chars) on first access', () => {
    const service = new SacAiSessionService();
    const traceId = service.getTraceId();

    expect(traceId).toMatch(/^[0-9a-f]{32}$/);
  });

  it('returns the same traceId on subsequent calls', () => {
    const service = new SacAiSessionService();
    const first = service.getTraceId();
    const second = service.getTraceId();

    expect(first).toBe(second);
  });

  it('reset() clears the traceId so a new one is generated', () => {
    const service = new SacAiSessionService();
    const before = service.getTraceId();

    service.reset();
    const after = service.getTraceId();

    // Technically could collide, but 128-bit random makes it astronomically unlikely
    expect(after).toMatch(/^[0-9a-f]{32}$/);
    expect(after).not.toBe(before);
  });

  // ---------------------------------------------------------------------------
  // audit entries
  // ---------------------------------------------------------------------------

  it('records an audit entry with the current traceId', () => {
    const service = new SacAiSessionService();
    const traceId = service.getTraceId();

    const entry = service.recordAudit('run.started', 'processing', 'test detail');

    expect(entry.eventType).toBe('run.started');
    expect(entry.status).toBe('processing');
    expect(entry.detail).toBe('test detail');
    expect(entry.traceId).toBe(traceId);
    expect(entry.id).toMatch(/^audit-/);
    expect(entry.timestamp).toBeTruthy();
  });

  it('returns audit entries in reverse-chronological order', () => {
    const service = new SacAiSessionService();

    service.recordAudit('first', 'processing', 'a');
    service.recordAudit('second', 'completed', 'b');

    const entries = service.getAuditEntries();
    expect(entries).toHaveLength(2);
    expect(entries[0].eventType).toBe('second');
    expect(entries[1].eventType).toBe('first');
  });

  it('enforces the audit limit of 20 entries', () => {
    const service = new SacAiSessionService();

    for (let i = 0; i < 25; i++) {
      service.recordAudit(`event-${i}`, 'processing', `detail-${i}`);
    }

    const entries = service.getAuditEntries();
    expect(entries).toHaveLength(20);
    // Most recent should be first
    expect(entries[0].eventType).toBe('event-24');
  });

  it('getAuditEntries() returns a defensive copy', () => {
    const service = new SacAiSessionService();
    service.recordAudit('test', 'processing', 'detail');

    const a = service.getAuditEntries();
    const b = service.getAuditEntries();
    expect(a).not.toBe(b);
    expect(a).toEqual(b);
  });

  it('clearAudit() removes all audit entries', () => {
    const service = new SacAiSessionService();
    service.recordAudit('test', 'processing', 'detail');

    service.clearAudit();
    expect(service.getAuditEntries()).toHaveLength(0);
  });

  it('reset() clears audit entries', () => {
    const service = new SacAiSessionService();
    service.recordAudit('test', 'processing', 'detail');

    service.reset();
    expect(service.getAuditEntries()).toHaveLength(0);
  });

  // ---------------------------------------------------------------------------
  // replay entries
  // ---------------------------------------------------------------------------

  it('records a replay entry with incrementing sequence and traceId', () => {
    const service = new SacAiSessionService();
    const traceId = service.getTraceId();

    const first = service.recordReplay('request.sent', 'msg-1');
    const second = service.recordReplay('stream.chunk', 'chunk data');

    expect(first.sequence).toBe(1);
    expect(second.sequence).toBe(2);
    expect(first.kind).toBe('request.sent');
    expect(second.kind).toBe('stream.chunk');
    expect(first.traceId).toBe(traceId);
    expect(second.traceId).toBe(traceId);
    expect(first.id).toMatch(/^replay-/);
  });

  it('returns replay entries in reverse-chronological order', () => {
    const service = new SacAiSessionService();

    service.recordReplay('request.sent', 'a');
    service.recordReplay('stream.complete', 'b');

    const entries = service.getReplayEntries();
    expect(entries).toHaveLength(2);
    expect(entries[0].kind).toBe('stream.complete');
    expect(entries[1].kind).toBe('request.sent');
  });

  it('enforces the replay limit of 100 entries', () => {
    const service = new SacAiSessionService();

    for (let i = 0; i < 110; i++) {
      service.recordReplay('stream.chunk', `chunk-${i}`);
    }

    const entries = service.getReplayEntries();
    expect(entries).toHaveLength(100);
    expect(entries[0].sequence).toBe(110);
  });

  it('getReplayEntries() returns a defensive copy', () => {
    const service = new SacAiSessionService();
    service.recordReplay('request.sent', 'data');

    const a = service.getReplayEntries();
    const b = service.getReplayEntries();
    expect(a).not.toBe(b);
    expect(a).toEqual(b);
  });

  it('clearReplay() removes all entries and resets sequence', () => {
    const service = new SacAiSessionService();
    service.recordReplay('request.sent', 'data');
    service.recordReplay('stream.chunk', 'data');

    service.clearReplay();
    expect(service.getReplayEntries()).toHaveLength(0);

    const next = service.recordReplay('request.sent', 'fresh');
    expect(next.sequence).toBe(1);
  });

  it('reset() clears replay entries and resets sequence', () => {
    const service = new SacAiSessionService();
    service.recordReplay('request.sent', 'data');

    service.reset();
    expect(service.getReplayEntries()).toHaveLength(0);

    const next = service.recordReplay('stream.chunk', 'fresh');
    expect(next.sequence).toBe(1);
  });

  // ---------------------------------------------------------------------------
  // cross-cutting: traceId consistency across audit and replay
  // ---------------------------------------------------------------------------

  it('audit and replay entries share the same traceId within a session', () => {
    const service = new SacAiSessionService();

    const audit = service.recordAudit('run', 'processing', 'd');
    const replay = service.recordReplay('request.sent', 'd');

    expect(audit.traceId).toBe(replay.traceId);
    expect(audit.traceId).toMatch(/^[0-9a-f]{32}$/);
  });

  it('after reset, new entries get a fresh traceId', () => {
    const service = new SacAiSessionService();
    const auditBefore = service.recordAudit('before', 'processing', 'd');

    service.reset();
    const auditAfter = service.recordAudit('after', 'completed', 'd');

    expect(auditBefore.traceId).not.toBe(auditAfter.traceId);
  });
});

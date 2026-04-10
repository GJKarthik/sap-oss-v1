import {
  getModeConfig,
  getPillsForMode,
  getGroupRelevance,
  getRouteRelevance,
  nextMode,
  prevMode,
  loadPersistedMode,
  persistMode,
} from './mode.helpers';
import { AppMode } from './mode.types';
import { ALL_MODES, DEFAULT_MODE, MODE_STORAGE_KEY } from './mode.config';

describe('mode.helpers', () => {
  // ── getModeConfig ──

  it('returns config for each mode', () => {
    for (const mode of ALL_MODES) {
      const config = getModeConfig(mode);
      expect(config.id).toBe(mode);
      expect(config.labelKey).toBeTruthy();
      expect(config.icon).toBeTruthy();
      expect(config.systemPromptPrefix).toBeTruthy();
      expect(['always', 'destructive-only', 'never']).toContain(config.confirmationLevel);
    }
  });

  it('chat mode requires full confirmation', () => {
    expect(getModeConfig('chat').confirmationLevel).toBe('always');
  });

  it('cowork confirms destructive-only', () => {
    expect(getModeConfig('cowork').confirmationLevel).toBe('destructive-only');
  });

  it('training never confirms', () => {
    expect(getModeConfig('training').confirmationLevel).toBe('never');
  });

  // ── getPillsForMode ──

  it('returns 2 pills for chat mode', () => {
    const pills = getPillsForMode('chat');
    expect(pills.length).toBe(2);
    expect(pills.map(p => p.action)).toEqual(['ask', 'explain']);
  });

  it('returns 3 pills for cowork mode', () => {
    const pills = getPillsForMode('cowork');
    expect(pills.length).toBe(3);
    expect(pills.map(p => p.action)).toContain('propose');
    expect(pills.map(p => p.action)).toContain('review');
    expect(pills.map(p => p.action)).toContain('debug');
  });

  it('returns 3 pills for training mode', () => {
    const pills = getPillsForMode('training');
    expect(pills.length).toBe(3);
    expect(pills.map(p => p.action)).toContain('run');
    expect(pills.map(p => p.action)).toContain('metrics');
    expect(pills.map(p => p.action)).toContain('debug');
  });

  it('debug pill appears in both cowork and training', () => {
    const coworkPills = getPillsForMode('cowork');
    const trainingPills = getPillsForMode('training');
    expect(coworkPills.find(p => p.action === 'debug')).toBeTruthy();
    expect(trainingPills.find(p => p.action === 'debug')).toBeTruthy();
  });

  // ── getGroupRelevance ──

  it('chat mode highlights home and assist groups', () => {
    expect(getGroupRelevance('chat', 'home')).toBe(1.0);
    expect(getGroupRelevance('chat', 'assist')).toBe(1.0);
    expect(getGroupRelevance('chat', 'operations')).toBe(0.4);
  });

  it('training mode highlights operations and data groups', () => {
    expect(getGroupRelevance('training', 'operations')).toBe(1.0);
    expect(getGroupRelevance('training', 'data')).toBe(0.8);
    expect(getGroupRelevance('training', 'home')).toBe(0.4);
  });

  it('returns 0.5 fallback for unknown group', () => {
    expect(getGroupRelevance('chat', 'nonexistent' as any)).toBe(0.5);
  });

  // ── getRouteRelevance ──

  it('uses route-level override when present', () => {
    const relevance = getRouteRelevance('chat', 'assist', { chat: 1.0, training: 0.5 });
    expect(relevance).toBe(1.0);
  });

  it('falls back to group relevance when route override missing for that mode', () => {
    const relevance = getRouteRelevance('chat', 'data', { cowork: 1.0 });
    expect(relevance).toBe(0.6); // chat → data group = 0.6
  });

  it('falls back to group relevance when no route override at all', () => {
    const relevance = getRouteRelevance('training', 'operations', undefined);
    expect(relevance).toBe(1.0);
  });

  // ── nextMode / prevMode ──

  it('cycles forward: chat → cowork → training → chat', () => {
    expect(nextMode('chat')).toBe('cowork');
    expect(nextMode('cowork')).toBe('training');
    expect(nextMode('training')).toBe('chat');
  });

  it('cycles backward: chat → training → cowork → chat', () => {
    expect(prevMode('chat')).toBe('training');
    expect(prevMode('training')).toBe('cowork');
    expect(prevMode('cowork')).toBe('chat');
  });

  // ── localStorage persistence ──

  beforeEach(() => {
    localStorage.clear();
  });

  it('defaults to chat when localStorage is empty', () => {
    expect(loadPersistedMode()).toBe(DEFAULT_MODE);
    expect(loadPersistedMode()).toBe('chat');
  });

  it('persists and loads a valid mode', () => {
    persistMode('cowork');
    expect(loadPersistedMode()).toBe('cowork');
  });

  it('ignores invalid stored value and returns default', () => {
    localStorage.setItem(MODE_STORAGE_KEY, 'invalid-mode');
    expect(loadPersistedMode()).toBe('chat');
  });

  it('persists each mode correctly', () => {
    for (const mode of ALL_MODES) {
      persistMode(mode);
      expect(localStorage.getItem(MODE_STORAGE_KEY)).toBe(mode);
      expect(loadPersistedMode()).toBe(mode);
    }
  });
});

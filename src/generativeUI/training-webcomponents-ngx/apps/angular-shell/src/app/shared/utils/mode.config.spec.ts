import { MODE_CONFIG, MODE_PILLS } from './mode.config';
import { TRAINING_ROUTE_LINKS } from '../../app.navigation';
import type { AppMode } from './mode.types';

describe('MODE_CONFIG', () => {
  const allRoutePaths = TRAINING_ROUTE_LINKS.map(r => r.path);

  it('defines all three modes', () => {
    expect(Object.keys(MODE_CONFIG)).toEqual(['chat', 'cowork', 'training']);
  });

  it('every suggestedRoute exists in TRAINING_ROUTE_LINKS', () => {
    for (const [mode, config] of Object.entries(MODE_CONFIG)) {
      for (const route of config.suggestedRoutes) {
        expect(allRoutePaths).toContain(route);
      }
    }
  });

  it('each mode has a non-empty systemPromptPrefix', () => {
    for (const config of Object.values(MODE_CONFIG)) {
      expect(config.systemPromptPrefix.length).toBeGreaterThan(10);
    }
  });

  it('each mode has a distinct confirmationLevel', () => {
    const levels = Object.values(MODE_CONFIG).map(c => c.confirmationLevel);
    expect(new Set(levels).size).toBe(3);
  });
});

describe('MODE_PILLS', () => {
  it('defines pills for all three modes', () => {
    const modes: AppMode[] = ['chat', 'cowork', 'training'];
    for (const mode of modes) {
      expect(MODE_PILLS[mode].length).toBeGreaterThan(0);
    }
  });

  it('each pill has label, icon, and action', () => {
    for (const pills of Object.values(MODE_PILLS)) {
      for (const pill of pills) {
        expect(pill.label).toBeTruthy();
        expect(pill.icon).toBeTruthy();
        expect(pill.action).toBeTruthy();
      }
    }
  });
});

import type { AppMode, ModeConfig, CoworkPlan, CoworkPlanStep, ContextPill } from './mode.types';

describe('mode.types', () => {
  it('AppMode accepts valid values', () => {
    const modes: AppMode[] = ['chat', 'cowork', 'training'];
    expect(modes).toHaveLength(3);
  });

  it('CoworkPlan has required shape', () => {
    const plan: CoworkPlan = {
      id: 'test-1',
      steps: [{ label: 'Step 1', description: 'Do thing', status: 'pending' }],
      status: 'proposed',
    };
    expect(plan.steps).toHaveLength(1);
    expect(plan.status).toBe('proposed');
  });

  it('ContextPill target is optional', () => {
    const pill: ContextPill = { label: 'Test', icon: 'home', action: 'navigate' };
    expect(pill.target).toBeUndefined();

    const pillWithTarget: ContextPill = { label: 'Test', icon: 'home', action: 'navigate', target: '/chat' };
    expect(pillWithTarget.target).toBe('/chat');
  });
});

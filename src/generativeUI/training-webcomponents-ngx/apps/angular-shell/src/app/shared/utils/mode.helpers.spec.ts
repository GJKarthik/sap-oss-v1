import { getModeCapabilities, getRouteRelevance, getContextPills } from './mode.helpers';

describe('getModeCapabilities', () => {
  it('returns conversational confirmation for chat mode', () => {
    const caps = getModeCapabilities('chat');
    expect(caps.confirmationLevel).toBe('conversational');
    expect(caps.systemPromptPrefix).toContain('conversational');
  });

  it('returns per-action confirmation for cowork mode', () => {
    const caps = getModeCapabilities('cowork');
    expect(caps.confirmationLevel).toBe('per-action');
    expect(caps.systemPromptPrefix).toContain('Plan before acting');
  });

  it('returns autonomous confirmation for training mode', () => {
    const caps = getModeCapabilities('training');
    expect(caps.confirmationLevel).toBe('autonomous');
    expect(caps.systemPromptPrefix).toContain('autonomously');
  });
});

describe('getRouteRelevance', () => {
  it('returns suggested routes for chat mode', () => {
    const relevance = getRouteRelevance('chat');
    expect(relevance.suggested).toContain('/chat');
    expect(relevance.suggested).toContain('/dashboard');
  });

  it('returns all routes regardless of mode', () => {
    const chatRelevance = getRouteRelevance('chat');
    const trainingRelevance = getRouteRelevance('training');
    expect(chatRelevance.all).toEqual(trainingRelevance.all);
    expect(chatRelevance.all.length).toBeGreaterThan(20);
  });

  it('training mode suggests pipeline routes', () => {
    const relevance = getRouteRelevance('training');
    expect(relevance.suggested).toContain('/pipeline');
    expect(relevance.suggested).toContain('/data-explorer');
    expect(relevance.suggested).not.toContain('/chat');
  });
});

describe('getContextPills', () => {
  it('returns pills for each mode', () => {
    expect(getContextPills('chat').length).toBeGreaterThan(0);
    expect(getContextPills('cowork').length).toBeGreaterThan(0);
    expect(getContextPills('training').length).toBeGreaterThan(0);
  });

  it('chat pills include recent chats', () => {
    const pills = getContextPills('chat');
    expect(pills.some(p => p.label === 'Recent chats')).toBe(true);
  });
});

import { TRAINING_ROUTE_LINKS } from './app.navigation';
import type { AppMode } from './shared/utils/mode.types';

describe('TRAINING_ROUTE_LINKS modeRelevance', () => {
  it('every route has a modeRelevance array', () => {
    for (const link of TRAINING_ROUTE_LINKS) {
      expect(link.modeRelevance).toBeDefined();
      expect(Array.isArray(link.modeRelevance)).toBe(true);
      expect(link.modeRelevance.length).toBeGreaterThan(0);
    }
  });

  it('chat mode suggests /dashboard and /chat', () => {
    const chatRoutes = TRAINING_ROUTE_LINKS.filter(r => r.modeRelevance.includes('chat'));
    const paths = chatRoutes.map(r => r.path);
    expect(paths).toContain('/dashboard');
    expect(paths).toContain('/chat');
  });

  it('training mode suggests /pipeline and /data-products', () => {
    const trainingRoutes = TRAINING_ROUTE_LINKS.filter(r => r.modeRelevance.includes('training'));
    const paths = trainingRoutes.map(r => r.path);
    expect(paths).toContain('/pipeline');
    expect(paths).toContain('/data-products');
  });

  it('modeRelevance only contains valid AppMode values', () => {
    const validModes: AppMode[] = ['chat', 'cowork', 'training'];
    for (const link of TRAINING_ROUTE_LINKS) {
      for (const mode of link.modeRelevance) {
        expect(validModes).toContain(mode);
      }
    }
  });
});

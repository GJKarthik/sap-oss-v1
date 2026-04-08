import { LearnPathService } from './learn-path.service';

describe('LearnPathService', () => {
  it('starts from first route and advances in order', () => {
    const service = new LearnPathService();

    const first = service.start();
    expect(first.route).toBe('/generative');
    expect(service.currentStep?.route).toBe('/generative');

    const second = service.next();
    expect(second?.route).toBe('/joule');
    expect(service.currentStep?.route).toBe('/joule');
  });

  it('stops after final step', () => {
    const service = new LearnPathService();
    service.start();
    service.next();
    service.next();
    service.next();

    const afterLast = service.next();

    expect(afterLast).toBeNull();
    expect(service.active).toBe(false);
  });
});

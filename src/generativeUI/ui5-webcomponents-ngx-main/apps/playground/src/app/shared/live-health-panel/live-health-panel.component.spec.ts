import { of } from 'rxjs';
import { LiveHealthPanelComponent } from './live-health-panel.component';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';

describe('LiveHealthPanelComponent', () => {
  it('starts with checking state before ngOnInit', () => {
    const service = {
      checkAllServices: () => of([]),
    } as unknown as LiveDemoHealthService;
    const component = new LiveHealthPanelComponent(service);

    expect(component.summaryText).toBe('Checking live service health...');
    expect(component.blocking).toBe(true);
  });

  it('shows healthy summary when all checks pass', () => {
    const service = {
      checkAllServices: () =>
        of([
          { name: 'AG-UI', ok: true, status: 200, url: '/ag-ui/health' },
          { name: 'OpenAI', ok: true, status: 200, url: '/health' },
          { name: 'MCP', ok: true, status: 200, url: '/health' },
        ]),
    } as unknown as LiveDemoHealthService;
    const component = new LiveHealthPanelComponent(service);
    component.ngOnInit();

    expect(component.blocking).toBe(false);
    expect(component.summaryText).toContain('All live dependencies are healthy');
  });

  it('refreshes checks and updates last check timestamp', () => {
    const service = {
      checkAllServices: jest.fn().mockReturnValue(
        of([{ name: 'AG-UI', ok: true, status: 200, url: '/ag-ui/health' }]),
      ),
    } as unknown as LiveDemoHealthService;
    const component = new LiveHealthPanelComponent(service);

    component.refreshHealth();

    expect((service.checkAllServices as jest.Mock)).toHaveBeenCalledTimes(1);
    expect(component.lastCheckedAt).not.toBeNull();
  });

  it('exposes readable status text for each service check', () => {
    const service = {
      checkAllServices: () => of([]),
    } as unknown as LiveDemoHealthService;
    const component = new LiveHealthPanelComponent(service);

    expect(
      component.getCheckStatusText({
        name: 'MCP',
        ok: true,
        status: 200,
        url: '/health',
      }),
    ).toContain('Healthy');

    expect(
      component.getCheckStatusText({
        name: 'MCP',
        ok: false,
        status: 503,
        url: '/health',
        error: 'down',
      }),
    ).toContain('Unavailable');
  });
});

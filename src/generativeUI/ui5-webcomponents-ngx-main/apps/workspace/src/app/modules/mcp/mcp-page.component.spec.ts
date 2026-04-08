import { HttpClient } from '@angular/common/http';
import { of, throwError } from 'rxjs';
import { McpPageComponent } from './mcp-page.component';
import { ExperienceHealthService } from '../../core/experience-health.service';

function makeHttp() {
  return {
    post: jest.fn(),
  } as unknown as HttpClient;
}

function makeHealthService() {
  return {
    checkRouteReadiness: jest.fn().mockReturnValue(
      of({ route: 'mcp', blocking: false, checks: [] }),
    ),
  } as unknown as ExperienceHealthService;
}

describe('McpPageComponent', () => {
  it('loads tool names from real MCP list-tools call', () => {
    const http = makeHttp();
    (http.post as jest.Mock).mockReturnValue(
      of({
        result: {
          tools: [{ name: 'toolA' }, { name: 'toolB' }],
        },
      }),
    );
    const health = makeHealthService();
    const component = new McpPageComponent(http, health);

    component.ngOnInit();

    expect(component.tools).toEqual(['toolA', 'toolB']);
    expect(component.lastError).toBeNull();
  });

  it('runs tool call and stores response payload', () => {
    const http = makeHttp();
    (http.post as jest.Mock)
      .mockReturnValueOnce(
        of({
          result: { tools: [{ name: 'toolA' }] },
        }),
      )
      .mockReturnValueOnce(
        of({
          result: { content: [{ type: 'text', text: 'ok' }] },
        }),
      );
    const health = makeHealthService();
    const component = new McpPageComponent(http, health);
    component.ngOnInit();
    component.selectedTool = 'toolA';

    component.invokeSelectedTool();

    expect(component.lastCallResult).toContain('"text": "ok"');
  });

  it('surfaces route blocked state and skips MCP calls', () => {
    const http = makeHttp();
    const health = makeHealthService();
    (health.checkRouteReadiness as jest.Mock).mockReturnValue(
      of({
        route: 'mcp',
        blocking: true,
        checks: [{ name: 'MCP', ok: false, status: 503, url: '/health' }],
      }),
    );
    const component = new McpPageComponent(http, health);

    component.ngOnInit();

    expect(component.routeBlocked).toBe(true);
    expect(http.post).not.toHaveBeenCalled();
  });

  it('captures backend failure for tool invocation', () => {
    const http = makeHttp();
    (http.post as jest.Mock)
      .mockReturnValueOnce(of({ result: { tools: [{ name: 'toolA' }] } }))
      .mockReturnValueOnce(throwError(() => new Error('mcp down')));
    const health = makeHealthService();
    const component = new McpPageComponent(http, health);
    component.ngOnInit();
    component.selectedTool = 'toolA';

    component.invokeSelectedTool();

    expect(component.lastError).toContain('mcp down');
  });

  it('flags invalid tools/list contract when tools array is missing', () => {
    const http = makeHttp();
    (http.post as jest.Mock).mockReturnValue(of({ result: {} }));
    const health = makeHealthService();
    const component = new McpPageComponent(http, health);

    component.ngOnInit();

    expect(component.tools).toEqual([]);
    expect(component.lastError).toContain('Invalid MCP tools/list contract');
  });
});

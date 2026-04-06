import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { of } from 'rxjs';
import { McpService } from '../../services/mcp.service';
import { PlaygroundComponent } from './playground.component';

describe('PlaygroundComponent', () => {
  let fixture: ComponentFixture<PlaygroundComponent>;
  let component: PlaygroundComponent;
  let mcpService: {
    fetchPalTools: jest.Mock;
    invokePalTool: jest.Mock;
  };

  beforeEach(async () => {
    mcpService = {
      fetchPalTools: jest.fn().mockReturnValue(
        of([
          {
            name: 'pal_forecast',
            description: 'Run forecasting',
            inputSchema: {
              type: 'object',
              properties: {
                table_name: { type: 'string' },
                value_column: { type: 'string' },
                horizon: { type: 'number' },
              },
              required: ['table_name', 'value_column'],
            },
          },
        ])
      ),
      invokePalTool: jest.fn().mockReturnValue(
        of({
          status: 'success',
          rows: [{ period: 1, forecast: 42 }],
        })
      ),
    };

    await TestBed.configureTestingModule({
      imports: [PlaygroundComponent],
      providers: [
        { provide: McpService, useValue: mcpService },
        provideHttpClient(),
        provideHttpClientTesting(),
      ],
    })
      .overrideComponent(PlaygroundComponent, {
        add: {
          schemas: [NO_ERRORS_SCHEMA],
        },
      })
      .compileComponents();
  });

  it('loads PAL tools and seeds the argument template from the selected tool schema', () => {
    fixture = TestBed.createComponent(PlaygroundComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(mcpService.fetchPalTools).toHaveBeenCalled();
    expect(component.selectedToolName).toBe('pal_forecast');
    expect(component.argumentsText).toContain('"table_name"');
    expect(component.argumentsText).toContain('"value_column"');
  });

  it('invokes the selected PAL tool and records the result', () => {
    fixture = TestBed.createComponent(PlaygroundComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    component.argumentsText = JSON.stringify({
      table_name: 'SALES_HISTORY',
      value_column: 'REVENUE',
      horizon: 6,
    });

    component.runTool();

    expect(mcpService.invokePalTool).toHaveBeenCalledWith('pal_forecast', {
      table_name: 'SALES_HISTORY',
      value_column: 'REVENUE',
      horizon: 6,
    });
    expect(component.invocations).toHaveLength(1);
    expect(component.invocations[0].state).toBe('success');
  });
});

import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { of, throwError } from 'rxjs';
import { AuthService } from '../../services/auth.service';
import { Deployment, McpService } from '../../services/mcp.service';
import { DeploymentsComponent } from './deployments.component';

describe('DeploymentsComponent', () => {
  let fixture: ComponentFixture<DeploymentsComponent>;
  let component: DeploymentsComponent;
  let mcpService: {
    fetchDeployments: jest.Mock;
    createDeployment: jest.Mock;
    updateDeploymentStatus: jest.Mock;
    deleteDeployment: jest.Mock;
  };

  beforeEach(async () => {
    mcpService = {
      fetchDeployments: jest.fn(),
      createDeployment: jest.fn(),
      updateDeploymentStatus: jest.fn(),
      deleteDeployment: jest.fn(),
    };

    await TestBed.configureTestingModule({
      imports: [DeploymentsComponent],
      providers: [
        { provide: McpService, useValue: mcpService },
        {
          provide: AuthService,
          useValue: {
            getUser: () => ({ username: 'admin', role: 'admin' }),
          },
        },
        provideHttpClient(),
        provideHttpClientTesting(),
      ],
    })
      .overrideComponent(DeploymentsComponent, {
        add: {
          schemas: [NO_ERRORS_SCHEMA],
        },
      })
      .compileComponents();
  });

  it('loads deployments on init', () => {
    const deployments: Deployment[] = [
      { id: 'deployment-1', status: 'RUNNING', scenarioId: 'scenario-a' },
      { id: 'deployment-2', status: 'FAILED', scenarioId: 'scenario-b' },
    ];
    mcpService.fetchDeployments.mockReturnValue(of(deployments));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(mcpService.fetchDeployments).toHaveBeenCalled();
    expect(component.deployments).toEqual(deployments);
    expect(component.loading).toBe(false);
    expect(fixture.nativeElement.textContent).toContain('deployment-1');
  });

  it('shows an error when deployment loading fails', () => {
    mcpService.fetchDeployments.mockReturnValue(
      throwError(() => new Error('backend unavailable'))
    );

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(component.error).toBe('backend unavailable');
    expect(component.loading).toBe(false);
    expect(fixture.nativeElement.textContent).toContain('backend unavailable');
  });

  it('maps status values to UI5 tag designs', () => {
    mcpService.fetchDeployments.mockReturnValue(of([]));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;

    expect(component.getStatusDesign('RUNNING')).toBe('Positive');
    expect(component.getStatusDesign('failed')).toBe('Negative');
    expect(component.getStatusDesign('inactive')).toBe('Critical');
    expect(component.getStatusDesign('pending')).toBe('Neutral');
  });

  it('opens the creation form for admin sessions', () => {
    mcpService.fetchDeployments.mockReturnValue(of([]));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    component.toggleCreateForm();
    fixture.detectChanges();

    const content = fixture.nativeElement.textContent;
    // Accept either translated text or raw i18n key (depends on whether translations are loaded)
    expect(content).toMatch(/Scenario ID|deployments\.scenarioId/);
    expect(content).toMatch(/Configuration JSON|deployments\.configurationJson/);
  });
});

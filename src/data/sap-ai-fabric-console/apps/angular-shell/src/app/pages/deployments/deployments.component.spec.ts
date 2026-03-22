import { CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { of, throwError } from 'rxjs';
import { Deployment, McpService } from '../../services/mcp.service';
import { DeploymentsComponent } from './deployments.component';

describe('DeploymentsComponent', () => {
  let fixture: ComponentFixture<DeploymentsComponent>;
  let component: DeploymentsComponent;
  let mcpService: { fetchDeployments: jest.Mock };

  beforeEach(async () => {
    mcpService = {
      fetchDeployments: jest.fn(),
    };

    await TestBed.configureTestingModule({
      imports: [DeploymentsComponent],
      providers: [
        { provide: McpService, useValue: mcpService },
        provideHttpClient(),
        provideHttpClientTesting(),
      ],
      schemas: [CUSTOM_ELEMENTS_SCHEMA],
    }).compileComponents();
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

    expect(component.error).toBe('Failed to load deployment data.');
    expect(component.loading).toBe(false);
    expect(fixture.nativeElement.textContent).toContain('Failed to load deployment data.');
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
});

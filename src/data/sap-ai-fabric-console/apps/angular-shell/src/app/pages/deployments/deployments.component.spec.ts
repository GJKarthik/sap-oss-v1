import { CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { of, throwError } from 'rxjs';
import {
  Deployment,
  DeploymentListResponse,
  DeploymentsService,
} from '../../services/api/deployments.service';
import { DeploymentsComponent } from './deployments.component';

describe('DeploymentsComponent', () => {
  let fixture: ComponentFixture<DeploymentsComponent>;
  let component: DeploymentsComponent;
  let deploymentsService: {
    listDeployments: jest.Mock;
    createDeployment: jest.Mock;
    getDeployment: jest.Mock;
    deleteDeployment: jest.Mock;
    updateDeploymentStatus: jest.Mock;
  };

  beforeEach(async () => {
    deploymentsService = {
      listDeployments: jest.fn(),
      createDeployment: jest.fn(),
      getDeployment: jest.fn(),
      deleteDeployment: jest.fn(),
      updateDeploymentStatus: jest.fn(),
    };

    await TestBed.configureTestingModule({
      imports: [DeploymentsComponent],
      providers: [
        { provide: DeploymentsService, useValue: deploymentsService },
        provideHttpClient(),
        provideHttpClientTesting(),
      ],
      schemas: [CUSTOM_ELEMENTS_SCHEMA],
    }).compileComponents();
  });

  it('loads deployments on init', () => {
    const deployments: Deployment[] = [
      { id: 'deployment-1', status: 'RUNNING', target_status: 'RUNNING', scenario_id: 'scenario-a', creation_time: '2026-03-23T00:00:00Z', details: {} },
      { id: 'deployment-2', status: 'FAILED', target_status: 'STOPPED', scenario_id: 'scenario-b', creation_time: '2026-03-23T01:00:00Z', details: {} },
    ];
    const response: DeploymentListResponse = { resources: deployments, count: deployments.length };
    deploymentsService.listDeployments.mockReturnValue(of(response));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(deploymentsService.listDeployments).toHaveBeenCalled();
    expect(component.deployments).toEqual(deployments);
    expect(component.deploymentCount).toBe(2);
    expect(component.loading).toBe(false);
    expect(fixture.nativeElement.textContent).toContain('deployment-1');
  });

  it('shows an error when deployment loading fails', () => {
    deploymentsService.listDeployments.mockReturnValue(
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
    deploymentsService.listDeployments.mockReturnValue(of({ resources: [], count: 0 }));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;

    expect(component.getStatusDesign('RUNNING')).toBe('Positive');
    expect(component.getStatusDesign('failed')).toBe('Negative');
    expect(component.getStatusDesign('inactive')).toBe('Critical');
    expect(component.getStatusDesign('pending')).toBe('Neutral');
  });

  it('creates a deployment through the backend service', () => {
    const createdDeployment: Deployment = {
      id: 'deployment-3',
      status: 'PENDING',
      target_status: 'RUNNING',
      scenario_id: 'scenario-c',
      creation_time: '2026-03-23T02:00:00Z',
      details: {},
    };
    deploymentsService.listDeployments.mockReturnValue(of({ resources: [], count: 0 }));
    deploymentsService.createDeployment.mockReturnValue(of(createdDeployment));
    deploymentsService.getDeployment.mockReturnValue(of(createdDeployment));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    component.createDeployment({ scenario_id: 'scenario-c' });

    expect(deploymentsService.createDeployment).toHaveBeenCalledWith({ scenario_id: 'scenario-c' });
    expect(deploymentsService.getDeployment).toHaveBeenCalledWith('deployment-3');
    expect(component.deployments).toEqual([createdDeployment]);
    expect(component.deploymentCount).toBe(1);
  });

  it('deletes a deployment through the backend service', () => {
    const existingDeployment: Deployment = {
      id: 'deployment-1',
      status: 'RUNNING',
      target_status: 'RUNNING',
      scenario_id: 'scenario-a',
      creation_time: '2026-03-23T00:00:00Z',
      details: {},
    };
    deploymentsService.listDeployments
      .mockReturnValueOnce(of({ resources: [existingDeployment], count: 1 }))
      .mockReturnValueOnce(of({ resources: [], count: 0 }));
    deploymentsService.deleteDeployment.mockReturnValue(of(void 0));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    component.deleteDeployment('deployment-1');

    expect(deploymentsService.deleteDeployment).toHaveBeenCalledWith('deployment-1');
    expect(component.deployments).toEqual([]);
    expect(component.deploymentCount).toBe(0);
  });

  it('updates deployment status through the backend service', () => {
    const existingDeployment: Deployment = {
      id: 'deployment-1',
      status: 'PENDING',
      target_status: 'RUNNING',
      scenario_id: 'scenario-a',
      creation_time: '2026-03-23T00:00:00Z',
      details: {},
    };
    const updatedDeployment: Deployment = {
      ...existingDeployment,
      target_status: 'STOPPED',
    };
    deploymentsService.listDeployments.mockReturnValue(of({ resources: [existingDeployment], count: 1 }));
    deploymentsService.updateDeploymentStatus.mockReturnValue(of({ id: 'deployment-1', target_status: 'STOPPED' }));
    deploymentsService.getDeployment.mockReturnValue(of(updatedDeployment));

    fixture = TestBed.createComponent(DeploymentsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    component.updateDeploymentStatus('deployment-1', 'STOPPED');

    expect(deploymentsService.updateDeploymentStatus).toHaveBeenCalledWith('deployment-1', 'STOPPED');
    expect(deploymentsService.getDeployment).toHaveBeenCalledWith('deployment-1');
    expect(component.deployments).toEqual([updatedDeployment]);
  });
});

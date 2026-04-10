import { Injector, runInInjectionContext } from '@angular/core';
import { CoworkPlanComponent } from './cowork-plan.component';
import type { CoworkPlan } from '../../utils/mode.types';

describe('CoworkPlanComponent', () => {
  const mockPlan: CoworkPlan = {
    id: 'plan-1',
    steps: [
      { label: 'Ingest data', description: 'Load CSV file', status: 'pending' },
      { label: 'Transform', description: 'Clean and chunk', status: 'pending' },
      { label: 'Embed', description: 'Generate embeddings', status: 'pending' },
    ],
    status: 'proposed',
  };

  it('has required plan input and output emitters', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    expect(component.plan).toBeDefined();
    expect(component.planApproved).toBeDefined();
    expect(component.planEdited).toBeDefined();
    expect(component.planRejected).toBeDefined();
  });

  it('approve() emits the plan via planApproved', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    const spy = jest.fn();
    component.planApproved.subscribe(spy);
    component.approve(mockPlan);
    expect(spy).toHaveBeenCalledWith(mockPlan);
  });

  it('reject() emits the plan via planRejected', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    const spy = jest.fn();
    component.planRejected.subscribe(spy);
    component.reject(mockPlan);
    expect(spy).toHaveBeenCalledWith(mockPlan);
  });

  it('edit() emits the plan via planEdited', () => {
    const injector = Injector.create({ providers: [] });
    const component = runInInjectionContext(injector, () => new CoworkPlanComponent());
    const spy = jest.fn();
    component.planEdited.subscribe(spy);
    component.edit(mockPlan);
    expect(spy).toHaveBeenCalledWith(mockPlan);
  });
});

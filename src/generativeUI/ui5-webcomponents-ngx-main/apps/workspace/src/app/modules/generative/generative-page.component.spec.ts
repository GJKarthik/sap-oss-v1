import { ChangeDetectorRef } from '@angular/core';
import { of, Subject, throwError } from 'rxjs';
import { GenerativePageComponent } from './generative-page.component';
import { GenerativeIntentService } from './generative-intent.service';
import { GenerativeRuntimeService } from './generative-runtime.service';
import { ExperienceHealthService } from '../../core/experience-health.service';
import { WorkspaceHistoryService } from '../../core/workspace-history.service';

function makeIntentService() {
  const intents$ = new Subject<{ action: string; payload?: unknown }>();
  return {
    intents$: intents$.asObservable(),
    _intents$: intents$,
  } as unknown as GenerativeIntentService & { _intents$: Subject<{ action: string; payload?: unknown }> };
}

function makeRuntimeService() {
  return {
    generateSchema: jest.fn(),
  } as unknown as GenerativeRuntimeService;
}

function makeHealthService() {
  return {
    checkRouteReadiness: jest.fn().mockReturnValue(
      of({ route: 'generative', blocking: false, checks: [] }),
    ),
  } as unknown as ExperienceHealthService;
}

function makeCdr(): ChangeDetectorRef {
  return { detectChanges: jest.fn() } as unknown as ChangeDetectorRef;
}

function makeHistoryService() {
  return {
    saveEntry: jest.fn().mockReturnValue(of({})),
    loadHistory: jest.fn().mockReturnValue(of([])),
  } as unknown as WorkspaceHistoryService;
}

describe('GenerativePageComponent', () => {
  it('uses runtime service instead of simulation to produce schema', () => {
    const cdr = makeCdr();
    const intentService = makeIntentService();
    const runtime = makeRuntimeService();
    const health = makeHealthService();
    (runtime.generateSchema as jest.Mock).mockReturnValue(of({ type: 'ui5-card' }));

    const component = new GenerativePageComponent(cdr, intentService, runtime, health, makeHistoryService());
    component.ngOnInit();
    component.generateUI('Build profile form');

    expect(runtime.generateSchema).toHaveBeenCalledWith('Build profile form');
    expect(component.uiSchema).toEqual({ type: 'ui5-card' });
    expect(component.loading).toBe(false);
  });

  it('keeps uiSchema null and surfaces error when backend call fails', () => {
    const cdr = makeCdr();
    const intentService = makeIntentService();
    const runtime = makeRuntimeService();
    const health = makeHealthService();
    (runtime.generateSchema as jest.Mock).mockReturnValue(
      throwError(() => new Error('backend down')),
    );

    const component = new GenerativePageComponent(cdr, intentService, runtime, health, makeHistoryService());
    component.ngOnInit();
    component.generateUI('Build profile form');

    expect(component.uiSchema).toBeNull();
    expect(component.lastError).toContain('backend down');
    expect(component.loading).toBe(false);
  });
});

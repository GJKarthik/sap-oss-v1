// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 SAP SE

import 'zone.js';
import 'zone.js/testing';
import { ChangeDetectionStrategy } from '@angular/core';
import { ComponentFixture, TestBed, getTestBed } from '@angular/core/testing';
import {
  BrowserDynamicTestingModule,
  platformBrowserDynamicTesting,
} from '@angular/platform-browser-dynamic/testing';
import { BehaviorSubject } from 'rxjs';
import {
  GovernanceService,
  PendingAction,
  PendingActionReview,
} from '../services/governance.service';
import { GovernanceReviewPanelComponent } from './governance-review-panel.component';

function makePendingAction(): PendingAction {
  return {
    id: 'action-1',
    toolName: 'modify_user',
    arguments: {
      userId: 'u-42',
      role: 'viewer',
    },
    description: 'Review user role change',
    riskLevel: 'high',
    affectedData: [
      {
        entityType: 'user',
        entityId: 'u-42',
        fields: ['role'],
        changeType: 'update',
      },
    ],
    createdAt: new Date('2026-03-20T00:00:00.000Z'),
    expiresAt: new Date('2026-03-20T00:05:00.000Z'),
    runId: 'run-1',
    allowModifications: true,
  };
}

function makeReview(action: PendingAction): PendingActionReview {
  return {
    action,
    riskLabel: 'High risk',
    riskDescription: 'This action changes or removes important business data.',
    affectedScope: {
      entityCount: 1,
      entities: ['user:u-42'],
      fieldCount: 1,
      fields: ['role'],
      changeTypes: ['update'],
      summary: '1 user · update · 1 field',
    },
    finalArguments: {
      userId: 'u-42',
      role: 'admin',
    },
    diff: [
      {
        path: 'role',
        before: 'viewer',
        after: 'admin',
        changeType: 'changed',
      },
    ],
  };
}

describe('GovernanceReviewPanelComponent', () => {
  let fixture: ComponentFixture<GovernanceReviewPanelComponent>;
  let component: GovernanceReviewPanelComponent;
  let pendingActions$: BehaviorSubject<PendingAction[]>;
  let governanceStub: {
    pendingActions$: BehaviorSubject<PendingAction[]>;
    buildPendingActionReview: jest.Mock<PendingActionReview | undefined, [string | PendingAction, Record<string, unknown>?]>;
    confirmAction: jest.Mock<Promise<void>, [string, (Record<string, unknown> | undefined)?]>;
    rejectAction: jest.Mock<Promise<void>, [string, (string | undefined)?]>;
  };

  beforeAll(() => {
    try {
      getTestBed().initTestEnvironment(
        BrowserDynamicTestingModule,
        platformBrowserDynamicTesting(),
      );
    } catch {
      // The Jest environment may already be initialised by the preset.
    }
  });

  beforeEach(async () => {
    pendingActions$ = new BehaviorSubject<PendingAction[]>([makePendingAction()]);
    governanceStub = {
      pendingActions$,
      buildPendingActionReview: jest.fn((actionOrId: string | PendingAction) => {
        const action = typeof actionOrId === 'string'
          ? pendingActions$.value.find(item => item.id === actionOrId)
          : actionOrId;
        return action ? makeReview(action) : undefined;
      }),
      confirmAction: jest.fn().mockResolvedValue(undefined),
      rejectAction: jest.fn().mockResolvedValue(undefined),
    };

    await TestBed.configureTestingModule({
      imports: [GovernanceReviewPanelComponent],
      providers: [
        { provide: GovernanceService, useValue: governanceStub },
      ],
    })
      .overrideComponent(GovernanceReviewPanelComponent, {
        set: { changeDetection: ChangeDetectionStrategy.Default },
      })
      .compileComponents();

    fixture = TestBed.createComponent(GovernanceReviewPanelComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('renders risk label, affected scope, and diff rows for the selected action', () => {
    const text = fixture.nativeElement.textContent;

    expect(text).toContain('High risk');
    expect(text).toContain('1 user · update · 1 field');
    expect(text).toContain('role');
    expect(text).toContain('viewer');
    expect(text).toContain('admin');
  });

  it('shows a validation error for invalid JSON modifications', () => {
    const textarea: HTMLTextAreaElement = fixture.nativeElement.querySelector(
      'textarea[aria-label="Operator modifications"]'
    );

    textarea.value = '{invalid';
    textarea.dispatchEvent(new Event('input'));
    fixture.detectChanges();

    expect(fixture.nativeElement.textContent).toContain('Operator modifications must be valid JSON.');
    const approveButton: HTMLButtonElement = fixture.nativeElement.querySelector(
      '.review-panel__button:not(.review-panel__button--secondary)'
    );
    expect(approveButton.disabled).toBe(true);
  });

  it('confirms the selected action with parsed modification JSON', async () => {
    const textarea: HTMLTextAreaElement = fixture.nativeElement.querySelector(
      'textarea[aria-label="Operator modifications"]'
    );
    textarea.value = '{"role":"admin"}';
    textarea.dispatchEvent(new Event('input'));
    fixture.detectChanges();

    const approveButton: HTMLButtonElement = fixture.nativeElement.querySelector(
      '.review-panel__button:not(.review-panel__button--secondary)'
    );
    approveButton.click();
    await fixture.whenStable();

    expect(governanceStub.confirmAction).toHaveBeenCalledWith('action-1', { role: 'admin' });
  });

  it('shows submission failures and keeps the action review interactive', async () => {
    governanceStub.confirmAction.mockRejectedValueOnce(new Error('Backend unavailable'));

    const approveButton: HTMLButtonElement = fixture.nativeElement.querySelector(
      '.review-panel__button:not(.review-panel__button--secondary)'
    );
    await component.confirmSelectedAction();
    fixture.detectChanges();

    expect(fixture.nativeElement.textContent).toContain('Approval failed: Backend unavailable');
    expect(approveButton.disabled).toBe(false);
  });
});

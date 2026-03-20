// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * GenUI Governance Module
 */

import { NgModule, ModuleWithProviders } from '@angular/core';
import { CommonModule } from '@angular/common';
import { GovernanceService, GOVERNANCE_CONFIG, GovernanceConfig } from './services/governance.service';
import { AuditService, AUDIT_CONFIG, AuditConfig } from './services/audit.service';
import { GovernanceReviewPanelComponent } from './components/governance-review-panel.component';

/** Combined configuration */
export interface GenUiGovernanceConfig {
  governance?: GovernanceConfig;
  audit?: AuditConfig;
}

@NgModule({
  imports: [CommonModule, GovernanceReviewPanelComponent],
  exports: [GovernanceReviewPanelComponent],
})
export class GenUiGovernanceModule {
  static forRoot(config?: GenUiGovernanceConfig): ModuleWithProviders<GenUiGovernanceModule> {
    return {
      ngModule: GenUiGovernanceModule,
      providers: [
        { provide: GOVERNANCE_CONFIG, useValue: config?.governance || {} },
        { provide: AUDIT_CONFIG, useValue: config?.audit || {} },
        GovernanceService,
        AuditService,
      ],
    };
  }

  static forChild(): ModuleWithProviders<GenUiGovernanceModule> {
    return {
      ngModule: GenUiGovernanceModule,
      providers: [],
    };
  }
}

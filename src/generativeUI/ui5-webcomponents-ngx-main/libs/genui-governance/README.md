# @ui5/genui-governance

Security and governance layer for SAP Generative UI - action confirmation, audit logging, and policy enforcement.

## Overview

Enterprise AI interfaces require explicit governance. This library provides:

- **Action Confirmation** - Human-in-the-loop approval for sensitive operations
- **Audit Logging** - Complete traceability of AI-generated UI actions
- **Policy Enforcement** - Configurable rules for what AI can do
- **Data Lineage** - Track data sources displayed in generated UI

## Features

- Action confirmation dialogs with modification support
- Audit trail for compliance (SOX, GDPR, etc.)
- Policy engine for action restrictions
- Data source attribution and lineage tracking
- Role-based action permissions

## Installation

```bash
npm install @ui5/genui-governance
```

## Usage

### Basic Setup

```typescript
import { GenUiGovernanceModule } from '@ui5/genui-governance';

@NgModule({
  imports: [
    GenUiGovernanceModule.forRoot({
      requireConfirmation: ['purchase_order', 'payment', 'approval'],
      auditLevel: 'full',
      policyEndpoint: '/api/policies'
    })
  ]
})
export class AppModule {}
```

### Action Confirmation

```typescript
import { GovernanceService } from '@ui5/genui-governance';

@Component({...})
export class MyComponent {
  constructor(private governance: GovernanceService) {
    // Actions requiring confirmation automatically show dialogs
    this.governance.pendingActions$.subscribe(action => {
      console.log('Action pending approval:', action);
    });
  }
  
  // Programmatic confirmation
  async confirmAction(actionId: string, modifications?: object) {
    await this.governance.confirmAction(actionId, modifications);
  }
  
  async rejectAction(actionId: string, reason: string) {
    await this.governance.rejectAction(actionId, reason);
  }
}
```

### Audit Trail

```typescript
import { AuditService } from '@ui5/genui-governance';

@Injectable()
export class ComplianceService {
  constructor(private audit: AuditService) {
    // All UI actions are automatically logged
    this.audit.entries$.subscribe(entry => {
      console.log('Audit:', entry);
    });
  }
  
  // Query audit log
  async getAuditTrail(options: AuditQuery): Promise<AuditEntry[]> {
    return this.audit.query(options);
  }
}
```

## Audit Entry Format

```typescript
interface AuditEntry {
  id: string;
  timestamp: string;
  userId: string;
  sessionId: string;
  runId: string;
  
  // Action details
  action: {
    type: 'ui_render' | 'tool_call' | 'user_input' | 'confirmation' | 'rejection';
    componentId?: string;
    toolName?: string;
    arguments?: object;
  };
  
  // Outcome
  outcome: 'success' | 'failure' | 'pending' | 'rejected';
  
  // Data lineage
  dataSources?: DataSource[];
  
  // Modifications made during confirmation
  modifications?: object;
  
  // Context
  context: {
    userAgent: string;
    ipAddress?: string;
    location?: string;
  };
}
```

## Policy Configuration

```typescript
interface PolicyConfig {
  // Actions that always require confirmation
  requireConfirmation: string[];
  
  // Actions that are blocked entirely
  blockedActions: string[];
  
  // Role-based permissions
  rolePermissions: {
    [role: string]: {
      allowed: string[];
      denied: string[];
      requireConfirmation: string[];
    };
  };
  
  // Data sensitivity rules
  dataPolicies: {
    // Mask sensitive fields in audit logs
    maskFields: string[];
    // Don't log certain data types
    excludeFromAudit: string[];
  };
}
```

## License

Apache-2.0 - SAP SE
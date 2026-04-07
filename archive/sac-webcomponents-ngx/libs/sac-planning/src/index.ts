/**
 * @sap-oss/sac-webcomponents-ngx/planning
 *
 * Angular Planning Module for SAP Analytics Cloud planning operations.
 * Components derived from mangle/sac_widget.mg module_component "planning" facts.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacPlanningModule } from './lib/sac-planning.module';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacPlanningModelService } from './lib/services/sac-planning-model.service';
export { SacDataActionService } from './lib/services/sac-data-action.service';
export { SacAllocationService } from './lib/services/sac-allocation.service';

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

export { SacPlanningPanelComponent } from './lib/components/sac-planning-panel.component';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  PlanningModel,
  PlanningSession,
  LockInfo,
  VersionInfo,
  PlanningAreaInfo,
  PlanningAreaFilter,
  PlanningAreaMemberInfo,
} from './lib/types/planning-model.types';

export type {
  DataAction,
  DataActionParameter,
  DataActionResult,
  DataActionTrigger,
} from './lib/types/data-action.types';

export type {
  Allocation,
  AllocationParameter,
  AllocationResult,
} from './lib/types/allocation.types';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type {
  PlanningEvents,
  DataActionExecutedEvent,
  VersionChangedEvent,
  DataLockedEvent,
} from './lib/types/planning-events.types';

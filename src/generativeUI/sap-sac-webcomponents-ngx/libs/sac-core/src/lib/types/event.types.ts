export interface SacEvent {
  type: SacEventType;
  payload?: unknown;
  timestamp: number;
  source?: string;
}

export type SacEventType =
  | 'widget:click'
  | 'widget:resize'
  | 'widget:visibility'
  | 'data:loaded'
  | 'data:error'
  | 'filter:changed'
  | 'selection:changed'
  | 'navigation:page'
  | 'custom'
  | string;

export type SacEventHandler = (event: SacEvent) => void;

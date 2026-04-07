export interface UIIntent {
  action: string;
  payload?: any;
  sourceType?: string;
}

export interface GenerativeNode {
  /** HTML tag or UI5 component name (e.g., 'ui5-button', 'div', 'ui5-card') */
  type: string;
  /** Properties/Attributes to apply to the element */
  props?: Record<string, any>;
  /** Direct text content for the element */
  content?: string;
  /** Children nodes */
  children?: GenerativeNode[];
  /** Intent to dispatch on interaction (click/input) */
  intent?: UIIntent;
}

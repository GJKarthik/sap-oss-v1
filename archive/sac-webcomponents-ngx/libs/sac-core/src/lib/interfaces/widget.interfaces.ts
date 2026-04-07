export interface WidgetState {
  visible: boolean;
  enabled: boolean;
  selected: boolean;
  focused: boolean;
}

export interface WidgetSearchOptions {
  query?: string;
  type?: string;
  recursive?: boolean;
  maxResults?: number;
}

export interface LayoutValue {
  top?: number | string;
  left?: number | string;
  width?: number | string;
  height?: number | string;
  unit?: string;
}

export interface OperationResult {
  success: boolean;
  message?: string;
  data?: unknown;
}

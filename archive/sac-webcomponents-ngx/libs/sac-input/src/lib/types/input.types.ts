/**
 * Input control types — from sap-sac-webcomponents-ts/src/input
 */

export interface SelectionItem {
  key: string;
  text: string;
  icon?: string;
  enabled?: boolean;
}

export interface ButtonConfig {
  text?: string;
  icon?: string;
  type?: 'default' | 'emphasized' | 'transparent' | 'negative' | 'positive';
  enabled?: boolean;
  visible?: boolean;
}

export interface DropdownConfig {
  items: SelectionItem[];
  selectedKey?: string;
  placeholder?: string;
  enabled?: boolean;
  visible?: boolean;
}

export interface InputFieldConfig {
  value?: string;
  placeholder?: string;
  type?: 'text' | 'number' | 'password' | 'email';
  maxLength?: number;
  enabled?: boolean;
  visible?: boolean;
  required?: boolean;
}

export interface DatePickerConfig {
  value?: string;
  minDate?: string;
  maxDate?: string;
  format?: string;
  enabled?: boolean;
  visible?: boolean;
}

export interface SliderConfig {
  value?: number;
  min?: number;
  max?: number;
  step?: number;
  enabled?: boolean;
  visible?: boolean;
}

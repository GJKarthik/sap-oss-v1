/**
 * Input control event types — from sap-sac-webcomponents-ts/src/input
 */

export interface ButtonClickEvent {
  buttonId: string;
  timestamp: number;
}

export interface DropdownChangeEvent {
  selectedKey: string;
  selectedValue: string;
  previousKey?: string;
}

export interface InputFieldChangeEvent {
  value: string;
  previousValue?: string;
  valid: boolean;
}

export interface DatePickerChangeEvent {
  date: string;
  previousDate?: string;
}

export interface SliderChangeEvent {
  value: number;
  previousValue?: number;
}

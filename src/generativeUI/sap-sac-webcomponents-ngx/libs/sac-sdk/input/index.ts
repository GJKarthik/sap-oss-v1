/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Button, Dropdown, InputField, TextArea, Slider, RangeSlider,
 *   Switch, CheckboxGroup, RadioButtonGroup, DatePicker, TimePicker, DateTimePicker,
 *   Calendar, FilterLine, InputControl, ListBox, ColorPicker, FileUploader
 *
 * Maps to: sac_widgets.mg categories "Action", "Input"
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/input-controls/ (16 handlers)
 */

import type { OperationResult } from '../types';
import { Widget } from '../widgets';

// ---------------------------------------------------------------------------
// Shared input types
// ---------------------------------------------------------------------------

export interface SelectionItem {
  key: string;
  text: string;
  icon?: string;
  enabled?: boolean;
}

// ---------------------------------------------------------------------------
// Button
// ---------------------------------------------------------------------------

export class Button extends Widget {
  async getText(): Promise<string> { return this.client.get(`/input/${e(this.id)}/text`); }
  async setText(text: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/text`, { text }); }
  async getIcon(): Promise<string> { return this.client.get(`/input/${e(this.id)}/icon`); }
  async setIcon(icon: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/icon`, { icon }); }
  async getTooltip(): Promise<string> { return this.client.get(`/input/${e(this.id)}/tooltip`); }
  async setTooltip(tooltip: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/tooltip`, { tooltip }); }
  async getType(): Promise<string> { return this.client.get(`/input/${e(this.id)}/type`); }
  async setType(type: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/type`, { type }); }
  async click(): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/click`); }
}

// ---------------------------------------------------------------------------
// Dropdown
// ---------------------------------------------------------------------------

export class Dropdown extends Widget {
  async getSelectedKey(): Promise<string> { return this.client.get(`/input/${e(this.id)}/selectedKey`); }
  async setSelectedKey(key: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selectedKey`, { key }); }
  async getSelectedItem(): Promise<SelectionItem> { return this.client.get(`/input/${e(this.id)}/selectedItem`); }
  async getItems(): Promise<SelectionItem[]> { return this.client.get(`/input/${e(this.id)}/items`); }
  async setItems(items: SelectionItem[]): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/items`, { items }); }
  async addItem(item: SelectionItem): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/items`, item); }
  async removeItem(key: string): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/items/${e(key)}`); }
  async clearItems(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/items`); }
}

// ---------------------------------------------------------------------------
// InputField
// ---------------------------------------------------------------------------

export class InputField extends Widget {
  async getValue(): Promise<string> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
  async getPlaceholder(): Promise<string> { return this.client.get(`/input/${e(this.id)}/placeholder`); }
  async setPlaceholder(placeholder: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/placeholder`, { placeholder }); }
  async getMaxLength(): Promise<number> { return this.client.get(`/input/${e(this.id)}/maxLength`); }
  async setMaxLength(maxLength: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/maxLength`, { maxLength }); }
  async getType(): Promise<string> { return this.client.get(`/input/${e(this.id)}/type`); }
  async setType(type: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/type`, { type }); }
  async isRequired(): Promise<boolean> { return this.client.get(`/input/${e(this.id)}/required`); }
  async setRequired(required: boolean): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/required`, { required }); }
  async clear(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/value`); }
  async focus(): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/focus`); }
}

// ---------------------------------------------------------------------------
// TextArea
// ---------------------------------------------------------------------------

export class TextArea extends Widget {
  async getValue(): Promise<string> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
  async setPlaceholder(placeholder: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/placeholder`, { placeholder }); }
  async setRows(rows: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/rows`, { rows }); }
  async setMaxLength(maxLength: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/maxLength`, { maxLength }); }
  async clear(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/value`); }
  async focus(): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/focus`); }
}

// ---------------------------------------------------------------------------
// Slider
// ---------------------------------------------------------------------------

export class Slider extends Widget {
  async getValue(): Promise<number> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
  async getMin(): Promise<number> { return this.client.get(`/input/${e(this.id)}/min`); }
  async setMin(min: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/min`, { min }); }
  async getMax(): Promise<number> { return this.client.get(`/input/${e(this.id)}/max`); }
  async setMax(max: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/max`, { max }); }
  async getStep(): Promise<number> { return this.client.get(`/input/${e(this.id)}/step`); }
  async setStep(step: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/step`, { step }); }
}

// ---------------------------------------------------------------------------
// RangeSlider
// ---------------------------------------------------------------------------

export class RangeSlider extends Widget {
  async getStartValue(): Promise<number> { return this.client.get(`/input/${e(this.id)}/startValue`); }
  async setStartValue(value: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/startValue`, { value }); }
  async getEndValue(): Promise<number> { return this.client.get(`/input/${e(this.id)}/endValue`); }
  async setEndValue(value: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/endValue`, { value }); }
  async setMin(min: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/min`, { min }); }
  async setMax(max: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/max`, { max }); }
  async setStep(step: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/step`, { step }); }
}

// ---------------------------------------------------------------------------
// Switch
// ---------------------------------------------------------------------------

export class Switch extends Widget {
  async getValue(): Promise<boolean> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: boolean): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
  async toggle(): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/toggle`); }
}

// ---------------------------------------------------------------------------
// CheckboxGroup
// ---------------------------------------------------------------------------

export class CheckboxGroup extends Widget {
  async getSelectedKeys(): Promise<string[]> { return this.client.get(`/input/${e(this.id)}/selectedKeys`); }
  async setSelectedKeys(keys: string[]): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selectedKeys`, { keys }); }
  async getItems(): Promise<SelectionItem[]> { return this.client.get(`/input/${e(this.id)}/items`); }
  async setItems(items: SelectionItem[]): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/items`, { items }); }
  async addItem(item: SelectionItem): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/items`, item); }
  async removeItem(key: string): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/items/${e(key)}`); }
  async clearSelection(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/selectedKeys`); }
  async selectAll(): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/selectAll`); }
}

// ---------------------------------------------------------------------------
// RadioButtonGroup
// ---------------------------------------------------------------------------

export class RadioButtonGroup extends Widget {
  async getSelectedKey(): Promise<string> { return this.client.get(`/input/${e(this.id)}/selectedKey`); }
  async setSelectedKey(key: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selectedKey`, { key }); }
  async getItems(): Promise<SelectionItem[]> { return this.client.get(`/input/${e(this.id)}/items`); }
  async setItems(items: SelectionItem[]): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/items`, { items }); }
  async addItem(item: SelectionItem): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/items`, item); }
  async removeItem(key: string): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/items/${e(key)}`); }
}

// ---------------------------------------------------------------------------
// ListBox
// ---------------------------------------------------------------------------

export class ListBox extends Widget {
  async getSelectedKeys(): Promise<string[]> { return this.client.get(`/input/${e(this.id)}/selectedKeys`); }
  async setSelectedKeys(keys: string[]): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selectedKeys`, { keys }); }
  async getItems(): Promise<SelectionItem[]> { return this.client.get(`/input/${e(this.id)}/items`); }
  async setItems(items: SelectionItem[]): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/items`, { items }); }
  async setMultiSelect(multi: boolean): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/multiSelect`, { multi }); }
  async isMultiSelect(): Promise<boolean> { return this.client.get(`/input/${e(this.id)}/multiSelect`); }
  async addItem(item: SelectionItem): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/items`, item); }
  async removeItem(key: string): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/items/${e(key)}`); }
}

// ---------------------------------------------------------------------------
// DatePicker
// ---------------------------------------------------------------------------

export class DatePicker extends Widget {
  async getValue(): Promise<string> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
  async setMinDate(date: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/minDate`, { date }); }
  async setMaxDate(date: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/maxDate`, { date }); }
  async setDateFormat(format: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/dateFormat`, { format }); }
  async getDateFormat(): Promise<string> { return this.client.get(`/input/${e(this.id)}/dateFormat`); }
  async clear(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/value`); }
}

// ---------------------------------------------------------------------------
// TimePicker
// ---------------------------------------------------------------------------

export class TimePicker extends Widget {
  async getValue(): Promise<string> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
  async setTimeFormat(format: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/timeFormat`, { format }); }
  async getTimeFormat(): Promise<string> { return this.client.get(`/input/${e(this.id)}/timeFormat`); }
}

// ---------------------------------------------------------------------------
// DateTimePicker
// ---------------------------------------------------------------------------

export class DateTimePicker extends Widget {
  async getValue(): Promise<string> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
  async setMinDate(date: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/minDate`, { date }); }
  async setMaxDate(date: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/maxDate`, { date }); }
  async setDateTimeFormat(format: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/dateTimeFormat`, { format }); }
}

// ---------------------------------------------------------------------------
// Calendar (input calendar widget, not planning calendar)
// ---------------------------------------------------------------------------

export class CalendarWidget extends Widget {
  async getSelectedDate(): Promise<string> { return this.client.get(`/input/${e(this.id)}/selectedDate`); }
  async setSelectedDate(date: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selectedDate`, { date }); }
  async getSelectedDates(): Promise<string[]> { return this.client.get(`/input/${e(this.id)}/selectedDates`); }
  async setSelectionMode(mode: 'single' | 'multiple' | 'range'): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selectionMode`, { mode }); }
  async setMinDate(date: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/minDate`, { date }); }
  async setMaxDate(date: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/maxDate`, { date }); }
  async navigateToMonth(year: number, month: number): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/navigateToMonth`, { year, month }); }
  async navigateToYear(year: number): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/navigateToYear`, { year }); }
}

// ---------------------------------------------------------------------------
// FilterLine
// ---------------------------------------------------------------------------

export class FilterLine extends Widget {
  async getSelection(): Promise<unknown> { return this.client.get(`/input/${e(this.id)}/selection`); }
  async setSelection(selection: unknown): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selection`, selection); }
  async getDimensionId(): Promise<string> { return this.client.get(`/input/${e(this.id)}/dimensionId`); }
  async clearSelection(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/selection`); }
  async setDataSource(dsName: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/datasource`, { name: dsName }); }
  async getDataSource(): Promise<string> { return this.client.get(`/input/${e(this.id)}/datasource`); }
  async refresh(): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/refresh`); }
}

// ---------------------------------------------------------------------------
// InputControl (smart input control with data binding)
// ---------------------------------------------------------------------------

export class InputControl extends Widget {
  async getSelection(): Promise<unknown> { return this.client.get(`/input/${e(this.id)}/selection`); }
  async setSelection(selection: unknown): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/selection`, selection); }
  async getDimensionId(): Promise<string> { return this.client.get(`/input/${e(this.id)}/dimensionId`); }
  async clearSelection(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/selection`); }
  async setDataSource(dsName: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/datasource`, { name: dsName }); }
  async getDataSource(): Promise<string> { return this.client.get(`/input/${e(this.id)}/datasource`); }
  async setMultiSelect(multi: boolean): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/multiSelect`, { multi }); }
  async isMultiSelect(): Promise<boolean> { return this.client.get(`/input/${e(this.id)}/multiSelect`); }
  async setHierarchical(hierarchical: boolean): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/hierarchical`, { hierarchical }); }
  async isHierarchical(): Promise<boolean> { return this.client.get(`/input/${e(this.id)}/hierarchical`); }
}

// ---------------------------------------------------------------------------
// ColorPicker
// ---------------------------------------------------------------------------

export class ColorPicker extends Widget {
  async getValue(): Promise<string> { return this.client.get(`/input/${e(this.id)}/value`); }
  async setValue(value: string): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/value`, { value }); }
}

// ---------------------------------------------------------------------------
// FileUploader
// ---------------------------------------------------------------------------

export class FileUploader extends Widget {
  async upload(): Promise<OperationResult> { return this.client.post(`/input/${e(this.id)}/upload`); }
  async clear(): Promise<OperationResult> { return this.client.del(`/input/${e(this.id)}/value`); }
  async setAcceptedTypes(types: string[]): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/acceptedTypes`, { types }); }
  async setMaxFileSize(sizeBytes: number): Promise<OperationResult> { return this.client.put(`/input/${e(this.id)}/maxFileSize`, { sizeBytes }); }
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface ButtonEvents {
  click: () => void;
}

export interface DropdownEvents {
  select: (key: string) => void;
}

export interface InputFieldEvents {
  change: (value: string) => void;
  submit: (value: string) => void;
}

export interface TextAreaEvents {
  change: (value: string) => void;
}

export interface SliderEvents {
  change: (value: number) => void;
}

export interface RangeSliderEvents {
  change: (startValue: number, endValue: number) => void;
}

export interface SwitchEvents {
  change: (value: boolean) => void;
}

export interface CheckboxGroupEvents {
  select: (selectedKeys: string[]) => void;
}

export interface RadioButtonGroupEvents {
  select: (selectedKey: string) => void;
}

export interface ListBoxEvents {
  select: (selectedKeys: string[]) => void;
}

export interface DatePickerEvents {
  select: (date: string) => void;
  change: (oldValue: string, newValue: string) => void;
}

export interface TimePickerEvents {
  select: (time: string) => void;
  change: (oldValue: string, newValue: string) => void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }

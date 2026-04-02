/**
 * @sap-oss/sac-webcomponents-ngx/sdk — Application, ScriptObject, Layout, NucleusApplicationInfo, utilities
 *
 * Specs:
 *   standard/application_client.odps.yaml
 *   standard/applicationinfo_client.odps.yaml
 *   standard/scriptobject_client.odps.yaml
 *   standard/layout_client.odps.yaml
 *   standard/navigationutils_client.odps.yaml
 *   standard/numberformat_client.odps.yaml
 *   standard/dateformat_client.odps.yaml
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/core/ + built-in-objects/
 */

import { type SACRestAPIClient, SACError } from '../client';
import type {
  OperationResult, LayoutValue, UserInfo, TeamInfo,
  ApplicationInfo, ExtendedApplicationInfo, ApplicationPermissions,
  ApplicationVersion, ApplicationDependency, ApplicationUsage, ApplicationMetadata,
  SharedUser, NotificationOptions, ThemeInfo,
  ScriptMethod,
  DeviceType, ViewMode, ApplicationMessageType,
} from '../types';

type EventHandler = (...args: unknown[]) => void;

// ---------------------------------------------------------------------------
// ScriptObject — base for all SAC scripting objects
// Spec: scriptobject_client.odps.yaml
// ---------------------------------------------------------------------------

export class ScriptObject {
  protected _handlers: Map<string, Set<EventHandler>> = new Map();

  constructor(protected readonly client: SACRestAPIClient, public readonly id: string) {}

  // -- Properties -----------------------------------------------------------

  async getName(): Promise<string> {
    return this.client.get<string>(`/scriptobject/${e(this.id)}/name`);
  }

  async getDescription(): Promise<string> {
    return this.client.get<string>(`/scriptobject/${e(this.id)}/description`);
  }

  // -- Method execution -----------------------------------------------------

  async invokeMethod(methodName: string, args?: unknown[]): Promise<unknown> {
    return this.client.post(`/scriptobject/${e(this.id)}/invoke/${e(methodName)}`, { args });
  }

  async getMethods(): Promise<ScriptMethod[]> {
    return this.client.get<ScriptMethod[]>(`/scriptobject/${e(this.id)}/methods`);
  }

  // -- State ----------------------------------------------------------------

  async getState(): Promise<Record<string, unknown>> {
    return this.client.get<Record<string, unknown>>(`/scriptobject/${e(this.id)}/state`);
  }

  async setState(state: Record<string, unknown>): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/scriptobject/${e(this.id)}/state`, state);
  }

  async getProperty<T>(propertyName: string): Promise<T> {
    return this.client.get<T>(`/scriptobject/${e(this.id)}/property/${e(propertyName)}`);
  }

  async setProperty(propertyName: string, value: unknown): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/scriptobject/${e(this.id)}/property/${e(propertyName)}`, { value },
    );
  }

  // -- Events ---------------------------------------------------------------

  on(event: string, handler: EventHandler): this {
    if (!this._handlers.has(event)) this._handlers.set(event, new Set());
    this._handlers.get(event)!.add(handler);
    return this;
  }

  off(event: string, handler: EventHandler): this {
    this._handlers.get(event)?.delete(handler);
    return this;
  }

  once(event: string, handler: EventHandler): this {
    const wrapper: EventHandler = (...args) => { this.off(event, wrapper); handler(...args); };
    return this.on(event, wrapper);
  }

  // -- Factory --------------------------------------------------------------

  static async getScriptObject(client: SACRestAPIClient, name: string): Promise<ScriptObject> {
    const data = await client.get<{ id: string }>(`/scriptobject/byName/${e(name)}`);
    return new ScriptObject(client, data.id);
  }

  static async getAllScriptObjects(client: SACRestAPIClient): Promise<ScriptObject[]> {
    const list = await client.get<Array<{ id: string }>>('/scriptobject');
    return list.map(item => new ScriptObject(client, item.id));
  }
}

// ---------------------------------------------------------------------------
// Application — singleton root object
// Spec: application_client.odps.yaml
// ---------------------------------------------------------------------------

export class Application extends ScriptObject {
  constructor(client: SACRestAPIClient) {
    super(client, '__application__');
  }

  static getInstance(client: SACRestAPIClient): Application {
    return new Application(client);
  }

  // -- Navigation -----------------------------------------------------------

  async openStory(storyId: string, pageId?: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/openStory', { storyId, pageId });
  }

  async openApplication(appId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/openApplication', { appId });
  }

  async goToPage(pageId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/goToPage', { pageId });
  }

  async goToPageByIndex(index: number): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/goToPageByIndex', { index });
  }

  // -- Dialogs --------------------------------------------------------------

  async showMessage(type: ApplicationMessageType, message: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/showMessage', { type, message });
  }

  async showAlert(message: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/showAlert', { message });
  }

  async showConfirm(message: string, callback?: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/showConfirm', { message, callback });
  }

  async showPopup(popupId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/showPopup', { popupId });
  }

  async closePopup(popupId: string): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/closePopup', { popupId });
  }

  // -- Context --------------------------------------------------------------

  async getDeviceType(): Promise<DeviceType> {
    return this.client.get<DeviceType>('/app/deviceType');
  }

  async getViewMode(): Promise<ViewMode> {
    return this.client.get<ViewMode>('/app/viewMode');
  }

  async getUserInfo(): Promise<UserInfo> {
    return this.client.get<UserInfo>('/app/user');
  }

  async getTeamInfo(): Promise<TeamInfo> {
    return this.client.get<TeamInfo>('/app/team');
  }

  async getTheme(): Promise<ThemeInfo> {
    return this.client.get<ThemeInfo>('/app/theme');
  }

  async getLanguage(): Promise<string> {
    return this.client.get<string>('/app/language');
  }

  async getInfo(): Promise<ApplicationInfo> {
    return this.client.get<ApplicationInfo>('/app/info');
  }

  // -- Notifications --------------------------------------------------------

  async sendNotification(
    receivers: string[], options: NotificationOptions,
  ): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/notification', { receivers, ...options });
  }

  // -- Utilities ------------------------------------------------------------

  async refresh(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/refresh');
  }

  async refreshData(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/refreshData');
  }

  async setBusy(busy: boolean): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/setBusy', { busy });
  }

  async print(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/print');
  }

  async undo(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/undo');
  }

  async redo(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/redo');
  }

  async createUUID(): Promise<string> {
    const r = await this.client.post<{ uuid: string }>('/app/uuid');
    return r.uuid;
  }

  // -- Shared objects -------------------------------------------------------

  async getSharedObject<T>(key: string): Promise<T> {
    return this.client.get<T>(`/app/shared/${e(key)}`);
  }

  async setSharedObject(key: string, value: unknown): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/app/shared/${e(key)}`, { value });
  }

  // -- Parameters -----------------------------------------------------------

  async getParameter(name: string): Promise<string> {
    return this.client.get<string>(`/app/parameter/${e(name)}`);
  }

  async setParameter(name: string, value: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(`/app/parameter/${e(name)}`, { value });
  }

  async close(): Promise<OperationResult> {
    return this.client.post<OperationResult>('/app/close');
  }
}

// ---------------------------------------------------------------------------
// NucleusApplicationInfo — extended metadata via backend
// Spec: applicationinfo_client.odps.yaml (wiring: /api/v1/sac/applicationinfo)
// ---------------------------------------------------------------------------

const APP_INFO_BASE = '/applicationinfo';

export class NucleusApplicationInfo {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly id: string,
    public readonly name: string,
    public readonly description: string,
  ) {}

  static fromSACInfo(client: SACRestAPIClient, info: ApplicationInfo): NucleusApplicationInfo {
    return new NucleusApplicationInfo(client, info.id, info.name, info.description);
  }

  static async getCurrent(client: SACRestAPIClient): Promise<NucleusApplicationInfo> {
    const info = await client.get<ApplicationInfo>('/app/info');
    return NucleusApplicationInfo.fromSACInfo(client, info);
  }

  // -- Extended information (GET /{appId}/...) -------------------------------

  async getFullMetadata(): Promise<ApplicationMetadata> {
    return this.client.get<ApplicationMetadata>(`${APP_INFO_BASE}/${e(this.id)}/metadata`);
  }

  async getExtendedInfo(): Promise<ExtendedApplicationInfo> {
    return this.client.get<ExtendedApplicationInfo>(`${APP_INFO_BASE}/${e(this.id)}/extended`);
  }

  async getPermissions(): Promise<ApplicationPermissions> {
    return this.client.get<ApplicationPermissions>(`${APP_INFO_BASE}/${e(this.id)}/permissions`);
  }

  async getDependencies(): Promise<ApplicationDependency[]> {
    return this.client.get<ApplicationDependency[]>(`${APP_INFO_BASE}/${e(this.id)}/dependencies`);
  }

  async getUsage(): Promise<ApplicationUsage> {
    return this.client.get<ApplicationUsage>(`${APP_INFO_BASE}/${e(this.id)}/usage`);
  }

  // -- Version management ---------------------------------------------------

  async getVersions(): Promise<ApplicationVersion[]> {
    return this.client.get<ApplicationVersion[]>(`${APP_INFO_BASE}/${e(this.id)}/versions`);
  }

  async getCurrentVersion(): Promise<ApplicationVersion> {
    const versions = await this.getVersions();
    const current = versions.find(v => v.isCurrent);
    if (!current) throw new Error('No current version found');
    return current;
  }

  async getVersion(version: string): Promise<ApplicationVersion | undefined> {
    const versions = await this.getVersions();
    return versions.find(v => v.version === version);
  }

  // -- Sharing --------------------------------------------------------------

  async getSharedUsers(): Promise<SharedUser[]> {
    return this.client.get<SharedUser[]>(`${APP_INFO_BASE}/${e(this.id)}/sharing`);
  }

  async shareWith(
    userId: string, permission: 'view' | 'edit' | 'admin',
  ): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/sharing`, { userId, permission },
    );
  }

  async unshare(userId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/sharing/${e(userId)}`,
    );
  }

  async setPublicAccess(access: 'none' | 'view' | 'edit'): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/publicAccess`, { access },
    );
  }

  // -- Tags & categories ----------------------------------------------------

  async getTags(): Promise<string[]> {
    return this.client.get<string[]>(`${APP_INFO_BASE}/${e(this.id)}/tags`);
  }

  async addTag(tag: string): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/tags`, { tag },
    );
  }

  async removeTag(tag: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/tags/${e(tag)}`,
    );
  }

  async setCategory(category: string): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/category`, { category },
    );
  }

  // -- Custom properties ----------------------------------------------------

  async getCustomProperty<T>(key: string): Promise<T | undefined> {
    return this.client.get<T | undefined>(
      `${APP_INFO_BASE}/${e(this.id)}/properties/${e(key)}`,
    );
  }

  async setCustomProperty(key: string, value: unknown): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/properties/${e(key)}`, { value },
    );
  }

  async removeCustomProperty(key: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(
      `${APP_INFO_BASE}/${e(this.id)}/properties/${e(key)}`,
    );
  }

  async getCustomProperties(): Promise<Record<string, unknown>> {
    return this.client.get<Record<string, unknown>>(
      `${APP_INFO_BASE}/${e(this.id)}/properties`,
    );
  }

  // -- Serialisation --------------------------------------------------------

  toJSON(): ApplicationInfo {
    return { id: this.id, name: this.name, description: this.description };
  }

  async toExtendedJSON(): Promise<ExtendedApplicationInfo> {
    return this.getExtendedInfo();
  }

  toString(): string {
    return `NucleusApplicationInfo(${this.id}, ${this.name})`;
  }

  equals(other: NucleusApplicationInfo): boolean {
    return this.id === other.id;
  }
}

// ---------------------------------------------------------------------------
// Layout — widget positioning/sizing
// Spec: layout_client.odps.yaml
// ---------------------------------------------------------------------------

export class Layout {
  constructor(private readonly client: SACRestAPIClient, private readonly widgetId: string) {}

  async getBottom(): Promise<LayoutValue> {
    return this.client.get<LayoutValue>(`/widget/${e(this.widgetId)}/layout/bottom`);
  }

  async getHeight(): Promise<LayoutValue> {
    return this.client.get<LayoutValue>(`/widget/${e(this.widgetId)}/layout/height`);
  }

  async getLeft(): Promise<LayoutValue> {
    return this.client.get<LayoutValue>(`/widget/${e(this.widgetId)}/layout/left`);
  }

  async getRight(): Promise<LayoutValue> {
    return this.client.get<LayoutValue>(`/widget/${e(this.widgetId)}/layout/right`);
  }

  async getTop(): Promise<LayoutValue> {
    return this.client.get<LayoutValue>(`/widget/${e(this.widgetId)}/layout/top`);
  }

  async getWidth(): Promise<LayoutValue> {
    return this.client.get<LayoutValue>(`/widget/${e(this.widgetId)}/layout/width`);
  }
}

// ---------------------------------------------------------------------------
// Utility classes — StringUtils, DateUtils, MathUtils
// Specs: built-in-objects/string_client, date_client, math_client
// ---------------------------------------------------------------------------

export class StringUtils {
  constructor(private readonly client: SACRestAPIClient) {}
  async format(template: string, ...args: string[]): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/string/format', { template, args });
    return r.result;
  }
  async concat(...parts: string[]): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/string/concat', { parts });
    return r.result;
  }
  async substring(str: string, start: number, end?: number): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/string/substring', { str, start, end });
    return r.result;
  }
  async replace(str: string, search: string, replacement: string): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/string/replace', { str, search, replacement });
    return r.result;
  }
  async split(str: string, separator: string): Promise<string[]> {
    const r = await this.client.post<{ result: string[] }>('/util/string/split', { str, separator });
    return r.result;
  }
  async join(parts: string[], separator: string): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/string/join', { parts, separator });
    return r.result;
  }
}

export class DateUtils {
  constructor(private readonly client: SACRestAPIClient) {}
  async format(date: string, pattern: string): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/date/format', { date, pattern });
    return r.result;
  }
  async parse(str: string, pattern: string): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/date/parse', { str, pattern });
    return r.result;
  }
  async addDays(date: string, days: number): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/date/addDays', { date, days });
    return r.result;
  }
  async addMonths(date: string, months: number): Promise<string> {
    const r = await this.client.post<{ result: string }>('/util/date/addMonths', { date, months });
    return r.result;
  }
  async diff(date1: string, date2: string): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/date/diff', { date1, date2 });
    return r.result;
  }
  async now(): Promise<string> {
    const r = await this.client.get<{ result: string }>('/util/date/now');
    return r.result;
  }
  async today(): Promise<string> {
    const r = await this.client.get<{ result: string }>('/util/date/today');
    return r.result;
  }
}

export class MathUtils {
  constructor(private readonly client: SACRestAPIClient) {}
  async round(value: number, decimals?: number): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/round', { value, decimals });
    return r.result;
  }
  async floor(value: number): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/floor', { value });
    return r.result;
  }
  async ceil(value: number): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/ceil', { value });
    return r.result;
  }
  async abs(value: number): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/abs', { value });
    return r.result;
  }
  async min(...values: number[]): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/min', { values });
    return r.result;
  }
  async max(...values: number[]): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/max', { values });
    return r.result;
  }
  async sum(values: number[]): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/sum', { values });
    return r.result;
  }
  async average(values: number[]): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/average', { values });
    return r.result;
  }
  async sqrt(value: number): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/sqrt', { value });
    return r.result;
  }
  async pow(base: number, exponent: number): Promise<number> {
    const r = await this.client.post<{ result: number }>('/util/math/pow', { base, exponent });
    return r.result;
  }
}

// ---------------------------------------------------------------------------
// NumberFormat / DateFormat / ConditionalFormat
// Specs: numberformat_client, dateformat_client
// ---------------------------------------------------------------------------

export interface NumberFormatConfig {
  pattern?: string;
  decimalPlaces?: number;
  scaling?: number;
  unit?: string;
  thousandsSeparator?: string;
}

export interface DateFormatConfig {
  pattern: string;
}

export interface ConditionalFormatRule {
  condition: string;
  style: Record<string, string>;
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface ApplicationEvents {
  initialization: () => void;
  navigation: (pageId: string) => void;
}

// ---------------------------------------------------------------------------
// Error classes (Rule 6) — from applicationinfo_client.odps.yaml
// ---------------------------------------------------------------------------

export class ApplicationNotFoundError extends SACError {
  constructor(message = 'Application not found') { super(message, 404, 'APPLICATION_NOT_FOUND'); }
}

export class PermissionDeniedError extends SACError {
  constructor(message = 'Permission denied for this operation') { super(message, 403, 'PERMISSION_DENIED'); }
}

export class UserNotFoundError extends SACError {
  constructor(message = 'User not found for sharing') { super(message, 404, 'USER_NOT_FOUND'); }
}

export class TagExistsError extends SACError {
  constructor(message = 'Tag already exists') { super(message, 409, 'TAG_EXISTS'); }
}

export class PropertyNotFoundError extends SACError {
  constructor(message = 'Custom property not found') { super(message, 404, 'PROPERTY_NOT_FOUND'); }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }

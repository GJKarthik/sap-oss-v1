export interface ApplicationInfo {
  id: string;
  name: string;
  description?: string;
  createdDate?: string;
  modifiedDate?: string;
  owner?: string;
}

export interface ExtendedApplicationInfo extends ApplicationInfo {
  version?: string;
  status?: string;
  tags?: string[];
  thumbnail?: string;
}

export interface ApplicationPermissions {
  canRead: boolean;
  canWrite: boolean;
  canDelete: boolean;
  canShare: boolean;
  canExecute: boolean;
}

export interface ApplicationMetadata {
  type: string;
  version: string;
  createdBy: string;
  modifiedBy?: string;
  tags?: string[];
}

export interface ThemeInfo {
  id: string;
  name: string;
  cssUrl?: string;
}

export interface UserInfo {
  id: string;
  displayName: string;
  email?: string;
  role?: string;
}

export interface TeamInfo {
  id: string;
  name: string;
  members?: string[];
}

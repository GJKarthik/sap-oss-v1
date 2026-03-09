export interface SacApiResponse<T = unknown> {
  data: T;
  status: number;
  message?: string;
}

export interface SacApiError {
  code: string;
  message: string;
  details?: string;
  status: number;
}

export interface SacPaginatedResponse<T = unknown> {
  data: T[];
  total: number;
  offset: number;
  limit: number;
  hasMore: boolean;
}

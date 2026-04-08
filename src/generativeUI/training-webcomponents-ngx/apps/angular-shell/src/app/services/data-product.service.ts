/**
 * Data Product Service — communicates with the /data-products API.
 *
 * Provides methods to list, get, update data products, and preview
 * effective LLM prompts for a given team × product combination.
 */

import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

export interface ProductSummary {
  id: string;
  name: string;
  version: string;
  description: string;
  domain: string;
  dataSecurityClass: string;
  owner: Record<string, string>;
  teamAccess: Record<string, any>;
  hasCountryViews: boolean;
  countryViewCount: number;
  fieldCount: number;
  enrichmentAvailable: boolean;
}

export interface ProductDetail {
  id: string;
  raw: Record<string, any>;
  enrichment: Record<string, any> | null;
}

export interface ProductUpdateRequest {
  teamAccess?: Record<string, any>;
  countryViews?: Record<string, any>;
}

export interface PromptPreviewRequest {
  productId: string;
  country?: string;
  domain?: string;
  basePrompt?: string;
}

export interface PromptPreviewResponse {
  effectivePrompt: string;
  glossaryTerms: Array<{ source: string; target: string; lang: string }>;
  filters: Record<string, string>;
  scopeLabel: string;
}

@Injectable({ providedIn: 'root' })
export class DataProductService {
  private readonly http = inject(HttpClient);
  private readonly base = '/api/data-products';

  listProducts(): Observable<ProductSummary[]> {
    return this.http.get<ProductSummary[]>(`${this.base}/products`);
  }

  getProduct(productId: string): Observable<ProductDetail> {
    return this.http.get<ProductDetail>(`${this.base}/products/${productId}`);
  }

  updateProduct(productId: string, update: ProductUpdateRequest): Observable<{ status: string }> {
    return this.http.patch<{ status: string }>(`${this.base}/products/${productId}`, update);
  }

  getRegistry(): Observable<Record<string, any>> {
    return this.http.get<Record<string, any>>(`${this.base}/registry`);
  }

  previewPrompt(request: PromptPreviewRequest): Observable<PromptPreviewResponse> {
    return this.http.post<PromptPreviewResponse>(`${this.base}/prompt-preview`, request);
  }

  triggerTrainingGeneration(options: {
    team?: string;
    examplesPerDomain?: number;
    validate?: boolean;
  }): Observable<{ job_id: string; status: string }> {
    return this.http.post<{ job_id: string; status: string }>('/api/jobs/training', {
      team: options.team || '',
      examples_per_domain: options.examplesPerDomain || 100000,
      validate: options.validate ?? true,
    });
  }
}

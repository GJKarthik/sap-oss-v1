import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

import { environment } from '../../../environments/environment';

export interface AIModel {
  id: string;
  name: string;
  provider: string;
  version: string;
  status: string;
  description: string | null;
  context_window: number;
  capabilities: string[];
}

export interface ModelListResponse {
  models: AIModel[];
  total: number;
}

@Injectable({ providedIn: 'root' })
export class ModelsService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = `${environment.apiBaseUrl}/models`;

  listModels(): Observable<ModelListResponse> {
    return this.http.get<ModelListResponse>(this.baseUrl);
  }

  getModel(modelId: string): Observable<AIModel> {
    return this.http.get<AIModel>(`${this.baseUrl}/${modelId}`);
  }
}
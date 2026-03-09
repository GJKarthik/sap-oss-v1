import { Injectable } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { Observable } from 'rxjs';

export interface Model {
  id: string;
  object: string;
  created: number;
  owned_by: string;
}

export interface ModelList {
  object: string;
  data: Model[];
}

export interface Message {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface ChatCompletionRequest {
  model: string;
  messages: Message[];
  temperature?: number;
  max_tokens?: number;
  stream?: boolean;
}

export interface ChatCompletionResponse {
  id: string;
  object: string;
  created: number;
  model: string;
  choices: Array<{
    index: number;
    message: Message;
    finish_reason: string;
  }>;
  usage: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
}

export interface Job {
  id: string;
  name: string;
  status: 'pending' | 'running' | 'completed' | 'failed' | 'cancelled';
  config: any;
  created_at: string;
  started_at?: string;
  completed_at?: string;
  progress: number;
  output_path?: string;
  error?: string;
}

export interface GpuStatus {
  gpu_name: string;
  compute_capability: string;
  total_memory_gb: number;
  supported_formats: string[];
}

@Injectable({
  providedIn: 'root'
})
export class ApiService {
  private baseUrl = '/api';
  
  constructor(private http: HttpClient) {}
  
  // OpenAI-compatible endpoints
  listModels(): Observable<ModelList> {
    return this.http.get<ModelList>(`${this.baseUrl}/v1/models`);
  }
  
  getModel(modelId: string): Observable<Model> {
    return this.http.get<Model>(`${this.baseUrl}/v1/models/${modelId}`);
  }
  
  createChatCompletion(request: ChatCompletionRequest): Observable<ChatCompletionResponse> {
    return this.http.post<ChatCompletionResponse>(`${this.baseUrl}/v1/chat/completions`, request);
  }
  
  createChatCompletionStream(request: ChatCompletionRequest): Observable<string> {
    const headers = new HttpHeaders({ 'Accept': 'text/event-stream' });
    return new Observable(observer => {
      const eventSource = new EventSource(`${this.baseUrl}/v1/chat/completions`);
      eventSource.onmessage = (event) => {
        if (event.data === '[DONE]') {
          observer.complete();
          eventSource.close();
        } else {
          observer.next(event.data);
        }
      };
      eventSource.onerror = (error) => {
        observer.error(error);
        eventSource.close();
      };
      return () => eventSource.close();
    });
  }
  
  // Model Optimizer endpoints
  getHealth(): Observable<{ status: string; service: string }> {
    return this.http.get<{ status: string; service: string }>(`${this.baseUrl}/health`);
  }
  
  getGpuStatus(): Observable<GpuStatus> {
    return this.http.get<GpuStatus>(`${this.baseUrl}/gpu/status`);
  }
  
  getModelCatalog(): Observable<any[]> {
    return this.http.get<any[]>(`${this.baseUrl}/models/catalog`);
  }
  
  getQuantFormats(): Observable<any> {
    return this.http.get<any>(`${this.baseUrl}/models/quant-formats`);
  }
  
  // Jobs API
  createJob(job: { config: any; name?: string }): Observable<Job> {
    return this.http.post<Job>(`${this.baseUrl}/jobs`, job);
  }
  
  listJobs(status?: string, limit?: number): Observable<Job[]> {
    let url = `${this.baseUrl}/jobs`;
    const params: string[] = [];
    if (status) params.push(`status=${status}`);
    if (limit) params.push(`limit=${limit}`);
    if (params.length) url += '?' + params.join('&');
    return this.http.get<Job[]>(url);
  }
  
  getJob(jobId: string): Observable<Job> {
    return this.http.get<Job>(`${this.baseUrl}/jobs/${jobId}`);
  }
  
  cancelJob(jobId: string): Observable<{ message: string; job_id: string }> {
    return this.http.delete<{ message: string; job_id: string }>(`${this.baseUrl}/jobs/${jobId}`);
  }
}
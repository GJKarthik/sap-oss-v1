import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { map, Observable } from 'rxjs';
import { environment } from '../../../environments/environment';
import {
  GenerateSchemaRequest,
  GenerateSchemaResponse,
} from './generative-contracts';
import { GenerativeNode } from './generative-renderer.component';

@Injectable({ providedIn: 'root' })
export class GenerativeRuntimeService {
  constructor(private readonly http: HttpClient) {}

  generateSchema(prompt: string): Observable<GenerativeNode> {
    const body: GenerateSchemaRequest = { prompt };
    const endpoint = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/ui/schema`;
    return this.http
      .post<GenerateSchemaResponse | GenerativeNode>(endpoint, body)
      .pipe(map((response) => this.unwrapSchema(response)));
  }

  private unwrapSchema(response: GenerateSchemaResponse | GenerativeNode): GenerativeNode {
    if ((response as GenerateSchemaResponse).schema) {
      const schema = (response as GenerateSchemaResponse).schema;
      if (this.isValidSchemaNode(schema)) {
        return schema;
      }
      throw new Error('Invalid generative schema contract');
    }
    if (this.isValidSchemaNode(response as GenerativeNode)) {
      return response as GenerativeNode;
    }
    throw new Error('Invalid generative schema contract');
  }

  private isValidSchemaNode(node: unknown): node is GenerativeNode {
    return Boolean(
      node &&
        typeof node === 'object' &&
        'type' in (node as Record<string, unknown>) &&
        typeof (node as { type: unknown }).type === 'string',
    );
  }
}

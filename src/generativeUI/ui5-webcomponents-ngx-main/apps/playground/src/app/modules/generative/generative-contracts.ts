import { GenerativeNode } from './generative-renderer.component';

export interface GenerateSchemaRequest {
  prompt: string;
}

export interface GenerateSchemaResponse {
  schema: GenerativeNode;
}

import { HttpClient } from '@angular/common/http';
import { Component, OnInit } from '@angular/core';
import { ExperienceHealthService } from '../../core/experience-health.service';
import { environment } from '../../../environments/environment';

interface ModelsResponse {
  data?: Array<{ id?: string }>;
}

@Component({
  selector: 'ui-angular-model-catalog-page',
  templateUrl: './model-catalog-page.component.html',
  styleUrls: ['./model-catalog-page.component.scss'],
  standalone: false,
})
export class ModelCatalogPageComponent implements OnInit {
  private readonly arabicPrimaryModelId = 'google/gemma-4-E4B-it';
  models: string[] = [];
  loading = false;
  lastError: string | null = null;
  routeBlocked = false;
  blockingReason = '';
  copySuccess = '';

  constructor(
    private readonly http: HttpClient,
    private readonly healthService: ExperienceHealthService,
  ) {}

  ngOnInit(): void {
    this.healthService.checkRouteReadiness('components').subscribe((readiness) => {
      this.routeBlocked = readiness.blocking;
      const failed = readiness.checks.find((check) => !check.ok);
      this.blockingReason = failed
        ? `Service required: ${failed.name} (${failed.status || 'no status'})`
        : '';
      if (!this.routeBlocked) {
        this.loadModels();
      }
    });
  }

  loadModels(): void {
    this.loading = true;
    this.lastError = null;
    const endpoint = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/models`;
    this.http.get<ModelsResponse>(endpoint).subscribe({
      next: (response) => {
        const rawItems = response?.data ?? [];
        this.models = rawItems
          .map((item) => item.id?.trim())
          .filter((id): id is string => Boolean(id))
          .sort((a, b) => this.sortModels(a, b));
        const hasInvalidContract =
          Array.isArray(rawItems) &&
          rawItems.length > 0 &&
          this.models.length === 0;
        this.lastError = hasInvalidContract
          ? 'Unexpected model catalog response'
          : null;
        this.loading = false;
      },
      error: (error: { message?: string }) => {
        this.models = [];
        this.lastError = error?.message ?? 'Failed to load model catalog';
        this.loading = false;
      },
    });
  }

  isArabicPrimaryModel(modelId: string): boolean {
    return modelId === this.arabicPrimaryModelId;
  }

  get curlSnippet(): string {
    const model = this.models[0] || 'MODEL_ID';
    return `curl ${environment.openAiBaseUrl}v1/chat/completions \\\n  -H "Content-Type: application/json" \\\n  -d '{"model":"${model}","messages":[{"role":"user","content":"Hello"}]}'`;
  }

  get pythonSnippet(): string {
    const model = this.models[0] || 'MODEL_ID';
    return `from openai import OpenAI\nclient = OpenAI(base_url="${environment.openAiBaseUrl}v1")\nresponse = client.chat.completions.create(\n    model="${model}",\n    messages=[{"role": "user", "content": "Hello"}]\n)\nprint(response.choices[0].message.content)`;
  }

  get tsSnippet(): string {
    const model = this.models[0] || 'MODEL_ID';
    return `const resp = await fetch("${environment.openAiBaseUrl}v1/chat/completions", {\n  method: "POST",\n  headers: { "Content-Type": "application/json" },\n  body: JSON.stringify({\n    model: "${model}",\n    messages: [{ role: "user", content: "Hello" }]\n  })\n});\nconst data = await resp.json();\nconsole.log(data.choices[0].message.content);`;
  }

  copyToClipboard(text: string): void {
    navigator.clipboard.writeText(text).then(() => {
      this.copySuccess = 'Copied';
      setTimeout(() => this.copySuccess = '', 2000);
    });
  }

  private sortModels(a: string, b: string): number {
    const aPrimary = this.isArabicPrimaryModel(a);
    const bPrimary = this.isArabicPrimaryModel(b);
    if (aPrimary && !bPrimary) return -1;
    if (!aPrimary && bPrimary) return 1;
    return a.localeCompare(b);
  }
}

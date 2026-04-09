import { HttpClient } from '@angular/common/http';
import { Component, OnInit } from '@angular/core';
import { ExperienceHealthService } from '../../core/experience-health.service';
import { environment } from '../../../environments/environment';

interface McpToolInfo {
  name?: string;
  description?: string;
  inputSchema?: unknown;
}

interface McpListToolsResponse {
  result?: { tools?: McpToolInfo[] };
}

interface McpCallToolResponse {
  result?: unknown;
}

@Component({
  selector: 'ui-angular-mcp-page',
  templateUrl: './mcp-page.component.html',
  styleUrls: ['./mcp-page.component.scss'],
  standalone: false,
})
export class McpPageComponent implements OnInit {
  tools: string[] = [];
  toolMeta: McpToolInfo[] = [];
  selectedTool = '';
  selectedToolMeta: McpToolInfo | null = null;
  toolArgs = '{}';
  argsError = '';
  loading = false;
  invoking = false;
  routeBlocked = false;
  blockingReason = '';
  lastError: string | null = null;
  lastCallResult = '';

  constructor(
    private readonly http: HttpClient,
    private readonly healthService: ExperienceHealthService,
  ) {}

  ngOnInit(): void {
    this.healthService.checkRouteReadiness('mcp').subscribe((readiness) => {
      this.routeBlocked = readiness.blocking;
      const failed = readiness.checks.find((check) => !check.ok);
      this.blockingReason = failed
        ? `Service required: ${failed.name} (${failed.status || 'no status'})`
        : '';
      if (!this.routeBlocked) {
        this.loadTools();
      }
    });
  }

  loadTools(): void {
    this.loading = true;
    this.lastError = null;
    const body = {
      jsonrpc: '2.0',
      id: `list-${Date.now()}`,
      method: 'tools/list',
    };
    this.http.post<McpListToolsResponse>(environment.mcpBaseUrl, body).subscribe({
      next: (response) => {
        const rawTools = response?.result?.tools;
        if (!Array.isArray(rawTools)) {
          this.tools = [];
          this.toolMeta = [];
          this.selectedTool = '';
          this.lastError = 'Invalid MCP tools/list contract';
          this.loading = false;
          return;
        }

        this.toolMeta = rawTools.filter(t => t.name?.trim());
        this.tools = this.toolMeta.map(t => t.name!.trim());
        this.lastError = null;
        if (this.tools.length > 0 && !this.selectedTool) {
          this.selectedTool = this.tools[0];
          this.selectedToolMeta = this.toolMeta[0] || null;
        }
        this.loading = false;
      },
      error: (error: { message?: string }) => {
        this.tools = [];
        this.toolMeta = [];
        this.lastError = error?.message ?? 'Failed to load MCP tools';
        this.loading = false;
      },
    });
  }

  onToolSelect(event: Event): void {
    this.selectedTool = (event as any)?.detail?.selectedOption?.value ?? '';
    this.selectedToolMeta = this.toolMeta.find(t => t.name === this.selectedTool) || null;
    this.toolArgs = '{}';
    this.argsError = '';
    this.lastCallResult = '';
  }

  onArgsChange(event: Event): void {
    this.toolArgs = (event.target as any)?.value ?? '{}';
  }

  invokeSelectedTool(): void {
    if (!this.selectedTool || this.routeBlocked) {
      return;
    }
    // Parse arguments
    let parsedArgs: Record<string, unknown> = {};
    try {
      parsedArgs = JSON.parse(this.toolArgs || '{}');
      this.argsError = '';
    } catch {
      this.argsError = 'Invalid JSON in arguments editor.';
      return;
    }
    this.invoking = true;
    this.lastError = null;
    const body = {
      jsonrpc: '2.0',
      id: `call-${Date.now()}`,
      method: 'tools/call',
      params: {
        name: this.selectedTool,
        arguments: parsedArgs,
      },
    };
    this.http.post<McpCallToolResponse>(environment.mcpBaseUrl, body).subscribe({
      next: (response) => {
        this.lastCallResult = JSON.stringify(response?.result ?? {}, null, 2);
        this.invoking = false;
      },
      error: (error: { message?: string }) => {
        this.lastError = error?.message ?? 'Failed to invoke MCP tool';
        this.invoking = false;
      },
    });
  }
}

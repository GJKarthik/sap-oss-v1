import { HttpClient } from '@angular/common/http';
import { Component, OnInit } from '@angular/core';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';
import { environment } from '../../../environments/environment';

interface McpListToolsResponse {
  result?: { tools?: Array<{ name?: string }> };
}

interface McpCallToolResponse {
  result?: unknown;
}

@Component({
  selector: 'playground-mcp-page',
  templateUrl: './mcp-page.component.html',
  styleUrls: ['./mcp-page.component.scss'],
  standalone: false,
})
export class McpPageComponent implements OnInit {
  tools: string[] = [];
  selectedTool = '';
  loading = false;
  invoking = false;
  routeBlocked = false;
  blockingReason = '';
  lastError: string | null = null;
  lastCallResult = '';

  constructor(
    private readonly http: HttpClient,
    private readonly healthService: LiveDemoHealthService,
  ) {}

  ngOnInit(): void {
    this.healthService.checkRouteReadiness('mcp').subscribe((readiness) => {
      this.routeBlocked = readiness.blocking;
      const failed = readiness.checks.find((check) => !check.ok);
      this.blockingReason = failed
        ? `Live service required: ${failed.name} (${failed.status || 'no status'})`
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
          this.selectedTool = '';
          this.lastError = 'Invalid MCP tools/list contract';
          this.loading = false;
          return;
        }

        this.tools = rawTools
          .map((tool) => tool.name?.trim())
          .filter((name): name is string => Boolean(name));
        this.lastError = null;
        if (this.tools.length > 0 && !this.selectedTool) {
          this.selectedTool = this.tools[0];
        }
        this.loading = false;
      },
      error: (error: { message?: string }) => {
        this.tools = [];
        this.lastError = error?.message ?? 'Failed to load MCP tools';
        this.loading = false;
      },
    });
  }

  invokeSelectedTool(): void {
    if (!this.selectedTool || this.routeBlocked) {
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
        arguments: {},
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

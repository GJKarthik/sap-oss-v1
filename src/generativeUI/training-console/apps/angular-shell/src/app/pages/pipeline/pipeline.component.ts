import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, signal, inject, OnInit, OnDestroy, ViewChild, ElementRef, AfterViewChecked } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ToastService } from '../../services/toast.service';
import { environment } from '../../../environments/environment';

type PipelineStatus = 'idle' | 'running' | 'done' | 'error';

interface PipelineStage {
  num: number;
  name: string;
  tool: string;
  input: string;
  output: string;
  status: PipelineStatus;
}

interface CommandCard {
  title: string;
  command: string;
}

@Component({
  selector: 'app-pipeline',
  standalone: true,
  imports: [CommonModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page-content">
      <div class="page-header">
        <h1 class="page-title">Pipeline</h1>
        <span class="text-muted text-small">7-stage Text-to-SQL data generation</span>
      </div>

      <div class="pipeline-info" style="display: flex; justify-content: space-between; align-items: center;">
        <div>
          <p>The pipeline converts banking Excel schemas into Spider/BIRD-format training pairs.</p>
          <div class="flow-diagram">
            Excel → CSV → Schema Registry → Template Expansion → Validation → Spider/BIRD Output
          </div>
        </div>
        <button class="btn-primary" (click)="startPipeline()" [disabled]="pipelineState() === 'running' || loading()" style="padding: 0.6rem 1.2rem; min-width: 170px;">
          {{ pipelineState() === 'running' ? '⚙️ Processing...' : '🚀 Execute Pipeline' }}
        </button>
      </div>

      @if (pipelineLogs().length > 0) {
        <div class="pipeline-terminal">
          <div class="terminal-header" style="display: flex; justify-content: space-between;">
            <span>Extraction Logs</span>
            <span [class]="pipelineState() === 'error' ? 'text-error' : (pipelineState() === 'completed' ? 'text-success' : '')">
              Status: {{ pipelineState() | uppercase }}
            </span>
          </div>
          <div class="terminal-body" #terminalBody>
            @for (log of pipelineLogs(); track $index) {
              <div>{{ log }}</div>
            }
          </div>
        </div>
      }

      <div class="stages-section">
        <h2 class="section-title">Pipeline Stages</h2>
        <div class="stages-table-wrapper">
          <table class="stages-table">
            <thead>
              <tr>
                <th>#</th>
                <th>Stage</th>
                <th>Tool</th>
                <th>Input</th>
                <th>Output</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              @for (s of stages(); track s.num) {
                <tr>
                  <td class="stage-num">{{ s.num }}</td>
                  <td class="stage-name">{{ s.name }}</td>
                  <td><code>{{ s.tool }}</code></td>
                  <td class="text-muted text-small">{{ s.input }}</td>
                  <td class="text-muted text-small">{{ s.output }}</td>
                  <td>
                    <span class="status-badge {{ statusClass(s.status) }}">{{ s.status }}</span>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      </div>

      <div class="pipeline-commands">
        <h2 class="section-title">Run Commands</h2>
        @for (cmd of commands; track cmd.title) {
          <div class="cmd-card">
            <h3 class="cmd-title">{{ cmd.title }}</h3>
            <pre>{{ cmd.command }}</pre>
          </div>
        }
      </div>
    </div>
  `,
  styles: [`
    .pipeline-info {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1.25rem;
      margin-bottom: 1.5rem;
      font-size: 0.875rem;
      color: var(--sapTextColor, #32363a);

      p { margin: 0 0 0.75rem; }
    }

    .flow-diagram {
      background: var(--sapList_Background, #f5f5f5);
      border-radius: 0.25rem;
      padding: 0.625rem 1rem;
      font-family: 'SFMono-Regular', Consolas, monospace;
      font-size: 0.8125rem;
      color: var(--sapBrandColor, #0854a0);
      overflow-x: auto;
      white-space: nowrap;
    }

    .pipeline-terminal {
      background: #1e1e1e; color: #d4d4d4; border-radius: 0.5rem; margin-bottom: 1.5rem; overflow: hidden;
      font-family: 'SFMono-Regular', Consolas, monospace; font-size: 0.8rem;
      box-shadow: inset 0 2px 10px rgba(0,0,0,0.5);
    }
    .terminal-header { background: #333; padding: 0.5rem 1rem; color: #fff; font-weight: 600; font-size: 0.75rem; }
    .terminal-body { padding: 1rem; max-height: 400px; overflow-y: auto; display: flex; flex-direction: column; gap: 0.2rem; }
    .text-success { color: #4caf50; }
    .text-error { color: #f44336; }

    .btn-primary {
      background: var(--sapButton_Emphasized_Background, #0854a0);
      color: #fff; border: none; border-radius: 0.25rem; cursor: pointer;
      font-weight: 600; font-size: 0.875rem; transition: background 0.2s;
    }
    .btn-primary:hover:not(:disabled) { background: var(--sapButton_Emphasized_Hover_Background, #063d75); }
    .btn-primary:disabled { opacity: 0.6; cursor: not-allowed; }

    .section-title {
      font-size: 1rem;
      font-weight: 600;
      color: var(--sapTextColor, #32363a);
      margin: 0 0 0.75rem;
    }

    .stages-section {
      margin-bottom: 1.5rem;
    }

    .stages-table-wrapper {
      overflow-x: auto;
    }

    .stages-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.8125rem;
      background: var(--sapTile_Background, #fff);
      border-radius: 0.5rem;
      overflow: hidden;
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);

      th {
        padding: 0.625rem 0.75rem;
        background: var(--sapList_HeaderBackground, #f5f5f5);
        text-align: left;
        font-weight: 600;
        color: var(--sapContent_LabelColor, #6a6d70);
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
        text-transform: uppercase;
        font-size: 0.7rem;
        letter-spacing: 0.04em;
      }

      td {
        padding: 0.5rem 0.75rem;
        border-bottom: 1px solid var(--sapList_BorderColor, #e4e4e4);
        vertical-align: middle;
      }

      tr:last-child td { border-bottom: none; }
      tr:hover td { background: var(--sapList_Hover_Background, #f5f5f5); }
    }

    .stage-num {
      color: var(--sapBrandColor, #0854a0);
      font-weight: 700;
      width: 2rem;
      text-align: center;
    }

    .stage-name { font-weight: 500; }

    .pipeline-commands {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
      gap: 1rem;
    }

    .cmd-card {
      background: var(--sapTile_Background, #fff);
      border: 1px solid var(--sapTile_BorderColor, #e4e4e4);
      border-radius: 0.5rem;
      padding: 1rem;
    }

    .cmd-title {
      font-size: 0.8125rem;
      font-weight: 600;
      margin: 0 0 0.5rem;
      color: var(--sapTextColor, #32363a);
    }

    pre {
      margin: 0;
      font-size: 0.8rem;
      background: var(--sapList_Background, #f5f5f5);
      padding: 0.5rem;
      border-radius: 0.25rem;
      overflow-x: auto;
    }
  `],
})
export class PipelineComponent implements OnInit, OnDestroy, AfterViewChecked {
  private readonly http = inject(HttpClient);
  private readonly toast = inject(ToastService);
  private statusInterval: any;

  @ViewChild('terminalBody') private terminalBody?: ElementRef;

  readonly pipelineState = signal<'idle'|'running'|'completed'|'error'>('idle');
  readonly pipelineLogs = signal<string[]>([]);
  readonly loading = signal(false);

  readonly stages = signal<PipelineStage[]>([
    { num: 1, name: 'Preconvert', tool: 'Python (openpyxl)', input: 'data/*.xlsx', output: 'staging/*.csv', status: 'idle' },
    { num: 2, name: 'Build', tool: 'zig build', input: 'Source code', output: 'Pipeline binary', status: 'idle' },
    { num: 3, name: 'Extract Schema', tool: 'Zig', input: 'staging/*.csv', output: 'Schema registry', status: 'idle' },
    { num: 4, name: 'Parse Templates', tool: 'Zig', input: 'data/prompt_templates.csv', output: 'Parameterised templates', status: 'idle' },
    { num: 5, name: 'Expand', tool: 'Zig', input: 'Templates + Schema', output: 'Text-SQL pairs', status: 'idle' },
    { num: 6, name: 'Validate', tool: 'Mangle', input: 'Pairs + Rules', output: 'Validated pairs', status: 'idle' },
    { num: 7, name: 'Format', tool: 'Zig', input: 'Validated pairs', output: 'Spider/BIRD JSONL', status: 'idle' },
  ]);

  readonly commands: CommandCard[] = [
    { title: 'Full pipeline (all 7 stages)', command: 'cd pipeline && make all' },
    { title: 'Step 1 — Preconvert Excel → CSV', command: 'cd pipeline && make preconvert' },
    { title: 'Step 2 — Build Zig binary', command: 'cd pipeline/zig && zig build' },
    { title: 'Run Zig pipeline tests', command: 'cd pipeline/zig && zig build test' },
  ];

  ngOnInit() {
    this.pollStatus();
    this.statusInterval = setInterval(() => this.pollStatus(), 2000);
  }

  ngOnDestroy() {
    if (this.statusInterval) clearInterval(this.statusInterval);
  }

  ngAfterViewChecked() {
    this.scrollToBottom();
  }

  private scrollToBottom(): void {
    try {
      if (this.terminalBody) {
        this.terminalBody.nativeElement.scrollTop = this.terminalBody.nativeElement.scrollHeight;
      }
    } catch(err) { }
  }

  pollStatus() {
    this.http.get<{state: 'idle'|'running'|'completed'|'error', logs: string[]}>(`${environment.apiBaseUrl}/pipeline/status`).subscribe({
      next: (res) => {
        this.pipelineState.set(res.state);
        this.pipelineLogs.set(res.logs);
      }
    });
  }

  startPipeline() {
    this.loading.set(true);
    this.http.post(`${environment.apiBaseUrl}/pipeline/start`, {}).subscribe({
      next: () => {
        this.toast.success('Pipeline extraction started', 'Started');
        this.pipelineState.set('running');
        this.loading.set(false);
      },
      error: (e: any) => {
        const detail = e?.error?.detail || 'Failed to start pipeline';
        this.toast.error(detail, 'Error');
        this.loading.set(false);
      }
    });
  }

  statusClass(status: PipelineStatus): string {
    const classMap: Record<PipelineStatus, string> = {
      idle: 'status-pending',
      running: 'status-running',
      done: 'status-success',
      error: 'status-error',
    };
    return classMap[status];
  }
}
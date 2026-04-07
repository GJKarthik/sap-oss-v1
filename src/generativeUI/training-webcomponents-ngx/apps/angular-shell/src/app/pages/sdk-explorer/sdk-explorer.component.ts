import { Component, OnInit, CUSTOM_ELEMENTS_SCHEMA, signal, inject, computed, ChangeDetectionStrategy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { environment } from '../../../environments/environment';
import { I18nService } from '../../services/i18n.service';

interface SdkSample {
  sdk: string;
  filename: string;
  path: string;
  type: string;
}

@Component({
  selector: 'app-sdk-explorer',
  standalone: true,
  imports: [CommonModule, Ui5WebcomponentsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <ui5-page background-design="Solid" class="dev-studio-aura">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Developer SDK Center</ui5-title>
        <div slot="endContent" style="display: flex; gap: 0.5rem; align-items: center;">
          <ui5-tag design="Information">SAP AI SDK v2.0</ui5-tag>
        </div>
      </ui5-bar>

      <div class="studio-layout" role="main">
        <!-- Sidebar: SDK Samples -->
        <aside class="glass-card side-nav">
          <ui5-bar design="Header">
            <ui5-title slot="startContent" level="H5">Integrated SDKs</ui5-title>
          </ui5-bar>
          <ui5-list separators="None" (item-click)="onSampleSelect($event)">
            @for (sdk of sdks(); track sdk) {
              <ui5-li-group-header>{{ sdk }}</ui5-li-group-header>
              @for (s of samplesBySdk(sdk); track s.path) {
                <ui5-li [attr.data-path]="s.path" icon="source-code" 
                        [selected]="selectedPath() === s.path">{{ s.filename }}</ui5-li>
              }
            }
          </ui5-list>
        </aside>

        <!-- Main Workspace -->
        <main class="workspace-area">
          @if (selectedPath()) {
            <div class="editor-section fadeIn">
              <div class="glass-card editor-card">
                <ui5-bar design="Header">
                  <ui5-title slot="startContent" level="H5">{{ selectedFilename() }}</ui5-title>
                  <ui5-button slot="endContent" design="Emphasized" icon="play" (click)="runCode()" [disabled]="running()">
                    {{ running() ? 'Executing...' : 'Run Example' }}
                  </ui5-button>
                </ui5-bar>
                <div class="code-viewport">
                  <pre><code class="language-typescript">{{ codeContent() }}</code></pre>
                </div>
              </div>

              <!-- Cinematic Terminal -->
              <div class="terminal-container" [class.terminal-container--visible]="showTerminal()">
                <div class="terminal-header">
                  <span>Runtime Logs</span>
                  <ui5-button design="Transparent" icon="decline" (click)="showTerminal.set(false)"></ui5-button>
                </div>
                <div class="terminal-body" #terminalBody>
                  @for (log of logs(); track $index) {
                    <div class="log-line">
                      <span class="log-ts">[{{ log.ts | date:'HH:mm:ss' }}]</span>
                      <span class="log-msg">{{ log.msg }}</span>
                    </div>
                  }
                  @if (running()) {
                    <div class="cursor-blink">█</div>
                  }
                </div>
              </div>
            </div>
          } @else {
            <div class="empty-workspace fadeIn">
              <ui5-icon name="developer-settings" class="huge-icon"></ui5-icon>
              <ui5-title level="H2">Select an SDK Example</ui5-title>
              <p class="text-muted">Explore real-world integration patterns for SAP AI Core, CAP, and LangChain</p>
            </div>
          }
        </main>
      </div>
    </ui5-page>
  `,
  styles: [`
    .dev-studio-aura {
      background: radial-gradient(circle at 0% 100%, rgba(8, 84, 160, 0.08) 0%, transparent 40%),
                  var(--sapBackgroundColor);
    }
    .studio-layout { display: grid; grid-template-columns: 300px 1fr; gap: 1.5rem; padding: 1.5rem; height: calc(100vh - 100px); overflow: hidden; }
    
    .glass-card {
      background: rgba(255, 255, 255, 0.72);
      backdrop-filter: blur(12px);
      border: 1px solid rgba(255, 255, 255, 0.4);
      border-radius: 1rem;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.04);
    }

    .side-nav { height: 100%; overflow-y: auto; }
    .workspace-area { height: 100%; display: flex; flex-direction: column; overflow: hidden; }
    
    .editor-section { flex: 1; display: flex; flex-direction: column; gap: 1.5rem; overflow: hidden; position: relative; }
    .editor-card { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
    .code-viewport { flex: 1; overflow: auto; background: #1e1e1e; padding: 1.5rem; border-radius: 0 0 1rem 1rem; }
    code { color: #d4d4d4; font-family: 'Fira Code', monospace; font-size: 0.875rem; line-height: 1.6; }

    .terminal-container { 
      position: absolute; bottom: -100%; left: 0; right: 0; height: 300px;
      background: rgba(13, 17, 23, 0.95); backdrop-filter: blur(20px);
      border-top: 1px solid rgba(255,255,255,0.1); transition: bottom 0.4s cubic-bezier(0.4, 0, 0.2, 1);
      display: flex; flex-direction: column; z-index: 10;
    }
    .terminal-container--visible { bottom: 0; }
    .terminal-header { padding: 0.5rem 1.5rem; display: flex; justify-content: space-between; align-items: center; color: #fff; font-size: 0.75rem; font-weight: bold; text-transform: uppercase; background: rgba(255,255,255,0.05); }
    .terminal-body { flex: 1; padding: 1rem 1.5rem; overflow-y: auto; font-family: monospace; font-size: 0.8125rem; color: #7ee787; }
    .log-ts { color: #8b949e; margin-right: 0.75rem; }
    
    .empty-workspace { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; gap: 1rem; }
    .huge-icon { font-size: 6rem; color: var(--sapBrandColor); opacity: 0.15; filter: drop-shadow(0 0 20px var(--sapBrandColor)); }

    .cursor-blink { display: inline-block; width: 8px; height: 15px; background: currentColor; animation: blink 1s step-end infinite; vertical-align: middle; }
    @keyframes blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }
    .fadeIn { animation: fadeIn 0.5s ease-out; }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
  `],
})
export class SdkExplorerComponent implements OnInit {
  private readonly http = inject(HttpClient);
  readonly i18n = inject(I18nService);

  readonly samples = signal<SdkSample[]>([]);
  readonly sdks = computed(() => [...new Set(this.samples().map(s => s.sdk))]);
  
  readonly selectedPath = signal<string | null>(null);
  readonly selectedFilename = computed(() => this.samples().find(s => s.path === this.selectedPath())?.filename ?? '');
  readonly codeContent = signal<string>('');
  readonly running = signal(false);
  readonly showTerminal = signal(false);
  readonly logs = signal<{ts: Date, msg: string}[]>([]);

  ngOnInit() {
    this.http.get<SdkSample[]>(`${environment.apiBaseUrl}/sdk/samples`).subscribe(res => this.samples.set(res));
  }

  samplesBySdk(sdk: string) {
    return this.samples().filter(s => s.sdk === sdk);
  }

  onSampleSelect(event: any) {
    const path = event.detail.item.getAttribute('data-path');
    if (!path) return;
    this.selectedPath.set(path);
    this.http.get<{content: string}>(`${environment.apiBaseUrl}/sdk/samples/content?path=${path}`).subscribe(res => {
      this.codeContent.set(res.content);
    });
  }

  runCode() {
    this.running.set(true);
    this.showTerminal.set(true);
    this.logs.set([{ ts: new Date(), msg: 'Initializing runtime environment...' }]);
    
    // Simulate cinematic execution
    const simulatedLogs = [
      'Loading SAP AI SDK modules...',
      'Injecting authentication context (SAP AI Core)',
      'Establishing connection to vLLM Inference Plane',
      'Payload Serialized: { model: "meta-llama/Llama-3.1-8B", max_tokens: 1024 }',
      'Streaming response from engine...',
      'Execution Complete. Process exited with code 0.'
    ];

    let i = 0;
    const interval = setInterval(() => {
      if (i < simulatedLogs.length) {
        this.logs.update(l => [...l, { ts: new Date(), msg: simulatedLogs[i++] }]);
      } else {
        clearInterval(interval);
        this.running.set(false);
      }
    }, 800);
  }
}

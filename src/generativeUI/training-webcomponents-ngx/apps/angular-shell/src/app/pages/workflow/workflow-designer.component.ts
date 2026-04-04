import {
  Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy,
  signal, computed, inject, OnInit, OnDestroy, ElementRef, ViewChild,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import { WorkflowService } from './workflow.service';
import {
  PetriNet, Place, Transition, Arc, Token,
  DesignerMode, DesignerTool, TokenType, TOKEN_COLOURS,
  createPlace, createTransition, createArc, createToken, cloneNet, createId,
} from './workflow.models';
import { WORKFLOW_TEMPLATES, WorkflowTemplate } from './workflow-templates';

@Component({
  selector: 'app-workflow-designer',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  providers: [WorkflowService],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './workflow-designer.component.html',
  styleUrls: ['./workflow-designer.component.scss'],
})
export class WorkflowDesignerComponent implements OnInit, OnDestroy {
  readonly i18n = inject(I18nService);
  readonly toast = inject(ToastService);
  readonly wf = inject(WorkflowService);
  readonly templates = WORKFLOW_TEMPLATES;

  /* view state */
  readonly zoom = signal(1);
  readonly panX = signal(0);
  readonly panY = signal(0);
  readonly showTemplates = signal(false);
  readonly showImport = signal(false);
  readonly importText = signal('');
  readonly showProperties = signal(false);
  private isPanning = false;
  private panStartX = 0;
  private panStartY = 0;
  private dragId: string | null = null;
  private dragType: 'place' | 'transition' | null = null;
  private dragOffsetX = 0;
  private dragOffsetY = 0;

  /* computed */
  readonly net = this.wf.net;
  readonly mode = this.wf.mode;
  readonly exec = this.wf.exec;
  readonly designer = this.wf.designer;

  ngOnInit(): void {
    this.wf.loadTemplate('tpl-train');
  }

  ngOnDestroy(): void {}

  /* --- Toolbar --- */
  setTool(t: DesignerTool): void { this.wf.setTool(t); }
  setMode(m: DesignerMode): void {
    this.wf.mode.set(m);
    if (m === 'execute') this.wf.setTool('select');
  }

  /* --- Canvas interactions --- */
  onCanvasClick(event: MouseEvent): void {
    const tool = this.designer().tool;
    if (this.mode() !== 'design') return;
    const pt = this.svgPoint(event);
    if (tool === 'place') {
      this.wf.pushUndo();
      const n = cloneNet(this.net());
      n.places.push(createPlace(pt.x, pt.y, `P${n.places.length + 1}`));
      this.wf.net.set(n);
    } else if (tool === 'transition') {
      this.wf.pushUndo();
      const n = cloneNet(this.net());
      n.transitions.push(createTransition(pt.x, pt.y, `T${n.transitions.length + 1}`));
      this.wf.net.set(n);
    } else if (tool === 'select') {
      this.wf.selectElement(null, null);
      this.showProperties.set(false);
    }
  }

  onPlaceClick(p: Place, event: MouseEvent): void {
    event.stopPropagation();
    const tool = this.designer().tool;
    if (tool === 'delete' && this.mode() === 'design') {
      this.wf.pushUndo();
      const n = cloneNet(this.net());
      n.places = n.places.filter(x => x.id !== p.id);
      n.arcs = n.arcs.filter(a => a.sourceId !== p.id && a.targetId !== p.id);
      this.wf.net.set(n);
    } else if (tool === 'arc' && this.mode() === 'design') {
      this.handleArcClick(p.id, 'place');
    } else {
      this.wf.selectElement(p.id, 'place');
      this.showProperties.set(true);
    }
  }

  onTransitionClick(t: Transition, event: MouseEvent): void {
    event.stopPropagation();
    const tool = this.designer().tool;
    if (tool === 'delete' && this.mode() === 'design') {
      this.wf.pushUndo();
      const n = cloneNet(this.net());
      n.transitions = n.transitions.filter(x => x.id !== t.id);
      n.arcs = n.arcs.filter(a => a.sourceId !== t.id && a.targetId !== t.id);
      this.wf.net.set(n);
    } else if (tool === 'arc' && this.mode() === 'design') {
      this.handleArcClick(t.id, 'transition');
    } else if (this.mode() === 'execute' && t.state === 'enabled') {
      this.wf.fireTransition(t.id);
    } else {
      this.wf.selectElement(t.id, 'transition');
      this.showProperties.set(true);
    }
  }

  onArcClick(a: Arc, event: MouseEvent): void {
    event.stopPropagation();
    if (this.designer().tool === 'delete' && this.mode() === 'design') {
      this.wf.pushUndo();
      const n = cloneNet(this.net());
      n.arcs = n.arcs.filter(x => x.id !== a.id);
      this.wf.net.set(n);
    } else {
      this.wf.selectElement(a.id, 'arc');
      this.showProperties.set(true);
    }
  }

  private handleArcClick(id: string, type: 'place' | 'transition'): void {
    const d = this.designer();
    if (!d.arcSourceId) {
      this.wf.designer.update(s => ({ ...s, arcSourceId: id, arcSourceType: type }));
    } else if (d.arcSourceType !== type) {
      this.wf.pushUndo();
      const n = cloneNet(this.net());
      n.arcs.push(createArc(d.arcSourceId, id, d.arcSourceType!));
      this.wf.net.set(n);
      this.wf.designer.update(s => ({ ...s, arcSourceId: null, arcSourceType: null }));
    } else {
      this.toast.info(this.i18n.t('workflow.arcSameType'));
      this.wf.designer.update(s => ({ ...s, arcSourceId: null, arcSourceType: null }));
    }
  }

  /* --- Drag --- */
  onDragStart(id: string, type: 'place' | 'transition', event: MouseEvent): void {
    if (this.mode() !== 'design' || this.designer().tool !== 'select') return;
    event.preventDefault();
    this.dragId = id; this.dragType = type;
    const el = type === 'place' ? this.net().places.find(p => p.id === id) : this.net().transitions.find(t => t.id === id);
    if (el) { this.dragOffsetX = event.clientX - el.position.x * this.zoom() - this.panX(); this.dragOffsetY = event.clientY - el.position.y * this.zoom() - this.panY(); }
  }

  onMouseMove(event: MouseEvent): void {
    if (this.dragId && this.dragType) {
      const x = (event.clientX - this.dragOffsetX - this.panX()) / this.zoom();
      const y = (event.clientY - this.dragOffsetY - this.panY()) / this.zoom();
      const n = cloneNet(this.net());
      const el = this.dragType === 'place' ? n.places.find(p => p.id === this.dragId) : n.transitions.find(t => t.id === this.dragId);
      if (el) { el.position = { x, y }; this.wf.net.set(n); }
    } else if (this.isPanning) {
      this.panX.set(event.clientX - this.panStartX);
      this.panY.set(event.clientY - this.panStartY);
    }
  }
  onMouseUp(): void { this.dragId = null; this.dragType = null; this.isPanning = false; }
  onPanStart(event: MouseEvent): void {
    if (this.dragId) return;
    if (event.button === 1 || event.shiftKey) { this.isPanning = true; this.panStartX = event.clientX - this.panX(); this.panStartY = event.clientY - this.panY(); }
  }
  zoomIn(): void { this.zoom.update(z => Math.min(z + 0.1, 3)); }
  zoomOut(): void { this.zoom.update(z => Math.max(z - 0.1, 0.3)); }
  resetView(): void { this.zoom.set(1); this.panX.set(0); this.panY.set(0); }

  /* --- Arc geometry --- */
  arcPath(a: Arc): string {
    const n = this.net();
    let sx: number, sy: number, tx: number, ty: number;
    if (a.sourceType === 'place') {
      const p = n.places.find(x => x.id === a.sourceId);
      const t = n.transitions.find(x => x.id === a.targetId);
      if (!p || !t) return '';
      sx = p.position.x; sy = p.position.y; tx = t.position.x; ty = t.position.y;
    } else {
      const t = n.transitions.find(x => x.id === a.sourceId);
      const p = n.places.find(x => x.id === a.targetId);
      if (!t || !p) return '';
      sx = t.position.x; sy = t.position.y; tx = p.position.x; ty = p.position.y;
    }
    return `M${sx},${sy} L${tx},${ty}`;
  }

  arcMidpoint(a: Arc): { x: number; y: number } {
    const n = this.net();
    const src = a.sourceType === 'place' ? n.places.find(x => x.id === a.sourceId) : n.transitions.find(x => x.id === a.sourceId);
    const tgt = a.sourceType === 'place' ? n.transitions.find(x => x.id === a.targetId) : n.places.find(x => x.id === a.targetId);
    if (!src || !tgt) return { x: 0, y: 0 };
    return { x: (src.position.x + tgt.position.x) / 2, y: (src.position.y + tgt.position.y) / 2 };
  }

  /* --- Properties panel helpers --- */
  selectedPlace(): Place | undefined { return this.net().places.find(p => p.id === this.designer().selectedId); }
  selectedTransition(): Transition | undefined { return this.net().transitions.find(t => t.id === this.designer().selectedId); }
  selectedArc(): Arc | undefined { return this.net().arcs.find(a => a.id === this.designer().selectedId); }

  updatePlace(field: string, value: string | number): void {
    const n = cloneNet(this.net());
    const p = n.places.find(x => x.id === this.designer().selectedId);
    if (!p) return;
    if (field === 'name') p.name = value as string;
    if (field === 'tokenType') p.tokenType = value as TokenType;
    if (field === 'capacity') p.capacity = +value || Infinity;
    this.wf.net.set(n);
  }
  updateTransition(field: string, value: string | number): void {
    const n = cloneNet(this.net());
    const t = n.transitions.find(x => x.id === this.designer().selectedId);
    if (!t) return;
    if (field === 'name') t.name = value as string;
    if (field === 'guard') t.guard = value as string;
    if (field === 'priority') t.priority = +value || 1;
    this.wf.net.set(n);
  }
  updateArc(field: string, value: string | number | boolean): void {
    const n = cloneNet(this.net());
    const a = n.arcs.find(x => x.id === this.designer().selectedId);
    if (!a) return;
    if (field === 'expression') a.expression = value as string;
    if (field === 'weight') a.weight = +value || 1;
    if (field === 'inhibitor') a.inhibitor = !!value;
    this.wf.net.set(n);
  }

  addTokenToPlace(): void {
    const n = cloneNet(this.net());
    const p = n.places.find(x => x.id === this.designer().selectedId);
    if (!p || p.tokens.length >= p.capacity) return;
    p.tokens.push(createToken(p.tokenType));
    this.wf.net.set(n);
  }

  /* --- Token positioning inside place circle --- */
  tokenPositions(tokens: Token[]): { x: number; y: number }[] {
    const r = 20;
    if (tokens.length <= 1) return [{ x: 0, y: 0 }];
    return tokens.map((_, i) => {
      const angle = (2 * Math.PI * i) / tokens.length - Math.PI / 2;
      return { x: Math.cos(angle) * r * 0.5, y: Math.sin(angle) * r * 0.5 };
    });
  }

  /* --- Export / Import --- */
  exportNet(): void {
    const json = this.wf.exportJson();
    const blob = new Blob([json], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = `${this.net().name || 'petri-net'}.json`; a.click();
    URL.revokeObjectURL(url);
    this.toast.info(this.i18n.t('workflow.exported'));
  }

  importNet(): void {
    if (this.wf.importJson(this.importText())) {
      this.showImport.set(false); this.importText.set('');
      this.toast.info(this.i18n.t('workflow.imported'));
    } else {
      this.toast.error(this.i18n.t('workflow.importError'));
    }
  }

  transitionColor(state: string): string {
    switch (state) {
      case 'enabled': return '#4caf50';
      case 'firing': return '#ffeb3b';
      case 'error': return '#f44336';
      default: return '#9e9e9e';
    }
  }

  transitionName(id: string): string {
    return this.net().transitions.find(t => t.id === id)?.name ?? id;
  }

  private svgPoint(event: MouseEvent): { x: number; y: number } {
    return {
      x: (event.offsetX - this.panX()) / this.zoom(),
      y: (event.offsetY - this.panY()) / this.zoom(),
    };
  }
}

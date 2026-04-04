/** Petri Net data models for the Workflow Designer */

export interface Position { x: number; y: number; }

export type TokenType = 'data' | 'control' | 'resource' | 'error';

export interface Token {
  id: string;
  type: TokenType;
  data?: Record<string, unknown>;
  colour: string;
}

export interface Place {
  id: string;
  name: string;
  position: Position;
  tokenType: TokenType;
  tokens: Token[];
  capacity: number;
}

export interface Transition {
  id: string;
  name: string;
  position: Position;
  guard?: string;
  priority: number;
  state: 'disabled' | 'enabled' | 'firing' | 'error';
}

export interface Arc {
  id: string;
  sourceId: string;
  targetId: string;
  sourceType: 'place' | 'transition';
  expression: string;
  weight: number;
  inhibitor: boolean;
}

export interface PetriNet {
  id: string;
  name: string;
  places: Place[];
  transitions: Transition[];
  arcs: Arc[];
}

export interface FiringEvent {
  transitionId: string;
  timestamp: number;
  consumedTokens: { placeId: string; tokenIds: string[] }[];
  producedTokens: { placeId: string; tokens: Token[] }[];
}

export interface ExecutionState {
  running: boolean;
  speed: 'slow' | 'normal' | 'fast';
  history: FiringEvent[];
  deadlock: boolean;
  stepCount: number;
}

export type DesignerTool = 'select' | 'place' | 'transition' | 'arc' | 'delete';

export interface DesignerState {
  tool: DesignerTool;
  selectedId: string | null;
  selectedType: 'place' | 'transition' | 'arc' | null;
  undoStack: PetriNet[];
  redoStack: PetriNet[];
  arcSourceId: string | null;
  arcSourceType: 'place' | 'transition' | null;
}

export type DesignerMode = 'design' | 'execute';

export const TOKEN_COLOURS: Record<TokenType, string> = {
  data: '#2196f3',
  control: '#4caf50',
  resource: '#ff9800',
  error: '#f44336',
};

export function createId(): string {
  return Math.random().toString(36).substring(2, 10);
}

export function createPlace(x: number, y: number, name: string, tokenType: TokenType = 'data'): Place {
  return { id: createId(), name, position: { x, y }, tokenType, tokens: [], capacity: Infinity };
}

export function createTransition(x: number, y: number, name: string): Transition {
  return { id: createId(), name, position: { x, y }, priority: 1, state: 'disabled' };
}

export function createArc(sourceId: string, targetId: string, sourceType: 'place' | 'transition'): Arc {
  return { id: createId(), sourceId, targetId, sourceType, expression: '', weight: 1, inhibitor: false };
}

export function createToken(type: TokenType, data?: Record<string, unknown>): Token {
  return { id: createId(), type, data, colour: TOKEN_COLOURS[type] };
}

export function cloneNet(net: PetriNet): PetriNet {
  return JSON.parse(JSON.stringify(net));
}

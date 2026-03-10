// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE

import { DynamicRenderer, RenderedComponent, A2UiSchema } from './dynamic-renderer.service';
import { ComponentRegistry } from '../registry/component-registry';
import { SchemaValidator } from '../validation/schema-validator';

// ---------------------------------------------------------------------------
// Minimal stubs
// ---------------------------------------------------------------------------

function makeRegistry(allowed = true): ComponentRegistry {
  return {
    isAllowed: jest.fn().mockReturnValue(allowed),
    get: jest.fn().mockReturnValue(undefined),
    allow: jest.fn(),
    deny: jest.fn(),
    getMetadata: jest.fn().mockReturnValue(undefined),
  } as unknown as ComponentRegistry;
}

function makeValidator(valid = true): SchemaValidator {
  return {
    validate: jest.fn().mockReturnValue({
      valid,
      errors: valid ? [] : [{ type: 'INVALID_SCHEMA', message: 'denied', path: '/', severity: 'error' }],
    }),
  } as unknown as SchemaValidator;
}

const mockElement = () => {
  const el: Record<string, unknown> = {};
  return {
    setAttribute: jest.fn((k: string, v: string) => { el[k] = v; }),
    appendChild: jest.fn(),
    remove: jest.fn(),
    style: {},
  } as unknown as HTMLElement;
};

function makeRendererFactory(el: HTMLElement) {
  return {
    createRenderer: jest.fn().mockReturnValue({
      createElement: jest.fn().mockReturnValue(el),
      createText: jest.fn().mockReturnValue(document.createTextNode('')),
      appendChild: jest.fn(),
      removeChild: jest.fn(),
      setAttribute: jest.fn(),
      setProperty: jest.fn(),
      setStyle: jest.fn(),
      addClass: jest.fn(),
      listen: jest.fn().mockReturnValue(() => {}),
    }),
  };
}

function makeDynamicRenderer(
  registry: ComponentRegistry,
  validator: SchemaValidator,
  el: HTMLElement
): DynamicRenderer {
  const factory = makeRendererFactory(el);
  return new DynamicRenderer(registry, validator, factory as never, null);
}

const simpleSchema = (): A2UiSchema => ({
  component: 'ui5-button',
  props: { text: 'Click me' },
});

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('DynamicRenderer', () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement('div');
    document.body.appendChild(container);
  });

  afterEach(() => {
    container.remove();
  });

  it('returns null when SchemaValidator rejects the schema', () => {
    const registry = makeRegistry(true);
    const validator = makeValidator(false);
    const el = mockElement();
    const renderer = makeDynamicRenderer(registry, validator, el);

    const result = renderer.render(simpleSchema(), container);

    expect(result).toBeNull();
    expect(validator.validate).toHaveBeenCalledWith(simpleSchema());
  });

  it('returns null when component is not in the registry allowlist', () => {
    const registry = makeRegistry(false);
    const validator = makeValidator(true);
    const el = mockElement();
    const renderer = makeDynamicRenderer(registry, validator, el);

    const result = renderer.render(simpleSchema(), container);

    expect(result).toBeNull();
    expect(registry.isAllowed).toHaveBeenCalledWith('ui5-button');
  });

  it('returns a RenderedComponent for an allowed, valid schema', () => {
    const registry = makeRegistry(true);
    const validator = makeValidator(true);
    const el = mockElement();
    const renderer = makeDynamicRenderer(registry, validator, el);

    const result = renderer.render(simpleSchema(), container);

    expect(result).not.toBeNull();
    expect(result?.schema.component).toBe('ui5-button');
  });

  it('emits the rendered instance on componentRendered$', () => {
    const registry = makeRegistry(true);
    const validator = makeValidator(true);
    const el = mockElement();
    const renderer = makeDynamicRenderer(registry, validator, el);
    const emitted: RenderedComponent[] = [];
    renderer.componentRendered$.subscribe((v: RenderedComponent) => emitted.push(v));

    renderer.render(simpleSchema(), container);

    expect(emitted).toHaveLength(1);
  });

  it('remove() emits on componentDestroyed$', () => {
    const registry = makeRegistry(true);
    const validator = makeValidator(true);
    const el = mockElement();
    const r = makeDynamicRenderer(registry, validator, el);
    const destroyed: string[] = [];
    r.componentDestroyed$.subscribe((id: string) => destroyed.push(id));

    const rendered = r.render(simpleSchema(), container);
    expect(rendered).not.toBeNull();

    r.remove(rendered!.id);

    expect(destroyed).toContain(rendered!.id);
  });

  it('clear() removes all tracked instances', () => {
    const registry = makeRegistry(true);
    const validator = makeValidator(true);
    const el = mockElement();
    const r = makeDynamicRenderer(registry, validator, el);

    r.render(simpleSchema(), container);
    r.render({ ...simpleSchema(), component: 'ui5-button' }, container);
    r.clear();

    expect(r.instances$.getValue().size).toBe(0);
  });

  it('applyStyles() blocks dangerous CSS values (javascript:)', () => {
    const registry = makeRegistry(true);
    const validator = makeValidator(true);
    const fakeRenderer = {
      createElement: jest.fn().mockReturnValue(document.createElement('ui5-button')),
      createText: jest.fn(),
      appendChild: jest.fn(),
      removeChild: jest.fn(),
      setAttribute: jest.fn(),
      setProperty: jest.fn(),
      setStyle: jest.fn(),
      addClass: jest.fn(),
      listen: jest.fn().mockReturnValue(() => {}),
    };
    const factory = { createRenderer: jest.fn().mockReturnValue(fakeRenderer) };
    const r = new DynamicRenderer(registry, validator, factory as never, null);
    const warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});

    r.render(
      { component: 'ui5-button', style: { backgroundImage: 'url(javascript:alert(1))' } },
      container
    );

    expect(fakeRenderer.setStyle).not.toHaveBeenCalledWith(
      expect.anything(), 'backgroundImage', expect.stringContaining('javascript')
    );
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('Blocked dangerous CSS'));
    warnSpy.mockRestore();
  });

  it('resolvePath() returns undefined for __proto__ path segments (B3)', () => {
    const registry = makeRegistry(true);
    const validator = makeValidator(false); // prevent actual render
    const el = mockElement();
    const r = makeDynamicRenderer(registry, validator, el);
    const warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});

    // Access private method via cast
    const result = (r as unknown as { resolvePath: (o: unknown, p: string) => unknown })
      .resolvePath({ a: 1 }, '__proto__.polluted');

    expect(result).toBeUndefined();
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('Blocked forbidden path segment'));
    warnSpy.mockRestore();
  });
});

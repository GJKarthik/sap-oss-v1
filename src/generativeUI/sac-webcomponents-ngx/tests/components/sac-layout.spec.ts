import { describe, expect, it } from 'vitest';

import {
  SacFlexContainerComponent,
  SacGridContainerComponent,
  SacGridItemComponent,
} from '../../libs/sac-ai-widget/components/sac-layout.component';

describe('SacFlexContainerComponent', () => {
  function createFlex(): SacFlexContainerComponent {
    return new SacFlexContainerComponent();
  }

  it('maps justify start to flex-start', () => {
    const flex = createFlex();
    expect(flex.justifyMap['start']).toBe('flex-start');
  });

  it('maps justify space-between to space-between', () => {
    const flex = createFlex();
    expect(flex.justifyMap['space-between']).toBe('space-between');
  });

  it('maps justify space-around to space-around', () => {
    const flex = createFlex();
    expect(flex.justifyMap['space-around']).toBe('space-around');
  });

  it('maps align stretch to stretch', () => {
    const flex = createFlex();
    expect(flex.alignMap['stretch']).toBe('stretch');
  });

  it('maps align start to flex-start', () => {
    const flex = createFlex();
    expect(flex.alignMap['start']).toBe('flex-start');
  });

  it('maps align end to flex-end', () => {
    const flex = createFlex();
    expect(flex.alignMap['end']).toBe('flex-end');
  });

  it('defaults direction to row', () => {
    const flex = createFlex();
    expect(flex.direction).toBe('row');
  });

  it('defaults justify to start', () => {
    const flex = createFlex();
    expect(flex.justify).toBe('start');
  });

  it('defaults align to stretch', () => {
    const flex = createFlex();
    expect(flex.align).toBe('stretch');
  });

  it('defaults gap to 2 (16px)', () => {
    const flex = createFlex();
    expect(flex.gap).toBe(2);
  });

  it('defaults wrap to false', () => {
    const flex = createFlex();
    expect(flex.wrap).toBe(false);
  });
});

describe('SacGridContainerComponent', () => {
  function createGrid(): SacGridContainerComponent {
    return new SacGridContainerComponent();
  }

  it('generates repeat columns from count', () => {
    const grid = createGrid();
    grid.columns = 3;
    expect(grid.gridColumns).toBe('repeat(3, 1fr)');
  });

  it('generates auto-fit columns from minColumnWidth', () => {
    const grid = createGrid();
    grid.minColumnWidth = 280;
    expect(grid.gridColumns).toBe('repeat(auto-fit, minmax(280px, 1fr))');
  });

  it('prefers minColumnWidth over columns when both set', () => {
    const grid = createGrid();
    grid.columns = 4;
    grid.minColumnWidth = 200;
    expect(grid.gridColumns).toBe('repeat(auto-fit, minmax(200px, 1fr))');
  });

  it('returns undefined gridRows when rows is not set', () => {
    const grid = createGrid();
    expect(grid.gridRows).toBeUndefined();
  });

  it('generates repeat rows from count', () => {
    const grid = createGrid();
    grid.rows = 3;
    expect(grid.gridRows).toBe('repeat(3, auto)');
  });

  it('defaults columns to 12', () => {
    const grid = createGrid();
    expect(grid.columns).toBe(12);
    expect(grid.gridColumns).toBe('repeat(12, 1fr)');
  });

  it('defaults gap to 2', () => {
    const grid = createGrid();
    expect(grid.gap).toBe(2);
  });

  it('defaults responsive to true', () => {
    const grid = createGrid();
    expect(grid.responsive).toBe(true);
  });
});

describe('SacGridItemComponent', () => {
  function createItem(): SacGridItemComponent {
    return new SacGridItemComponent();
  }

  it('generates grid-column span from colSpan', () => {
    const item = createItem();
    item.colSpan = 4;
    expect(item.gridColumnStyle).toBe('span 4');
  });

  it('generates grid-row span from rowSpan', () => {
    const item = createItem();
    item.rowSpan = 2;
    expect(item.gridRowStyle).toBe('span 2');
  });

  it('returns undefined when no colSpan set', () => {
    const item = createItem();
    expect(item.gridColumnStyle).toBeUndefined();
  });

  it('returns undefined when no rowSpan set', () => {
    const item = createItem();
    expect(item.gridRowStyle).toBeUndefined();
  });
});

import { describe, expect, it } from 'vitest';
import { SacVariableService } from '../libs/sac-datasource/src/lib/services/sac-variable.service';

describe('SacVariableService', () => {
  it('starts with no variables', () => {
    const service = new SacVariableService();
    expect(service.getVariable('v1')).toBeUndefined();
  });

  it('sets and retrieves a variable', () => {
    const service = new SacVariableService();
    service.setVariable('fiscal_year', '2024', 'single');
    const v = service.getVariable('fiscal_year');
    expect(v).toEqual({ variableId: 'fiscal_year', value: '2024', type: 'single' });
  });

  it('defaults type to single', () => {
    const service = new SacVariableService();
    service.setVariable('v1', 'val');
    expect(service.getVariable('v1')?.type).toBe('single');
  });

  it('removes a variable', () => {
    const service = new SacVariableService();
    service.setVariable('v1', 'val');
    service.removeVariable('v1');
    expect(service.getVariable('v1')).toBeUndefined();
  });

  it('clearAll removes all variables', () => {
    const service = new SacVariableService();
    service.setVariable('v1', 'a');
    service.setVariable('v2', 'b');
    service.clearAll();
    expect(service.getVariable('v1')).toBeUndefined();
    expect(service.getVariable('v2')).toBeUndefined();
  });

  it('variableValues$ emits on changes', () => {
    const service = new SacVariableService();
    const emissions: Map<string, any>[] = [];

    service.variableValues$.subscribe((m) => emissions.push(new Map(m)));
    service.setVariable('v1', 'test');

    expect(emissions).toHaveLength(2); // initial + set
    expect(emissions[1].has('v1')).toBe(true);
  });
});

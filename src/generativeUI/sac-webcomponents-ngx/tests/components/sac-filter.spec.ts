import { Injector, runInInjectionContext } from '@angular/core';
import { describe, expect, it, vi } from 'vitest';

import {
  SacFilterDropdownComponent,
  SacFilterCheckboxComponent,
  FilterChangeEvent,
} from '../../libs/sac-ai-widget/components/sac-filter.component';
import { SacI18nService } from '../../libs/sac-core/src/lib/services/sac-i18n.service';



describe('SacFilterDropdownComponent', () => {
  function createDropdown(): SacFilterDropdownComponent {
    const injector = Injector.create({
      providers: [{ provide: SacI18nService, useClass: SacI18nService }],
    });
    return runInInjectionContext(injector, () => new SacFilterDropdownComponent());
  }

  it('emits SingleValue filterChange on single selection', () => {
    const dropdown = createDropdown();
    dropdown.dimension = 'Region';
    dropdown.multiple = false;
    dropdown.options = [
      { value: 'EMEA', label: 'EMEA' },
      { value: 'APJ', label: 'APJ' },
    ];

    let emitted: FilterChangeEvent | undefined;
    dropdown.filterChange.subscribe((event: FilterChangeEvent) => {
      emitted = event;
    });

    dropdown.onSelectionChange('EMEA');

    expect(emitted).toEqual({
      dimension: 'Region',
      value: 'EMEA',
      filterType: 'SingleValue',
    });
  });

  it('emits MultipleValue filterChange when multiple=true', () => {
    const dropdown = createDropdown();
    dropdown.dimension = 'Region';
    dropdown.multiple = true;
    dropdown.options = [
      { value: 'EMEA', label: 'EMEA' },
      { value: 'APJ', label: 'APJ' },
    ];

    let emitted: FilterChangeEvent | undefined;
    dropdown.filterChange.subscribe((event: FilterChangeEvent) => {
      emitted = event;
    });

    dropdown.onSelectionChange(['EMEA', 'APJ']);

    expect(emitted).toEqual({
      dimension: 'Region',
      value: ['EMEA', 'APJ'],
      filterType: 'MultipleValue',
    });
  });

  it('generates correct labelId from dimension', () => {
    const dropdown = createDropdown();
    dropdown.dimension = 'Region';
    expect(dropdown.labelId).toBe('filter-label-Region');
  });

  it('announces selection change for screen readers', () => {
    const dropdown = createDropdown();
    dropdown.options = [{ value: 'EMEA', label: 'Europe' }];

    dropdown.onSelectionChange('EMEA');
    expect(dropdown.announcement).toBe('Selected Europe');
  });

  it('announces count for multi-select', () => {
    const dropdown = createDropdown();
    dropdown.multiple = true;

    dropdown.onSelectionChange(['EMEA', 'APJ']);
    expect(dropdown.announcement).toBe('Selected 2 items');
  });
});

describe('SacFilterCheckboxComponent', () => {
  function createCheckbox(): SacFilterCheckboxComponent {
    const injector = Injector.create({
      providers: [{ provide: SacI18nService, useClass: SacI18nService }],
    });
    return runInInjectionContext(injector, () => new SacFilterCheckboxComponent());
  }

  it('emits MultipleValue with selected option values', () => {
    const checkbox = createCheckbox();
    checkbox.dimension = 'Region';
    checkbox.options = [
      { value: 'EMEA', label: 'EMEA', selected: true },
      { value: 'APJ', label: 'APJ', selected: false },
    ];

    let emitted: FilterChangeEvent | undefined;
    checkbox.filterChange.subscribe((event: FilterChangeEvent) => {
      emitted = event;
    });

    const event = { target: { checked: true } } as unknown as Event;
    checkbox.onCheckboxChange(checkbox.options[1], event);

    expect(emitted).toEqual({
      dimension: 'Region',
      value: ['EMEA', 'APJ'],
      filterType: 'MultipleValue',
    });
  });

  it('toggles option.selected on checkbox change', () => {
    const checkbox = createCheckbox();
    checkbox.dimension = 'Region';
    checkbox.options = [
      { value: 'EMEA', label: 'EMEA', selected: false },
    ];

    const event = { target: { checked: true } } as unknown as Event;
    checkbox.onCheckboxChange(checkbox.options[0], event);

    expect(checkbox.options[0].selected).toBe(true);
  });

  it('announces checked state for screen readers', () => {
    const checkbox = createCheckbox();
    checkbox.dimension = 'Region';
    checkbox.options = [
      { value: 'EMEA', label: 'EMEA', selected: false },
    ];

    const event = { target: { checked: true } } as unknown as Event;
    checkbox.onCheckboxChange(checkbox.options[0], event);

    expect(checkbox.announcement).toBe('EMEA selected, 1 total');
  });

  it('announces unchecked state for screen readers', () => {
    const checkbox = createCheckbox();
    checkbox.dimension = 'Region';
    checkbox.options = [
      { value: 'EMEA', label: 'EMEA', selected: true },
      { value: 'APJ', label: 'APJ', selected: true },
    ];

    const event = { target: { checked: false } } as unknown as Event;
    checkbox.onCheckboxChange(checkbox.options[0], event);

    expect(checkbox.announcement).toBe('EMEA deselected, 1 total');
  });

  it('generates correct descId from dimension', () => {
    const checkbox = createCheckbox();
    checkbox.dimension = 'Year';
    expect(checkbox.descId).toBe('filter-desc-Year');
  });
});

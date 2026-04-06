import { Injector, runInInjectionContext } from '@angular/core';
import { describe, expect, it, vi } from 'vitest';

import {
  SacSliderComponent,
  SliderChangeEvent,
} from '../../libs/sac-ai-widget/components/sac-slider.component';
import { SacI18nService } from '../../libs/sac-core/src/lib/services/sac-i18n.service';

/** Create a minimal KeyboardEvent-like object for Node.js environment. */
function keyEvent(key: string): KeyboardEvent {
  return { key, preventDefault: vi.fn() } as unknown as KeyboardEvent;
}

describe('SacSliderComponent', () => {
  function createSlider(): SacSliderComponent {
    const injector = Injector.create({
      providers: [{ provide: SacI18nService, useClass: SacI18nService }],
    });
    return runInInjectionContext(injector, () => new SacSliderComponent());
  }

  it('initializes value to initialValue when provided', () => {
    const slider = createSlider();
    slider.min = 0;
    slider.max = 100;
    slider.initialValue = 42;
    slider.ngOnInit();

    expect(slider.value).toBe(42);
  });

  it('initializes value to min when initialValue is not provided', () => {
    const slider = createSlider();
    slider.min = 10;
    slider.max = 100;
    slider.ngOnInit();

    expect(slider.value).toBe(10);
  });

  it('formats currency values with dollar sign', () => {
    const slider = createSlider();
    slider.format = 'currency';

    expect(slider.formatValue(1500)).toMatch(/^\$1,?500$/);
  });

  it('formats percent values with percent suffix', () => {
    const slider = createSlider();
    slider.format = 'percent';

    expect(slider.formatValue(75)).toBe('75%');
  });

  it('formats plain number values with locale string', () => {
    const slider = createSlider();
    slider.format = 'number';

    const result = slider.formatValue(1000);
    expect(result).toMatch(/1,?000/);
  });

  it('emits sliderChange on value change', () => {
    const slider = createSlider();
    slider.dimension = 'Amount';

    let emitted: SliderChangeEvent | undefined;
    slider.sliderChange.subscribe((event: SliderChangeEvent) => {
      emitted = event;
    });

    slider.onValueChange(50);

    expect(emitted).toEqual({
      dimension: 'Amount',
      value: 50,
    });
  });

  it('announces value change for screen readers', () => {
    const slider = createSlider();
    slider.label = 'Revenue';
    slider.format = 'number';

    slider.onValueChange(500);

    expect(slider.announcement).toContain('Revenue');
    expect(slider.announcement).toContain('500');
  });

  it('sets value to min on Home key', () => {
    const slider = createSlider();
    slider.min = 0;
    slider.max = 100;
    slider.value = 50;

    let emitted: SliderChangeEvent | undefined;
    slider.sliderChange.subscribe((event: SliderChangeEvent) => {
      emitted = event;
    });

    const event = keyEvent('Home');
    slider.onKeyDown(event);

    expect(slider.value).toBe(0);
    expect(emitted?.value).toBe(0);
    expect(event.preventDefault).toHaveBeenCalled();
  });

  it('sets value to max on End key', () => {
    const slider = createSlider();
    slider.min = 0;
    slider.max = 100;
    slider.value = 50;

    slider.onKeyDown(keyEvent('End'));

    expect(slider.value).toBe(100);
  });

  it('increments by 10% step on PageUp', () => {
    const slider = createSlider();
    slider.min = 0;
    slider.max = 100;
    slider.value = 50;

    slider.onKeyDown(keyEvent('PageUp'));

    expect(slider.value).toBe(60);
  });

  it('decrements by 10% step on PageDown', () => {
    const slider = createSlider();
    slider.min = 0;
    slider.max = 100;
    slider.value = 50;

    slider.onKeyDown(keyEvent('PageDown'));

    expect(slider.value).toBe(40);
  });

  it('clamps PageUp to max', () => {
    const slider = createSlider();
    slider.min = 0;
    slider.max = 100;
    slider.value = 95;

    slider.onKeyDown(keyEvent('PageUp'));

    expect(slider.value).toBe(100);
  });

  it('clamps PageDown to min', () => {
    const slider = createSlider();
    slider.min = 0;
    slider.max = 100;
    slider.value = 5;

    slider.onKeyDown(keyEvent('PageDown'));

    expect(slider.value).toBe(0);
  });

  it('generates correct labelId from dimension', () => {
    const slider = createSlider();
    slider.dimension = 'Revenue';
    expect(slider.labelId).toBe('slider-label-Revenue');
  });
});

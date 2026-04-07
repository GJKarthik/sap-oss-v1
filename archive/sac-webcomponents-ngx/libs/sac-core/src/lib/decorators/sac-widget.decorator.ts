/**
 * SacWidget decorator — marks a component as a SAC widget wrapper.
 * Stores metadata for selector/input/output derivation via Mangle rules.
 */
const SAC_WIDGET_META = new WeakMap<object, string>();

export function SacWidget(config: { widgetType: string }): ClassDecorator {
  return (target: Function) => {
    SAC_WIDGET_META.set(target, config.widgetType);
  };
}

export function getSacWidgetType(target: Function): string | undefined {
  return SAC_WIDGET_META.get(target);
}

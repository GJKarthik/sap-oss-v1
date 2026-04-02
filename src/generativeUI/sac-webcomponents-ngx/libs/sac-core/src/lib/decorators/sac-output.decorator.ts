/**
 * SacOutput decorator — marks a property as a SAC widget output event.
 */
const SAC_OUTPUT_META = new WeakMap<object, Map<string, string>>();

export function SacOutput(alias?: string): PropertyDecorator {
  return (target: Object, propertyKey: string | symbol) => {
    const key = String(propertyKey);
    let map = SAC_OUTPUT_META.get(target.constructor);
    if (!map) {
      map = new Map();
      SAC_OUTPUT_META.set(target.constructor, map);
    }
    map.set(key, alias ?? key);
  };
}

export function getSacOutputs(target: Function): Map<string, string> | undefined {
  return SAC_OUTPUT_META.get(target);
}

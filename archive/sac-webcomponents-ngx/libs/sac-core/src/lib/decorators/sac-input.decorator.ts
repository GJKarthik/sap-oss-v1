/**
 * SacInput decorator — marks a property as a SAC widget input binding.
 */
const SAC_INPUT_META = new WeakMap<object, Map<string, string>>();

export function SacInput(alias?: string): PropertyDecorator {
  return (target: Object, propertyKey: string | symbol) => {
    const key = String(propertyKey);
    let map = SAC_INPUT_META.get(target.constructor);
    if (!map) {
      map = new Map();
      SAC_INPUT_META.set(target.constructor, map);
    }
    map.set(key, alias ?? key);
  };
}

export function getSacInputs(target: Function): Map<string, string> | undefined {
  return SAC_INPUT_META.get(target);
}

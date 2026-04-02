/**
 * Cast Utility
 *
 * Type-safe casting helper mirroring the `cast` function
 * from sap-sac-webcomponents-ts/src/builtins.
 *
 * Provides runtime type assertion with optional fallback.
 */

/**
 * Cast a value to the target type with an optional runtime type guard.
 *
 * @param value    The value to cast.
 * @param guard    Optional runtime predicate that validates the cast.
 * @param fallback Optional fallback value if the guard fails.
 * @returns        The value typed as T.
 * @throws         TypeError if the guard fails and no fallback is provided.
 */
export function cast<T>(
  value: unknown,
  guard?: (v: unknown) => v is T,
  fallback?: T,
): T {
  if (guard) {
    if (guard(value)) {
      return value;
    }
    if (fallback !== undefined) {
      return fallback;
    }
    throw new TypeError(
      `cast failed: value ${JSON.stringify(value)} did not pass type guard`,
    );
  }
  return value as T;
}

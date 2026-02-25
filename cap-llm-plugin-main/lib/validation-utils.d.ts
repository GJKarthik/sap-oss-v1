/**
 * Type declarations for validation-utils.js (until migrated to .ts).
 */
export function validateSqlIdentifier(name: string, label: string): void;
export function validatePositiveInteger(value: unknown, label: string, max?: number): void;
export function validateEmbeddingVector(embedding: unknown): void;

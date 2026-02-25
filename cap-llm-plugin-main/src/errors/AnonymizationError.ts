import { CAPLLMPluginError } from "./CAPLLMPluginError";

/**
 * Error thrown during anonymization operations.
 *
 * Covers entity-not-found, missing sequence column, and invalid
 * sequence ID errors in getAnonymizedData.
 */
export class AnonymizationError extends CAPLLMPluginError {
  constructor(message: string, code: string, details?: Record<string, unknown>) {
    super(message, code, details);
    this.name = "AnonymizationError";
  }
}

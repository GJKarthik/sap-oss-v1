import { OrchestrationClient } from '@sap-ai-sdk/orchestration';
const MAX_TEMPLATE_CHARS = 40000;
const MAX_PLACEHOLDERS = 500;
export default class OrchestrationService {
    async chatCompletion(req) {
        const template = req?.data?.template;
        const placeholderValues = req?.data?.placeholderValues;
        if (typeof template !== 'string' || template.trim().length === 0) {
            throw new Error('chatCompletion requires a non-empty template string.');
        }
        if (template.length > MAX_TEMPLATE_CHARS) {
            throw new Error(`chatCompletion template exceeds maximum length (${MAX_TEMPLATE_CHARS}).`);
        }
        if (!Array.isArray(placeholderValues)) {
            throw new Error('chatCompletion requires placeholderValues as an array.');
        }
        const model = {
            name: 'gpt-4o'
        };
        try {
            const response = await new OrchestrationClient({
                promptTemplating: {
                    model,
                    prompt: { template: template.slice(0, MAX_TEMPLATE_CHARS) }
                }
            }).chatCompletion({
                placeholderValues: mapPlaceholderValues(placeholderValues.slice(0, MAX_PLACEHOLDERS))
            });
            return response.getContent();
        }
        catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            throw new Error(`Orchestration chat completion failed: ${message}`);
        }
    }
}
/**
 * Map placeholder values since CAP does not support dynamic object keys.
 *
 * For example:
 *
 * ```ts
 * placeholderValues: [{
 *   name: 'param1',
 *   value: 'value1'
 * }]
 * ```
 * =>
 * ```ts
 * mappedPlaceholderValues: {
 *   param1: 'value1'
 * }
 * ```
 * @param inputParams - Array of `PlaceholderValue` entity.
 * @returns Mapped placeholder values for orchestration service.
 */
function mapPlaceholderValues(placeholderValues) {
    const mapped = {};
    for (const entry of placeholderValues) {
        if (!entry || typeof entry.name !== 'string')
            continue;
        const name = entry.name.trim();
        if (!name)
            continue;
        mapped[name] = typeof entry.value === 'string' ? entry.value : String(entry.value ?? '');
    }
    return mapped;
}
//# sourceMappingURL=orchestration-service.js.map
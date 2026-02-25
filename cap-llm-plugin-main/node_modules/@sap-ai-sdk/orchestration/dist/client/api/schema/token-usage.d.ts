/**
 * Usage of tokens in the response
 */
export type TokenUsage = {
    /**
     * Number of tokens used in the input
     * @example 20
     */
    completion_tokens: number;
    /**
     * Number of tokens used in the output
     * @example 30
     */
    prompt_tokens: number;
    /**
     * Total number of tokens used
     * @example 50
     */
    total_tokens: number;
} & Record<string, any>;
//# sourceMappingURL=token-usage.d.ts.map
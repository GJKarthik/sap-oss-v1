/**
 * Generic module result
 */
export type GenericModuleResult = {
    /**
     * Some message created from the module
     * @example "Input to LLM is masked successfully."
     */
    message: string;
    /**
     * Additional data object from the module
     */
    data?: Record<string, any>;
} & Record<string, any>;
//# sourceMappingURL=generic-module-result.d.ts.map
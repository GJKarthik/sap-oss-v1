/**
 * A2UiSchema Generator
 *
 * Uses LLM function calling to generate SAP Fiori UI schemas dynamically
 * based on user intent and available data.
 */
import type { A2UiSchema } from './event-types';
/** Whitelisted UI5 Web Components for schema generation */
export declare const ALLOWED_COMPONENTS: Set<string>;
/**
 * OpenAI function definition for generating A2UiSchema
 */
export declare const GENERATE_UI_FUNCTION: {
    name: string;
    description: string;
    parameters: {
        type: string;
        properties: {
            layout: {
                type: string;
                description: string;
                properties: {
                    id: {
                        type: string;
                        description: string;
                    };
                    type: {
                        type: string;
                        description: string;
                        enum: string[];
                    };
                    props: {
                        type: string;
                        description: string;
                        additionalProperties: boolean;
                    };
                    children: {
                        type: string;
                        description: string;
                        items: {
                            $ref: string;
                        };
                    };
                    slots: {
                        type: string;
                        description: string;
                        additionalProperties: {
                            type: string;
                            items: {
                                $ref: string;
                            };
                        };
                    };
                    dataBinding: {
                        type: string;
                        properties: {
                            source: {
                                type: string;
                            };
                            path: {
                                type: string;
                            };
                        };
                    };
                };
                required: string[];
            };
            dataSources: {
                type: string;
                description: string;
                additionalProperties: {
                    type: string;
                    properties: {
                        type: {
                            type: string;
                            enum: string[];
                        };
                        endpoint: {
                            type: string;
                        };
                        data: {};
                    };
                };
            };
            actions: {
                type: string;
                description: string;
                additionalProperties: {
                    type: string;
                    properties: {
                        type: {
                            type: string;
                            enum: string[];
                        };
                        endpoint: {
                            type: string;
                        };
                        method: {
                            type: string;
                            enum: string[];
                        };
                        requiresConfirmation: {
                            type: string;
                        };
                    };
                };
            };
        };
        required: string[];
    };
};
export declare const UI_GENERATION_SYSTEM_PROMPT = "You are an expert SAP Fiori UI architect. Your task is to generate A2UiSchema JSON structures that describe enterprise UIs using UI5 Web Components.\n\nDESIGN PRINCIPLES:\n1. Follow SAP Fiori design guidelines for consistency and familiarity\n2. Use appropriate floorplans: List Report, Object Page, Worklist, Dashboard, Wizard\n3. Ensure accessibility with proper labels, ARIA attributes, and keyboard navigation\n4. Design for responsive layouts that work on desktop and mobile\n5. Group related information logically using cards, panels, and sections\n6. Provide clear visual hierarchy with appropriate typography\n7. Include loading states and empty states where appropriate\n\nCOMPONENT SELECTION:\n- Tables (ui5-table): For structured data lists with sorting/filtering\n- Cards (ui5-card): For summarized information blocks\n- Forms (ui5-input, ui5-select, etc.): For data entry with validation\n- Charts: For data visualization (use appropriate chart types)\n- Dialogs (ui5-dialog): For confirmations and secondary workflows\n- Navigation (ui5-breadcrumbs, ui5-tabs): For multi-level navigation\n\nDATA BINDING:\n- Use dataBinding to connect components to data sources\n- Prefer OData endpoints for SAP backend integration\n- Include proper paths for nested data access\n\nACTIONS:\n- Mark destructive actions with requiresConfirmation: true\n- Use semantic button designs (emphasized for primary, transparent for secondary)\n\nGenerate valid JSON matching the A2UiSchema format.";
export interface SchemaGeneratorConfig {
    modelName: string;
    resourceGroup: string;
}
export interface GenerateSchemaParams {
    userIntent: string;
    context?: {
        entityType?: string;
        availableData?: Record<string, unknown>;
        userRole?: string;
        previousUI?: A2UiSchema;
    };
}
export interface GenerateSchemaResult {
    schema: A2UiSchema;
    explanation?: string;
    rawResponse?: unknown;
}
/**
 * Schema Generator - Uses LLM to generate A2UiSchema from natural language
 */
export declare class SchemaGenerator {
    private config;
    constructor(config: SchemaGeneratorConfig);
    /**
     * Generate A2UiSchema from user intent
     */
    generateSchema(params: GenerateSchemaParams, llmPlugin: {
        getChatCompletionWithConfig: (config: unknown, payload: unknown) => Promise<unknown>;
    }): Promise<GenerateSchemaResult>;
    /**
     * Generate a streaming schema (returns partial updates)
     */
    generateSchemaStreaming(params: GenerateSchemaParams, llmPlugin: {
        streamChatCompletion: (params: unknown, req?: unknown) => Promise<string>;
    }): AsyncGenerator<Partial<A2UiSchema>, void, unknown>;
    /**
     * Build messages for LLM
     */
    private buildMessages;
    /**
     * Parse LLM response into schema result
     */
    private parseResponse;
    /**
     * Parse schema JSON from content string
     */
    private parseSchemaFromContent;
    /**
     * Sanitize schema to ensure only allowed components
     */
    private sanitizeSchema;
    /**
     * Recursively sanitize component tree
     */
    private sanitizeComponent;
    /**
     * Sanitize component props
     */
    private sanitizeProps;
    /**
     * Basic string sanitization
     */
    private sanitizeString;
}
/**
 * Create a simple text UI schema
 */
export declare function createTextSchema(text: string, id?: string): A2UiSchema;
/**
 * Create a loading state schema
 */
export declare function createLoadingSchema(message?: string): A2UiSchema;
/**
 * Create an error state schema
 */
export declare function createErrorSchema(error: string, title?: string): A2UiSchema;
//# sourceMappingURL=schema-generator.d.ts.map
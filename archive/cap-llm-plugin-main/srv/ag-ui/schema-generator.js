"use strict";
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * A2UiSchema Generator
 *
 * Uses LLM function calling to generate SAP Fiori UI schemas dynamically
 * based on user intent and available data.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.SchemaGenerator = exports.UI_GENERATION_SYSTEM_PROMPT = exports.GENERATE_UI_FUNCTION = exports.ALLOWED_COMPONENTS = void 0;
exports.createTextSchema = createTextSchema;
exports.createLoadingSchema = createLoadingSchema;
exports.createErrorSchema = createErrorSchema;
// =============================================================================
// Allowed Fiori Components (Security Whitelist)
// =============================================================================
/** Whitelisted UI5 Web Components for schema generation */
exports.ALLOWED_COMPONENTS = new Set([
    // Layout
    'ui5-bar', 'ui5-card', 'ui5-card-header', 'ui5-panel', 'ui5-page',
    'ui5-flexible-column-layout', 'ui5-dynamic-page', 'ui5-dynamic-page-header',
    'ui5-dynamic-page-title', 'ui5-toolbar', 'ui5-toolbar-spacer', 'ui5-toolbar-separator',
    // Display
    'ui5-title', 'ui5-label', 'ui5-text', 'ui5-badge', 'ui5-tag', 'ui5-icon',
    'ui5-avatar', 'ui5-avatar-group', 'ui5-rating-indicator', 'ui5-progress-indicator',
    'ui5-illustrated-message', 'ui5-busy-indicator',
    // Data Display
    'ui5-table', 'ui5-table-column', 'ui5-table-row', 'ui5-table-cell',
    'ui5-list', 'ui5-li', 'ui5-li-custom', 'ui5-li-groupheader',
    'ui5-tree', 'ui5-tree-item',
    // Forms
    'ui5-input', 'ui5-textarea', 'ui5-select', 'ui5-option', 'ui5-combobox',
    'ui5-combobox-item', 'ui5-multi-combobox', 'ui5-date-picker', 'ui5-time-picker',
    'ui5-datetime-picker', 'ui5-checkbox', 'ui5-radio-button', 'ui5-switch',
    'ui5-slider', 'ui5-range-slider', 'ui5-step-input', 'ui5-file-uploader',
    // Actions
    'ui5-button', 'ui5-segmented-button', 'ui5-segmented-button-item',
    'ui5-split-button', 'ui5-toggle-button', 'ui5-menu', 'ui5-menu-item',
    // Navigation
    'ui5-link', 'ui5-breadcrumbs', 'ui5-breadcrumbs-item', 'ui5-tabs',
    'ui5-tab', 'ui5-tab-separator', 'ui5-side-navigation', 'ui5-side-navigation-item',
    'ui5-side-navigation-sub-item', 'ui5-wizard', 'ui5-wizard-step',
    // Dialogs
    'ui5-dialog', 'ui5-popover', 'ui5-responsive-popover', 'ui5-message-strip',
    'ui5-toast',
    // Charts (Fiori compliant)
    'ui5-micro-bar-chart', 'ui5-radial-chart',
]);
// =============================================================================
// LLM Function Definition for UI Generation
// =============================================================================
/**
 * OpenAI function definition for generating A2UiSchema
 */
exports.GENERATE_UI_FUNCTION = {
    name: 'generate_ui',
    description: `Generate a SAP Fiori UI schema (A2UiSchema) based on user requirements.
The schema describes a UI layout using UI5 Web Components that will be rendered dynamically.
Use appropriate Fiori patterns: List Reports, Object Pages, Worklists, Wizards, Dashboards.`,
    parameters: {
        type: 'object',
        properties: {
            layout: {
                type: 'object',
                description: 'Root UI component tree',
                properties: {
                    id: { type: 'string', description: 'Unique component ID' },
                    type: {
                        type: 'string',
                        description: 'UI5 Web Component tag name (e.g., ui5-card, ui5-table)',
                        enum: Array.from(exports.ALLOWED_COMPONENTS),
                    },
                    props: {
                        type: 'object',
                        description: 'Component properties',
                        additionalProperties: true,
                    },
                    children: {
                        type: 'array',
                        description: 'Child components',
                        items: { $ref: '#/properties/layout' },
                    },
                    slots: {
                        type: 'object',
                        description: 'Named slots with component arrays',
                        additionalProperties: {
                            type: 'array',
                            items: { $ref: '#/properties/layout' },
                        },
                    },
                    dataBinding: {
                        type: 'object',
                        properties: {
                            source: { type: 'string' },
                            path: { type: 'string' },
                        },
                    },
                },
                required: ['id', 'type'],
            },
            dataSources: {
                type: 'object',
                description: 'Data sources for binding',
                additionalProperties: {
                    type: 'object',
                    properties: {
                        type: { type: 'string', enum: ['odata', 'rest', 'static'] },
                        endpoint: { type: 'string' },
                        data: {},
                    },
                },
            },
            actions: {
                type: 'object',
                description: 'Available actions',
                additionalProperties: {
                    type: 'object',
                    properties: {
                        type: { type: 'string', enum: ['navigate', 'api', 'custom'] },
                        endpoint: { type: 'string' },
                        method: { type: 'string', enum: ['GET', 'POST', 'PUT', 'DELETE'] },
                        requiresConfirmation: { type: 'boolean' },
                    },
                },
            },
        },
        required: ['layout'],
    },
};
// =============================================================================
// System Prompt for UI Generation
// =============================================================================
exports.UI_GENERATION_SYSTEM_PROMPT = `You are an expert SAP Fiori UI architect. Your task is to generate A2UiSchema JSON structures that describe enterprise UIs using UI5 Web Components.

DESIGN PRINCIPLES:
1. Follow SAP Fiori design guidelines for consistency and familiarity
2. Use appropriate floorplans: List Report, Object Page, Worklist, Dashboard, Wizard
3. Ensure accessibility with proper labels, ARIA attributes, and keyboard navigation
4. Design for responsive layouts that work on desktop and mobile
5. Group related information logically using cards, panels, and sections
6. Provide clear visual hierarchy with appropriate typography
7. Include loading states and empty states where appropriate

COMPONENT SELECTION:
- Tables (ui5-table): For structured data lists with sorting/filtering
- Cards (ui5-card): For summarized information blocks
- Forms (ui5-input, ui5-select, etc.): For data entry with validation
- Charts: For data visualization (use appropriate chart types)
- Dialogs (ui5-dialog): For confirmations and secondary workflows
- Navigation (ui5-breadcrumbs, ui5-tabs): For multi-level navigation

DATA BINDING:
- Use dataBinding to connect components to data sources
- Prefer OData endpoints for SAP backend integration
- Include proper paths for nested data access

ACTIONS:
- Mark destructive actions with requiresConfirmation: true
- Use semantic button designs (emphasized for primary, transparent for secondary)

Generate valid JSON matching the A2UiSchema format.`;
/**
 * Schema Generator - Uses LLM to generate A2UiSchema from natural language
 */
class SchemaGenerator {
    constructor(config) {
        this.config = config;
    }
    /**
     * Generate A2UiSchema from user intent
     */
    async generateSchema(params, llmPlugin) {
        const messages = this.buildMessages(params);
        const response = await llmPlugin.getChatCompletionWithConfig({
            modelName: this.config.modelName,
            resourceGroup: this.config.resourceGroup,
        }, {
            messages,
            functions: [exports.GENERATE_UI_FUNCTION],
            function_call: { name: 'generate_ui' },
        });
        return this.parseResponse(response);
    }
    /**
     * Generate a streaming schema (returns partial updates)
     */
    async *generateSchemaStreaming(params, llmPlugin) {
        // For streaming, we accumulate JSON and yield partial parses
        const streamParams = {
            clientConfig: JSON.stringify({
                promptTemplating: {
                    model: { name: this.config.modelName },
                },
            }),
            chatCompletionConfig: JSON.stringify({
                messages: this.buildMessages(params),
                functions: [exports.GENERATE_UI_FUNCTION],
                function_call: { name: 'generate_ui' },
            }),
        };
        // Note: This is a simplified streaming approach
        // In production, would use actual SSE streaming with partial JSON parsing
        const fullContent = await llmPlugin.streamChatCompletion(streamParams);
        try {
            const schema = this.parseSchemaFromContent(fullContent);
            yield schema;
        }
        catch {
            // Yield empty partial on parse error
            yield { layout: { id: 'error', type: 'ui5-text', props: { text: 'Failed to generate UI' } } };
        }
    }
    /**
     * Build messages for LLM
     */
    buildMessages(params) {
        const messages = [
            { role: 'system', content: exports.UI_GENERATION_SYSTEM_PROMPT },
        ];
        // Add context if provided
        if (params.context) {
            let contextMessage = 'Additional context:\n';
            if (params.context.entityType) {
                contextMessage += `- Entity type: ${params.context.entityType}\n`;
            }
            if (params.context.userRole) {
                contextMessage += `- User role: ${params.context.userRole}\n`;
            }
            if (params.context.availableData) {
                contextMessage += `- Available data structure: ${JSON.stringify(params.context.availableData, null, 2)}\n`;
            }
            if (params.context.previousUI) {
                contextMessage += `- Previous UI layout ID: ${params.context.previousUI.layout?.id}\n`;
            }
            messages.push({ role: 'system', content: contextMessage });
        }
        // Add user intent
        messages.push({ role: 'user', content: params.userIntent });
        return messages;
    }
    /**
     * Parse LLM response into schema result
     */
    parseResponse(response) {
        const resp = response;
        // Try to extract function call arguments
        let schemaJson;
        // SDK response format
        if (typeof resp?.getContent === 'function') {
            schemaJson = resp.getContent();
        }
        // Raw OpenAI format
        else if (resp?.choices?.[0]?.message?.function_call?.arguments) {
            schemaJson = resp.choices[0].message.function_call.arguments;
        }
        // Fallback to content
        else if (resp?.choices?.[0]?.message?.content) {
            schemaJson = resp.choices[0].message.content;
        }
        if (!schemaJson) {
            throw new Error('No schema content in LLM response');
        }
        const schema = this.parseSchemaFromContent(schemaJson);
        return {
            schema,
            rawResponse: response,
        };
    }
    /**
     * Parse schema JSON from content string
     */
    parseSchemaFromContent(content) {
        // Try to extract JSON from content (may be wrapped in markdown code blocks)
        let jsonStr = content;
        // Remove markdown code fences if present
        const codeBlockMatch = content.match(/```(?:json)?\s*([\s\S]*?)```/);
        if (codeBlockMatch) {
            jsonStr = codeBlockMatch[1];
        }
        const parsed = JSON.parse(jsonStr.trim());
        // Validate and sanitize the schema
        return this.sanitizeSchema(parsed);
    }
    /**
     * Sanitize schema to ensure only allowed components
     */
    sanitizeSchema(schema) {
        const s = schema;
        if (!s.layout) {
            throw new Error('Schema missing required layout property');
        }
        s.layout = this.sanitizeComponent(s.layout);
        return {
            $schema: 'https://sap.github.io/ui5-webcomponents/schemas/a2ui-schema.json',
            version: '1.0',
            layout: s.layout,
            dataSources: s.dataSources,
            actions: s.actions,
        };
    }
    /**
     * Recursively sanitize component tree
     */
    sanitizeComponent(component) {
        // Validate component type against whitelist
        if (!exports.ALLOWED_COMPONENTS.has(component.type)) {
            // Replace with safe fallback
            return {
                id: component.id,
                type: 'ui5-text',
                props: { text: `[Blocked component: ${component.type}]` },
            };
        }
        // Sanitize children
        if (component.children) {
            component.children = component.children.map((c) => this.sanitizeComponent(c));
        }
        // Sanitize slots
        if (component.slots) {
            for (const slotName of Object.keys(component.slots)) {
                component.slots[slotName] = component.slots[slotName].map((c) => this.sanitizeComponent(c));
            }
        }
        // Sanitize props (basic XSS prevention)
        if (component.props) {
            component.props = this.sanitizeProps(component.props);
        }
        return component;
    }
    /**
     * Sanitize component props
     */
    sanitizeProps(props) {
        const sanitized = {};
        for (const [key, value] of Object.entries(props)) {
            // Skip event handlers (security)
            if (key.startsWith('on') || key.includes('javascript:')) {
                continue;
            }
            // Sanitize string values
            if (typeof value === 'string') {
                sanitized[key] = this.sanitizeString(value);
            }
            else {
                sanitized[key] = value;
            }
        }
        return sanitized;
    }
    /**
     * Basic string sanitization
     */
    sanitizeString(str) {
        return str
            .replace(/javascript:/gi, '')
            .replace(/on\w+=/gi, '')
            .replace(/<script/gi, '&lt;script')
            .replace(/<\/script/gi, '&lt;/script');
    }
}
exports.SchemaGenerator = SchemaGenerator;
// =============================================================================
// Convenience Functions
// =============================================================================
/**
 * Create a simple text UI schema
 */
function createTextSchema(text, id = 'text-message') {
    return {
        $schema: 'https://sap.github.io/ui5-webcomponents/schemas/a2ui-schema.json',
        version: '1.0',
        layout: {
            id,
            type: 'ui5-card',
            children: [
                {
                    id: `${id}-content`,
                    type: 'ui5-text',
                    props: { text },
                },
            ],
        },
    };
}
/**
 * Create a loading state schema
 */
function createLoadingSchema(message = 'Loading...') {
    return {
        $schema: 'https://sap.github.io/ui5-webcomponents/schemas/a2ui-schema.json',
        version: '1.0',
        layout: {
            id: 'loading',
            type: 'ui5-busy-indicator',
            props: {
                active: true,
                size: 'Medium',
                text: message,
            },
        },
    };
}
/**
 * Create an error state schema
 */
function createErrorSchema(error, title = 'Error') {
    return {
        $schema: 'https://sap.github.io/ui5-webcomponents/schemas/a2ui-schema.json',
        version: '1.0',
        layout: {
            id: 'error',
            type: 'ui5-message-strip',
            props: {
                design: 'Negative',
                hideCloseButton: false,
            },
            children: [
                {
                    id: 'error-title',
                    type: 'ui5-title',
                    props: { level: 'H5', text: title },
                },
                {
                    id: 'error-message',
                    type: 'ui5-text',
                    props: { text: error },
                },
            ],
        },
    };
}
//# sourceMappingURL=schema-generator.js.map
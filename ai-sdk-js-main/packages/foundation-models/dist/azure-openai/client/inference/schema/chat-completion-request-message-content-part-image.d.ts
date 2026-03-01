/**
 * Representation of the 'AzureOpenAiChatCompletionRequestMessageContentPartImage' schema.
 */
export type AzureOpenAiChatCompletionRequestMessageContentPartImage = {
    /**
     * The type of the content part.
     */
    type: 'image_url';
    image_url: {
        /**
         * Either a URL of the image or the base64 encoded image data.
         * Format: "uri".
         */
        url: string;
        /**
         * Specifies the detail level of the image. Learn more in the [Vision guide](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/gpt-with-vision?tabs=rest%2Csystem-assigned%2Cresource#detail-parameter-settings-in-image-processing-low-high-auto).
         * Default: "auto".
         */
        detail?: 'auto' | 'low' | 'high';
    } & Record<string, any>;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-request-message-content-part-image.d.ts.map
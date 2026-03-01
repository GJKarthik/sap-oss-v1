/**
 * citation information for a chat completions response message.
 */
export type AzureOpenAiCitation = {
    /**
     * The content of the citation.
     */
    content: string;
    /**
     * The title of the citation.
     */
    title?: string;
    /**
     * The URL of the citation.
     */
    url?: string;
    /**
     * The file path of the citation.
     */
    filepath?: string;
    /**
     * The chunk ID of the citation.
     */
    chunk_id?: string;
} & Record<string, any>;
//# sourceMappingURL=citation.d.ts.map
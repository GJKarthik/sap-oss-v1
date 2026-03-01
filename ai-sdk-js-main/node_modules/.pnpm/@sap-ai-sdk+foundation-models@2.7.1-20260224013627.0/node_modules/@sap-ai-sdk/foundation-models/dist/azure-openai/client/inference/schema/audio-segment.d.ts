/**
 * Transcription or translation segment.
 */
export type AzureOpenAiAudioSegment = {
    /**
     * Segment identifier.
     */
    id?: number;
    /**
     * Offset of the segment.
     */
    seek?: number;
    /**
     * Segment start offset.
     */
    start?: number;
    /**
     * Segment end offset.
     */
    end?: number;
    /**
     * Segment text.
     */
    text?: string;
    /**
     * Tokens of the text.
     */
    tokens?: number[];
    /**
     * Temperature.
     */
    temperature?: number;
    /**
     * Average log probability.
     */
    avg_logprob?: number;
    /**
     * Compression ratio.
     */
    compression_ratio?: number;
    /**
     * Probability of 'no speech'.
     */
    no_speech_prob?: number;
} & Record<string, any>;
//# sourceMappingURL=audio-segment.d.ts.map
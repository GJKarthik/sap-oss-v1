/**
 * StreamBuilder tests.
 */

import {
  StreamBuilder,
  streamToMessage,
  createTextAccumulator,
  createTokenCounter,
  teeStream,
  type StreamResult,
  type ToolCallDelta,
} from '../src/stream-builder.js';
import type { VllmStreamChunk } from '../src/types.js';

// Helper to create mock chunks
function createMockChunk(
  content?: string,
  finishReason?: string | null,
  role?: string
): VllmStreamChunk {
  return {
    id: 'test-id',
    object: 'chat.completion.chunk',
    created: Date.now(),
    model: 'test-model',
    choices: [
      {
        index: 0,
        delta: {
          role: role as 'assistant' | undefined,
          content,
        },
        finishReason: finishReason as 'stop' | 'length' | 'tool_calls' | null,
      },
    ],
  };
}

// Helper to create async generator from chunks
async function* mockStream(
  chunks: VllmStreamChunk[]
): AsyncGenerator<VllmStreamChunk, void, unknown> {
  for (const chunk of chunks) {
    yield chunk;
  }
}

describe('StreamBuilder', () => {
  describe('basic execution', () => {
    it('should process empty stream', async () => {
      const result = await new StreamBuilder().execute(mockStream([]));

      expect(result.content).toBe('');
      expect(result.chunks).toBe(0);
      expect(result.finishReason).toBeNull();
    });

    it('should accumulate content from chunks', async () => {
      const chunks = [
        createMockChunk('Hello'),
        createMockChunk(' '),
        createMockChunk('World'),
        createMockChunk('!', 'stop'),
      ];

      const result = await new StreamBuilder().execute(mockStream(chunks));

      expect(result.content).toBe('Hello World!');
      expect(result.chunks).toBe(4);
      expect(result.finishReason).toBe('stop');
    });

    it('should track duration', async () => {
      const chunks = [createMockChunk('Hi', 'stop')];
      const result = await new StreamBuilder().execute(mockStream(chunks));

      expect(result.duration).toBeGreaterThanOrEqual(0);
    });

    it('should track time to first chunk', async () => {
      const chunks = [createMockChunk('Hi', 'stop')];
      const result = await new StreamBuilder().execute(mockStream(chunks));

      expect(result.timeToFirstChunk).not.toBeNull();
      expect(result.timeToFirstChunk).toBeGreaterThanOrEqual(0);
    });
  });

  describe('callbacks', () => {
    it('should call onChunk for each chunk', async () => {
      const chunks = [
        createMockChunk('A'),
        createMockChunk('B'),
        createMockChunk('C'),
      ];

      const received: VllmStreamChunk[] = [];
      await new StreamBuilder()
        .onChunk((chunk) => received.push(chunk))
        .execute(mockStream(chunks));

      expect(received).toHaveLength(3);
    });

    it('should call onContent with content delta', async () => {
      const chunks = [
        createMockChunk('Hello'),
        createMockChunk(' World'),
      ];

      const contents: string[] = [];
      await new StreamBuilder()
        .onContent((content) => contents.push(content))
        .execute(mockStream(chunks));

      expect(contents).toEqual(['Hello', ' World']);
    });

    it('should call onStart on first chunk', async () => {
      const chunks = [
        createMockChunk('A'),
        createMockChunk('B'),
      ];

      let startChunk: VllmStreamChunk | null = null;
      await new StreamBuilder()
        .onStart((chunk) => { startChunk = chunk; })
        .execute(mockStream(chunks));

      expect(startChunk).not.toBeNull();
      expect(startChunk!.choices[0].delta.content).toBe('A');
    });

    it('should call onComplete with result', async () => {
      const chunks = [createMockChunk('Done', 'stop')];

      let completedResult: StreamResult | null = null;
      await new StreamBuilder()
        .onComplete((result) => { completedResult = result; })
        .execute(mockStream(chunks));

      expect(completedResult).not.toBeNull();
      expect(completedResult!.content).toBe('Done');
    });

    it('should call onError on exception', async () => {
      async function* errorStream(): AsyncGenerator<VllmStreamChunk, void, unknown> {
        throw new Error('Stream failed');
      }

      let caughtError: Error | null = null;

      try {
        await new StreamBuilder()
          .onError((error) => { caughtError = error; })
          .execute(errorStream());
      } catch {
        // Expected
      }

      expect(caughtError).not.toBeNull();
      expect(caughtError!.message).toBe('Stream failed');
    });
  });

  describe('middleware', () => {
    it('should apply middleware to chunks', async () => {
      const chunks = [
        createMockChunk('hello'),
        createMockChunk(' world'),
      ];

      const result = await new StreamBuilder()
        .use((chunk) => {
          // Uppercase content
          if (chunk.choices[0]?.delta?.content) {
            return {
              ...chunk,
              choices: [{
                ...chunk.choices[0],
                delta: {
                  ...chunk.choices[0].delta,
                  content: chunk.choices[0].delta.content.toUpperCase(),
                },
              }],
            };
          }
          return chunk;
        })
        .execute(mockStream(chunks));

      expect(result.content).toBe('HELLO WORLD');
    });

    it('should filter chunks with null return', async () => {
      const chunks = [
        createMockChunk('keep'),
        createMockChunk('skip'),
        createMockChunk('keep'),
      ];

      const result = await new StreamBuilder()
        .use((chunk) => {
          if (chunk.choices[0]?.delta?.content === 'skip') {
            return null;
          }
          return chunk;
        })
        .execute(mockStream(chunks));

      expect(result.content).toBe('keepkeep');
      expect(result.chunks).toBe(2);
    });

    it('should chain multiple middleware', async () => {
      const chunks = [createMockChunk('hello')];

      const order: string[] = [];
      await new StreamBuilder()
        .use((chunk) => { order.push('first'); return chunk; })
        .use((chunk) => { order.push('second'); return chunk; })
        .use((chunk) => { order.push('third'); return chunk; })
        .execute(mockStream(chunks));

      expect(order).toEqual(['first', 'second', 'third']);
    });
  });

  describe('filter helper', () => {
    it('should filter chunks based on predicate', async () => {
      const chunks = [
        createMockChunk('a'),
        createMockChunk('bb'),
        createMockChunk('ccc'),
      ];

      const result = await new StreamBuilder()
        .filter((chunk) => (chunk.choices[0]?.delta?.content?.length ?? 0) > 1)
        .execute(mockStream(chunks));

      expect(result.content).toBe('bbccc');
      expect(result.chunks).toBe(2);
    });
  });

  describe('map helper', () => {
    it('should transform chunks', async () => {
      const chunks = [createMockChunk('test')];

      const result = await new StreamBuilder()
        .map((chunk) => ({
          ...chunk,
          choices: [{
            ...chunk.choices[0],
            delta: {
              ...chunk.choices[0].delta,
              content: `[${chunk.choices[0].delta.content}]`,
            },
          }],
        }))
        .execute(mockStream(chunks));

      expect(result.content).toBe('[test]');
    });
  });

  describe('maxChunks', () => {
    it('should limit number of chunks processed', async () => {
      const chunks = [
        createMockChunk('1'),
        createMockChunk('2'),
        createMockChunk('3'),
        createMockChunk('4'),
        createMockChunk('5'),
      ];

      const result = await new StreamBuilder()
        .maxChunks(3)
        .execute(mockStream(chunks));

      expect(result.chunks).toBe(3);
      expect(result.content).toBe('123');
      expect(result.aborted).toBe(true);
    });
  });

  describe('fluent API', () => {
    it('should support method chaining', async () => {
      const chunks = [createMockChunk('test', 'stop')];
      const contentParts: string[] = [];

      const result = await StreamBuilder.create()
        .onContent((c) => contentParts.push(c))
        .onComplete(() => {})
        .maxChunks(10)
        .filter(() => true)
        .execute(mockStream(chunks));

      expect(result.content).toBe('test');
      expect(contentParts).toEqual(['test']);
    });
  });
});

describe('streamToMessage', () => {
  it('should convert stream to message', async () => {
    const chunks = [
      createMockChunk(undefined, null, 'assistant'),
      createMockChunk('Hello'),
      createMockChunk('!', 'stop'),
    ];

    const message = await streamToMessage(mockStream(chunks));

    expect(message.role).toBe('assistant');
    expect(message.content).toBe('Hello!');
  });

  it('should return empty content for empty stream', async () => {
    const message = await streamToMessage(mockStream([]));

    expect(message.role).toBe('assistant');
    expect(message.content).toBe('');
  });
});

describe('createTextAccumulator', () => {
  it('should accumulate text progressively', async () => {
    const chunks = [
      createMockChunk('A'),
      createMockChunk('B'),
      createMockChunk('C'),
    ];

    const accumulated: string[] = [];
    const builder = createTextAccumulator((text) => accumulated.push(text));

    await builder.execute(mockStream(chunks));

    expect(accumulated).toEqual(['A', 'AB', 'ABC']);
  });
});

describe('createTokenCounter', () => {
  it('should count tokens progressively', async () => {
    const chunks = [
      createMockChunk('Hello'), // ~2 tokens
      createMockChunk(' world'), // ~2 tokens
    ];

    const counts: number[] = [];
    const builder = createTokenCounter((count) => counts.push(count));

    await builder.execute(mockStream(chunks));

    expect(counts.length).toBe(2);
    expect(counts[1]).toBeGreaterThan(counts[0]);
  });
});

describe('teeStream', () => {
  it('should create two independent streams', async () => {
    const chunks = [
      createMockChunk('A'),
      createMockChunk('B'),
      createMockChunk('C'),
    ];

    const [stream1, stream2] = teeStream(mockStream(chunks));

    const result1 = await new StreamBuilder().execute(stream1);
    const result2 = await new StreamBuilder().execute(stream2);

    expect(result1.content).toBe('ABC');
    expect(result2.content).toBe('ABC');
  });
});
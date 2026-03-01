// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SSE Parser tests.
 */

import { SSEParser, type SSEEvent } from '../src/sse-parser.js';

describe('SSEParser', () => {
  describe('basic parsing', () => {
    it('should parse single data event', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('hello');
    });

    it('should parse multiple data events', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: first\n\ndata: second\n\n');

      expect(events).toHaveLength(2);
      expect(events[0].data).toBe('first');
      expect(events[1].data).toBe('second');
    });

    it('should handle chunked input', () => {
      const parser = new SSEParser();

      const events1 = parser.feed('data: hel');
      expect(events1).toHaveLength(0);

      const events2 = parser.feed('lo\n\n');
      expect(events2).toHaveLength(1);
      expect(events2[0].data).toBe('hello');
    });

    it('should parse JSON data', () => {
      const parser = new SSEParser();
      const json = '{"content": "hello"}';
      const events = parser.feed(`data: ${json}\n\n`);

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe(json);

      const parsed = JSON.parse(events[0].data);
      expect(parsed.content).toBe('hello');
    });
  });

  describe('line endings', () => {
    it('should handle \\n line endings', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: test\n\n');

      expect(events).toHaveLength(1);
    });

    it('should handle \\r\\n line endings', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: test\r\n\r\n');

      expect(events).toHaveLength(1);
    });

    it('should handle \\r line endings', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: test\r\r');

      expect(events).toHaveLength(1);
    });

    it('should handle mixed line endings', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: one\n\ndata: two\r\n\r\ndata: three\r\r');

      expect(events).toHaveLength(3);
    });
  });

  describe('multi-line data', () => {
    it('should combine multiple data lines', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: line1\ndata: line2\ndata: line3\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('line1\nline2\nline3');
    });

    it('should handle empty data lines', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: \ndata: hello\ndata: \n\n');

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('\nhello\n');
    });
  });

  describe('event field', () => {
    it('should parse event type', () => {
      const parser = new SSEParser();
      const events = parser.feed('event: message\ndata: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].event).toBe('message');
      expect(events[0].data).toBe('hello');
    });

    it('should handle event without data', () => {
      const parser = new SSEParser();
      const events = parser.feed('event: ping\n\n');

      // No data = no event dispatched
      expect(events).toHaveLength(0);
    });

    it('should reset event for each dispatch', () => {
      const parser = new SSEParser();
      const events = parser.feed('event: first\ndata: 1\n\ndata: 2\n\n');

      expect(events).toHaveLength(2);
      expect(events[0].event).toBe('first');
      expect(events[1].event).toBeUndefined();
    });
  });

  describe('id field', () => {
    it('should parse event id', () => {
      const parser = new SSEParser();
      const events = parser.feed('id: 123\ndata: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].id).toBe('123');
    });

    it('should persist id across events', () => {
      const parser = new SSEParser();
      const events = parser.feed('id: 1\ndata: first\n\ndata: second\n\n');

      expect(events).toHaveLength(2);
      expect(events[0].id).toBe('1');
      expect(events[1].id).toBe('1'); // Persisted from previous
    });

    it('should update id when new one provided', () => {
      const parser = new SSEParser();
      const events = parser.feed('id: 1\ndata: first\n\nid: 2\ndata: second\n\n');

      expect(events).toHaveLength(2);
      expect(events[0].id).toBe('1');
      expect(events[1].id).toBe('2');
    });

    it('should track last event id', () => {
      const parser = new SSEParser();
      parser.feed('id: 123\ndata: test\n\n');

      expect(parser.getLastEventId()).toBe('123');
    });
  });

  describe('retry field', () => {
    it('should parse retry value', () => {
      const parser = new SSEParser();
      const events = parser.feed('retry: 5000\ndata: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].retry).toBe(5000);
    });

    it('should ignore invalid retry values', () => {
      const parser = new SSEParser();
      const events = parser.feed('retry: invalid\ndata: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].retry).toBeUndefined();
    });

    it('should ignore negative retry values', () => {
      const parser = new SSEParser();
      const events = parser.feed('retry: -100\ndata: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].retry).toBeUndefined();
    });
  });

  describe('comments', () => {
    it('should ignore comment lines', () => {
      const parser = new SSEParser();
      const events = parser.feed(': this is a comment\ndata: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('hello');
    });

    it('should handle standalone comments', () => {
      const parser = new SSEParser();
      const events = parser.feed(': comment only\n\n');

      expect(events).toHaveLength(0);
    });

    it('should handle comments between events', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: first\n\n: comment\n\ndata: second\n\n');

      expect(events).toHaveLength(2);
    });
  });

  describe('field value handling', () => {
    it('should remove leading space from value', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: hello\n\n');

      expect(events[0].data).toBe('hello');
    });

    it('should handle field without colon', () => {
      const parser = new SSEParser();
      const events = parser.feed('data\n\n');

      // data field with empty value
      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('');
    });

    it('should handle field with empty value', () => {
      const parser = new SSEParser();
      const events = parser.feed('data:\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('');
    });

    it('should handle colon in value', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: key: value\n\n');

      expect(events[0].data).toBe('key: value');
    });

    it('should ignore unknown fields', () => {
      const parser = new SSEParser();
      const events = parser.feed('unknown: value\ndata: hello\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('hello');
      expect((events[0] as { unknown?: string }).unknown).toBeUndefined();
    });
  });

  describe('flush', () => {
    it('should flush pending data', () => {
      const parser = new SSEParser();
      parser.feed('data: incomplete');
      const event = parser.flush();

      expect(event).toBeDefined();
      expect(event!.data).toBe('incomplete');
    });

    it('should return undefined if no pending data', () => {
      const parser = new SSEParser();
      const event = parser.flush();

      expect(event).toBeUndefined();
    });

    it('should clear buffer after flush', () => {
      const parser = new SSEParser();
      parser.feed('data: test');
      parser.flush();
      const event = parser.flush();

      expect(event).toBeUndefined();
    });
  });

  describe('reset', () => {
    it('should clear all state', () => {
      const parser = new SSEParser();
      parser.feed('id: 123\ndata: partial');
      parser.reset();

      expect(parser.getLastEventId()).toBeUndefined();
      expect(parser.flush()).toBeUndefined();
    });
  });

  describe('callback mode', () => {
    it('should call onEvent callback', () => {
      const events: SSEEvent[] = [];
      const parser = new SSEParser((event) => events.push(event));

      parser.feed('data: hello\n\ndata: world\n\n');

      expect(events).toHaveLength(2);
    });
  });

  describe('vLLM streaming format', () => {
    it('should parse vLLM stream chunks', () => {
      const parser = new SSEParser();
      const chunk1 = '{"id":"cmpl-1","choices":[{"delta":{"content":"Hello"}}]}';
      const chunk2 = '{"id":"cmpl-1","choices":[{"delta":{"content":"!"}}]}';

      const events = parser.feed(`data: ${chunk1}\n\ndata: ${chunk2}\n\n`);

      expect(events).toHaveLength(2);

      const parsed1 = JSON.parse(events[0].data);
      expect(parsed1.choices[0].delta.content).toBe('Hello');

      const parsed2 = JSON.parse(events[1].data);
      expect(parsed2.choices[0].delta.content).toBe('!');
    });

    it('should parse [DONE] marker', () => {
      const parser = new SSEParser();
      const events = parser.feed('data: [DONE]\n\n');

      expect(events).toHaveLength(1);
      expect(events[0].data).toBe('[DONE]');
    });

    it('should handle complete vLLM stream', () => {
      const parser = new SSEParser();
      const stream = [
        'data: {"id":"1","choices":[{"delta":{"role":"assistant"}}]}\n\n',
        'data: {"id":"1","choices":[{"delta":{"content":"Hi"}}]}\n\n',
        'data: {"id":"1","choices":[{"delta":{"content":"!"}}]}\n\n',
        'data: {"id":"1","choices":[{"finish_reason":"stop"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      let allEvents: SSEEvent[] = [];
      for (const chunk of stream) {
        allEvents = allEvents.concat(parser.feed(chunk));
      }

      expect(allEvents).toHaveLength(5);
      expect(allEvents[4].data).toBe('[DONE]');
    });
  });
});
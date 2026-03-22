import { describe, expect, it } from 'vitest';
import { SacEventService } from '../libs/sac-core/src/lib/services/sac-event.service';

describe('SacEventService', () => {
  it('emits events that listeners receive via on()', () => {
    const service = new SacEventService();
    const received: unknown[] = [];

    service.on('click').subscribe((e) => received.push(e));
    service.emit('click', { x: 10, y: 20 });

    expect(received).toHaveLength(1);
    expect(received[0]).toEqual({ type: 'click', payload: { x: 10, y: 20 } });
  });

  it('filters events by type', () => {
    const service = new SacEventService();
    const clicks: unknown[] = [];
    const hovers: unknown[] = [];

    service.on('click').subscribe((e) => clicks.push(e));
    service.on('hover').subscribe((e) => hovers.push(e));

    service.emit('click', 'c1');
    service.emit('hover', 'h1');
    service.emit('click', 'c2');

    expect(clicks).toHaveLength(2);
    expect(hovers).toHaveLength(1);
  });

  it('onAny() receives all events', () => {
    const service = new SacEventService();
    const all: unknown[] = [];

    service.onAny().subscribe((e) => all.push(e));
    service.emit('a', 1);
    service.emit('b', 2);

    expect(all).toHaveLength(2);
  });

  it('emit without payload sends undefined', () => {
    const service = new SacEventService();
    const received: unknown[] = [];

    service.on('test').subscribe((e) => received.push(e));
    service.emit('test');

    expect(received[0]).toEqual({ type: 'test', payload: undefined });
  });
});

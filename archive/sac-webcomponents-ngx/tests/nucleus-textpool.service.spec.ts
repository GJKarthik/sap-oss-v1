import { describe, expect, it } from 'vitest';
import { NucleusTextPoolService } from '../libs/sac-builtins/src/lib/services/nucleus-textpool.service';

describe('NucleusTextPoolService', () => {
  it('defaults to English', () => {
    const service = new NucleusTextPoolService();
    expect(service.getLanguage()).toBe('en');
  });

  it('sets and gets language', () => {
    const service = new NucleusTextPoolService();
    service.setLanguage('de');
    expect(service.getLanguage()).toBe('de');
  });

  it('stores and retrieves text entries', () => {
    const service = new NucleusTextPoolService();
    service.set('greeting', 'Hello');
    expect(service.get('greeting')).toBe('Hello');
  });

  it('returns key as fallback when entry not found', () => {
    const service = new NucleusTextPoolService();
    expect(service.get('missing_key')).toBe('missing_key');
  });

  it('supports multi-language entries', () => {
    const service = new NucleusTextPoolService();
    service.set('greeting', 'Hello', 'en');
    service.set('greeting', 'Hallo', 'de');

    expect(service.get('greeting', 'en')).toBe('Hello');
    expect(service.get('greeting', 'de')).toBe('Hallo');
  });

  it('loadEntries loads a batch', () => {
    const service = new NucleusTextPoolService();
    service.loadEntries([
      { key: 'a', value: 'Alpha', language: 'en' },
      { key: 'b', value: 'Beta', language: 'en' },
    ]);
    expect(service.get('a')).toBe('Alpha');
    expect(service.get('b')).toBe('Beta');
  });

  it('getAll returns entries for current language', () => {
    const service = new NucleusTextPoolService();
    service.set('a', 'A', 'en');
    service.set('b', 'B', 'de');

    const enEntries = service.getAll('en');
    expect(enEntries).toHaveLength(1);
    expect(enEntries[0].key).toBe('a');
  });

  it('clear removes all entries', () => {
    const service = new NucleusTextPoolService();
    service.set('a', 'A');
    service.clear();
    expect(service.get('a')).toBe('a'); // fallback
  });
});

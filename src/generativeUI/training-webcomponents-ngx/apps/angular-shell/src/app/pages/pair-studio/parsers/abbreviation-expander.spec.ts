import { expandColumnName, stripSapPrefix, splitIdentifier, expandToken } from './abbreviation-expander';

describe('expandColumnName', () => {
  it('should expand simple abbreviations', () => {
    const result = expandColumnName('AMT');
    expect(result.naturalName.toLowerCase()).toContain('amount');
    expect(result.confidence).toBe(1.0);
    expect(result.unknownTokens).toHaveLength(0);
  });

  it('should expand underscore-separated names', () => {
    const result = expandColumnName('CUST_INV_AMT');
    expect(result.naturalName.toLowerCase()).toContain('customer');
    expect(result.naturalName.toLowerCase()).toContain('amount');
  });

  it('should strip SAP prefixes', () => {
    const result = expandColumnName('ZZAP_FIELD_NAME');
    expect(result.naturalName.toLowerCase()).not.toMatch(/^zz/);
  });

  it('should handle camelCase input', () => {
    const result = expandColumnName('accountBalance');
    expect(result.naturalName.toLowerCase()).toContain('account');
    expect(result.naturalName.toLowerCase()).toContain('balance');
  });

  it('should handle already readable names', () => {
    const result = expandColumnName('TOTAL_REVENUE');
    expect(result.naturalName.toLowerCase()).toContain('total');
    expect(result.naturalName.toLowerCase()).toContain('revenue');
  });

  it('should return non-empty naturalName for any non-empty input', () => {
    expect(expandColumnName('X').naturalName.length).toBeGreaterThan(0);
  });

  it('should expand common financial abbreviations', () => {
    const result = expandColumnName('GL_ACCT_NBR');
    expect(result.naturalName.toLowerCase()).toContain('general ledger');
  });

  it('should expand DT/TM suffixes', () => {
    const result = expandColumnName('CREATED_DT');
    expect(result.naturalName.toLowerCase()).toContain('date');
  });

  it('should reduce confidence for unknown tokens', () => {
    const result = expandColumnName('XYZ_AMT');
    expect(result.confidence).toBeLessThan(1.0);
    expect(result.unknownTokens.length).toBeGreaterThan(0);
  });
});

describe('stripSapPrefix', () => {
  it('should strip /BIC/ prefix', () => {
    expect(stripSapPrefix('/BIC/ZREVENUE')).toBe('REVENUE');
  });

  it('should strip /BI0/ prefix', () => {
    expect(stripSapPrefix('/BI0/0MATERIAL')).toBe('MATERIAL');
  });

  it('should strip leading zeros', () => {
    expect(stripSapPrefix('0COSTCENTER')).toBe('COSTCENTER');
  });

  it('should strip leading Z custom indicator', () => {
    expect(stripSapPrefix('ZREVENUE')).toBe('REVENUE');
  });
});

describe('splitIdentifier', () => {
  it('should split on underscores', () => {
    expect(splitIdentifier('ACCOUNT_BALANCE')).toEqual(['ACCOUNT', 'BALANCE']);
  });

  it('should split camelCase', () => {
    expect(splitIdentifier('accountBalance')).toEqual(['account', 'Balance']);
  });
});

describe('expandToken', () => {
  it('should expand known abbreviations', () => {
    const result = expandToken('AMT');
    expect(result.expanded).toBe('Amount');
    expect(result.known).toBe(true);
  });

  it('should flag unknown short tokens', () => {
    const result = expandToken('XQ');
    expect(result.known).toBe(false);
  });

  it('should accept full English words as known', () => {
    const result = expandToken('Revenue');
    expect(result.known).toBe(true);
  });
});

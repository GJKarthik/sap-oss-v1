import { parseDdl } from './ddl-parser';

describe('parseDdl', () => {
  it('should parse a basic CREATE TABLE statement', () => {
    const ddl = `
      CREATE TABLE BANK_ACCOUNTS (
        ACCOUNT_ID INTEGER NOT NULL,
        ACCOUNT_NAME VARCHAR(100),
        BALANCE DECIMAL(15,2),
        CREATED_AT TIMESTAMP
      );
    `;
    const result = parseDdl(ddl, 'test.sql');

    expect(result.errors).toHaveLength(0);
    expect(result.termPairs.length).toBe(4);

    const accountId = result.termPairs.find(t => t.sourceTerm === 'ACCOUNT_ID');
    expect(accountId).toBeDefined();
    expect(accountId!.pairType).toBe('db_field_mapping');
    expect(accountId!.dbContext?.tableName).toBe('BANK_ACCOUNTS');
    expect(accountId!.dbContext?.dataType).toContain('INTEGER');
  });

  it('should parse HANA column table SQL format', () => {
    const ddl = `
      CREATE COLUMN TABLE "SCHEMA"."GL_LEDGER" (
        "LEDGER_ID" NVARCHAR(10) NOT NULL,
        "COMPANY_CODE" NVARCHAR(4),
        "FISCAL_YEAR" INTEGER,
        PRIMARY KEY ("LEDGER_ID")
      );
    `;
    const result = parseDdl(ddl, 'GL_LEDGER.sql');

    expect(result.errors).toHaveLength(0);
    expect(result.termPairs.length).toBe(3);

    const companyCode = result.termPairs.find(t => t.sourceTerm === 'COMPANY_CODE');
    expect(companyCode).toBeDefined();
    expect(companyCode!.pairType).toBe('db_field_mapping');
  });

  it('should parse .hdbtable JSON format', () => {
    const ddl = JSON.stringify({
      schemaName: "SCHEMA",
      tableType: "GL_LEDGER",
      columns: [
        { name: "LEDGER_ID", sqlType: "NVARCHAR", length: 10 },
        { name: "COMPANY_CODE", sqlType: "NVARCHAR", length: 4 },
        { name: "FISCAL_YEAR", sqlType: "INTEGER" }
      ]
    });
    const result = parseDdl(ddl, 'GL_LEDGER.hdbtable');

    expect(result.errors).toHaveLength(0);
    expect(result.termPairs.length).toBe(3);
    expect(result.termPairs[0].pairType).toBe('db_field_mapping');
  });

  it('should expand abbreviations in target terms', () => {
    const ddl = `
      CREATE TABLE INVOICE_HDR (
        INV_AMT DECIMAL(15,2),
        CUST_NM VARCHAR(100)
      );
    `;
    const result = parseDdl(ddl, 'test.sql');

    const invAmt = result.termPairs.find(t => t.sourceTerm === 'INV_AMT');
    expect(invAmt).toBeDefined();
    expect(invAmt!.targetTerm.length).toBeGreaterThan(0);
    expect(invAmt!.targetTerm).not.toBe('INV_AMT');
  });

  it('should set confidence from abbreviation expander', () => {
    const ddl = `CREATE TABLE T (ACCOUNT_BALANCE DECIMAL);`;
    const result = parseDdl(ddl, 'test.sql');

    // Known tokens → high confidence
    expect(result.termPairs.length).toBe(1);
    expect(result.termPairs[0].confidence).toBeGreaterThanOrEqual(0.5);
  });

  it('should return errors for empty/invalid DDL', () => {
    const result = parseDdl('', 'empty.sql');
    expect(result.termPairs).toHaveLength(0);
  });

  it('should handle multiple CREATE TABLE statements', () => {
    const ddl = `
      CREATE TABLE ACCOUNTS (ACCOUNT_ID INTEGER);
      CREATE TABLE INVOICES (INVOICE_AMT VARCHAR(10), CUST_NM DECIMAL);
    `;
    const result = parseDdl(ddl, 'multi.sql');
    expect(result.termPairs.length).toBe(3);
  });

  it('should skip PRIMARY KEY and CONSTRAINT lines', () => {
    const ddl = `
      CREATE TABLE T (
        ID INTEGER NOT NULL,
        PRIMARY KEY (ID),
        CONSTRAINT chk_id CHECK (ID > 0)
      );
    `;
    const result = parseDdl(ddl, 'test.sql');
    const hasPk = result.termPairs.some(t =>
      t.sourceTerm.toUpperCase().includes('PRIMARY')
    );
    expect(hasPk).toBe(false);
  });
});

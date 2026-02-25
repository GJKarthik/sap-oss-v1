# SQL Injection Audit Report — cap-llm-plugin

**Date:** Day 1  
**Auditor:** Cascade  
**Scope:** All files in `cap-llm-plugin-main/` that execute SQL via `cds.db.run()` or `db.run()`  
**Files audited:** `srv/cap-llm-plugin.js`, `lib/anonymization-helper.js`, `cds-plugin.js`

---

## Executive Summary

**12 SQL execution points** were identified across 2 files. Of these:

- 🔴 **4 are Critical** — user-supplied values directly interpolated into SQL strings
- 🟠 **5 are High** — CDS-metadata-derived values interpolated into DDL (lower exploit risk but still unsafe)
- 🟡 **3 are Medium** — derived identifiers interpolated but constrained by upstream logic

No parameterized queries (`cds.run(query, params)`) are used anywhere in the codebase.

---

## Finding Details

### File 1: `srv/cap-llm-plugin.js`

#### FINDING #1 — 🔴 CRITICAL: `getAnonymizedData()` — sequenceIds injection

**Lines 42–45:**
```javascript
query += `where "${sequenceColumn?.name?.toUpperCase()}" in (${sequenceIds
  .map((value) => `'${value}'`)
  .join(", ")});`;
```

- **Tainted input:** `sequenceIds` parameter — caller-supplied `number[]` (documented) but **no type validation**
- **Attack vector:** If a caller passes `["1' OR '1'='1"]` as sequenceIds, the resulting SQL becomes:
  ```sql
  select * from "VIEW_NAME" where "COL" in ('1' OR '1'='1');
  ```
- **Impact:** Full read access to the anonymized view, bypassing intended row filtering
- **Fix:** Use parameterized query: `cds.db.run(query, sequenceIds)` with `?` placeholders

#### FINDING #2 — 🟡 MEDIUM: `getAnonymizedData()` — viewName from entityName

**Lines 38–40:**
```javascript
const viewName = entityName.toUpperCase().replace(/\./g, "_") + "_ANOMYZ_V";
let query = `select * from "${viewName}"\n`;
```

- **Tainted input:** `entityName` parameter — string from caller
- **Mitigation present:** Double-quoted identifier limits injection scope; `.toUpperCase().replace(/\./g, "_")` removes dots
- **Residual risk:** A crafted `entityName` containing `"` (double-quote) could break out: `entityName = 'FOO" UNION SELECT * FROM SECRETS --'`
- **Fix:** Validate `entityName` against `cds.services` entity registry before use (partially done on line 27 but the lookup result isn't used to guard the SQL)

#### FINDING #3 — 🔴 CRITICAL: `similaritySearch()` — multiple injections in one statement

**Lines 644–645:**
```javascript
const embedding_str = `'[${embedding.toString()}]'`
const selectStmt = `SELECT TOP ${topK} *,TO_NVARCHAR(${contentColumn}) as PAGE_CONTENT,${algoName}(${embeddingColumnName}, TO_REAL_VECTOR(${embedding_str})) as SCORE FROM ${tableName} ORDER BY SCORE ${sortDirection}`;
```

**6 interpolated values in a single SQL statement:**

| Variable | Source | Type Check | Injection Risk |
|----------|--------|------------|----------------|
| `topK` | Caller param, default `3` | None — could be string | 🔴 **Critical** — `topK = "1; DROP TABLE foo --"` |
| `contentColumn` | Caller param | None | 🔴 **Critical** — unquoted identifier, full injection |
| `algoName` | Caller param, whitelist-checked | ✅ Validated on line 634 | ✅ Safe |
| `embeddingColumnName` | Caller param | None | 🔴 **Critical** — unquoted identifier, full injection |
| `embedding_str` | From `embedding.toString()` | None | 🟡 Medium — numeric array, but `.toString()` on a malicious object could return SQL |
| `tableName` | Caller param | None | 🔴 **Critical** — unquoted identifier, full injection |
| `sortDirection` | Derived from `algoName` | ✅ Constrained to "ASC"/"DESC" | ✅ Safe |

- **Attack vector (tableName):** `tableName = "MY_TABLE; DROP TABLE USERS --"` → arbitrary SQL execution
- **Attack vector (topK):** `topK = "1 UNION SELECT * FROM SENSITIVE_TABLE --"` → data exfiltration
- **Impact:** Arbitrary SQL execution including DDL (DROP, CREATE) and full data exfiltration
- **Fix:** 
  - Quote all identifiers with double-quotes and validate against metadata
  - Validate `topK` is a positive integer: `Number.isInteger(topK) && topK > 0`
  - Use parameterized query for the embedding vector value

---

### File 2: `lib/anonymization-helper.js`

#### FINDING #4 — 🟠 HIGH: `createAnonymizedView()` — view existence check

**Line 3:**
```javascript
let viewExists = await cds.db.run(`SELECT count(1) as "count" FROM SYS.VIEWS where VIEW_NAME='${view_name}' and SCHEMA_NAME='${schemaName}'`);
```

- **Tainted inputs:** `view_name` (derived from `entityName`), `schemaName` (from `cds.db` credentials)
- **Source:** `view_name` comes from `entityName.toUpperCase().replace(/\./g, '_') + '_ANOMYZ_V'`; `schemaName` from `srv.options.credentials.schema`
- **Risk:** `schemaName` is from service binding (trusted), but `entityName` originates from CDS model annotations — **medium trust**. A malicious CDS model with `entity "foo'; DROP TABLE bar --"` could inject.
- **Fix:** Use parameterized query: `cds.db.run("SELECT count(1) as \"count\" FROM SYS.VIEWS WHERE VIEW_NAME=? AND SCHEMA_NAME=?", [view_name, schemaName])`

#### FINDING #5 — 🟠 HIGH: `createAnonymizedView()` — DROP VIEW

**Line 8:**
```javascript
await cds.db.run(`drop view "${view_name}"`);
```

- **Tainted input:** `view_name` — derived from entity name
- **Risk:** Double-quoted identifier limits risk, but a `"` in the entity name breaks out
- **Fix:** Validate `view_name` with allowlist regex: `/^[A-Z0-9_]+$/`

#### FINDING #6 — 🟠 HIGH: `createAnonymizedView()` — CREATE VIEW with DDL injection

**Lines 18–20:**
```javascript
anonymizedViewQuery += ` CREATE VIEW "${view_name}" AS SELECT ${Object.keys(anonymizedElements).map(item => `"${item.toUpperCase()}"`).join(", ")}`;
anonymizedViewQuery += ` FROM "${entityViewName}" \n WITH ANONYMIZATION  (${anonymizeAlgorithm}\n`;
for (let [key, value] of Object.entries(anonymizedElements)) { anonymizedViewQuery += `COLUMN "${key.toUpperCase()}" PARAMETERS '${value}'\n`; }
```

**5 interpolated values in DDL:**

| Variable | Source | Risk |
|----------|--------|------|
| `view_name` | Derived from entityName | 🟠 High — double-quoted but breakable |
| Column names from `anonymizedElements` keys | CDS model `@anonymize` element names | 🟠 High — double-quoted but breakable |
| `entityViewName` | Derived from entityName | 🟠 High — double-quoted but breakable |
| `anonymizeAlgorithm` | CDS `@anonymize` annotation value | 🔴 **Critical** — unquoted, directly in DDL |
| `value` in PARAMETERS clause | CDS `@anonymize` element annotation values | 🟠 High — single-quoted, breakable with `'` |

- **Attack vector (anonymizeAlgorithm):** A malicious CDS model annotation `@anonymize: "ALGORITHM 'K-ANONYMITY' ); DROP TABLE USERS; --"` → arbitrary DDL execution
- **Impact:** Full DDL execution on HANA (CREATE/DROP tables, views)
- **Fix:** Validate `anonymizeAlgorithm` against a whitelist of known algorithms; validate all identifiers with regex

#### FINDING #7 — 🟡 MEDIUM: `createAnonymizedView()` — REFRESH VIEW

**Line 34:**
```javascript
await cds.db.run(`REFRESH VIEW "${view_name}" ANONYMIZATION`);
```

- **Tainted input:** `view_name` — same as Finding #5
- **Fix:** Same identifier validation as Finding #5

---

## Summary Table

| # | File | Line(s) | Severity | Tainted Input | SQL Type | Parameterizable? |
|---|------|---------|----------|---------------|----------|-----------------|
| 1 | `srv/cap-llm-plugin.js` | 42–45 | 🔴 Critical | `sequenceIds` (caller) | SELECT WHERE IN | ✅ Yes |
| 2 | `srv/cap-llm-plugin.js` | 38–40 | 🟡 Medium | `entityName` (caller) | SELECT FROM | Validate against CDS registry |
| 3a | `srv/cap-llm-plugin.js` | 645 | 🔴 Critical | `tableName` (caller) | SELECT FROM | Validate identifier |
| 3b | `srv/cap-llm-plugin.js` | 645 | 🔴 Critical | `contentColumn` (caller) | SELECT column | Validate identifier |
| 3c | `srv/cap-llm-plugin.js` | 645 | 🔴 Critical | `embeddingColumnName` (caller) | SELECT column / function arg | Validate identifier |
| 3d | `srv/cap-llm-plugin.js` | 645 | 🔴 Critical | `topK` (caller) | SELECT TOP | ✅ Yes — validate integer |
| 3e | `srv/cap-llm-plugin.js` | 644 | 🟡 Medium | `embedding` (from SDK) | TO_REAL_VECTOR arg | ✅ Yes — validate numeric array |
| 4 | `lib/anonymization-helper.js` | 3 | 🟠 High | `view_name`, `schemaName` | SELECT WHERE | ✅ Yes |
| 5 | `lib/anonymization-helper.js` | 8 | 🟠 High | `view_name` | DROP VIEW | Validate identifier |
| 6a | `lib/anonymization-helper.js` | 18–19 | 🟠 High | `view_name`, column names, `entityViewName` | CREATE VIEW | Validate identifiers |
| 6b | `lib/anonymization-helper.js` | 19 | 🔴 Critical | `anonymizeAlgorithm` | DDL clause | Whitelist validation |
| 6c | `lib/anonymization-helper.js` | 20 | 🟠 High | annotation `value` | PARAMETERS clause | Escape single quotes |
| 7 | `lib/anonymization-helper.js` | 34 | 🟡 Medium | `view_name` | REFRESH VIEW | Validate identifier |

---

## Recommended Fix Strategy

### Priority 1 — Parameterize value inputs (Day 2)
These can use `cds.db.run(query, params)` with `?` placeholders:
- **Finding #1:** `sequenceIds` in `getAnonymizedData()` → use `WHERE col IN (?, ?, ?)`
- **Finding #4:** `view_name` and `schemaName` in existence check → use `WHERE VIEW_NAME=? AND SCHEMA_NAME=?`

### Priority 2 — Validate and sanitize identifiers (Day 2–3)
These are SQL identifiers (table/column/view names) that cannot use `?` parameters:
- Create a shared `validateSqlIdentifier(name)` function that:
  1. Checks against regex `/^[A-Za-z_][A-Za-z0-9_]*$/`
  2. Throws `InvalidIdentifierError` on failure
  3. Always wraps in double-quotes for safe quoting
- Apply to: `tableName`, `contentColumn`, `embeddingColumnName`, `view_name`, `entityViewName`, column names
- **Finding #3d:** Validate `topK` is a positive integer with `Number.isInteger(topK) && topK > 0 && topK <= 1000`

### Priority 3 — Whitelist DDL values (Day 3)
- **Finding #6b:** Validate `anonymizeAlgorithm` against known HANA algorithms: `['K-ANONYMITY', 'L-DIVERSITY', 'DIFFERENTIAL-PRIVACY']` (or a broader HANA-specific list)
- **Finding #6c:** Escape single quotes in annotation values: `value.replace(/'/g, "''")`

### Priority 4 — Validate embedding vector (Day 2)
- **Finding #3e:** Validate `embedding` is an array of numbers before `.toString()`:
  ```javascript
  if (!Array.isArray(embedding) || !embedding.every(v => typeof v === 'number' && isFinite(v))) {
    throw new Error('Embedding must be an array of finite numbers');
  }
  ```

---

## Files Modified by This Audit

None — this is a read-only audit. Fixes will be applied on Days 2–3.

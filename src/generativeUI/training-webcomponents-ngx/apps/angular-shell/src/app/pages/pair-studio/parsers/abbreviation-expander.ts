/**
 * Abbreviation Expander — converts SAP/HANA column names to natural language.
 *
 * Strategy:
 *  1. Strip SAP BW namespace prefixes (/BIC/, /BI0/, leading 0)
 *  2. Split on underscore / camelCase boundaries
 *  3. Expand each token via a known abbreviation lookup table
 *  4. Title-case the result
 *
 * Tokens that cannot be expanded are kept as-is and flagged
 * with reduced confidence (0.6 instead of 1.0).
 */

const ABBREVIATION_MAP: Record<string, string> = {
  ACCT: 'Account',
  ADDR: 'Address',
  ADJ: 'Adjusted',
  AMT: 'Amount',
  APPR: 'Approval',
  AUTH: 'Authorization',
  AVG: 'Average',
  BAL: 'Balance',
  BNK: 'Bank',
  BR: 'Branch',
  BUS: 'Business',
  CAT: 'Category',
  CD: 'Code',
  CHG: 'Charge',
  CLS: 'Class',
  CNTRY: 'Country',
  COMP: 'Company',
  CONF: 'Configuration',
  CR: 'Credit',
  CRD: 'Card',
  CREAT: 'Created',
  CURR: 'Currency',
  CUST: 'Customer',
  CUST_GRP: 'Customer Group',
  DB: 'Debit',
  DEL: 'Delivery',
  DEPT: 'Department',
  DESC: 'Description',
  DIST: 'Distribution',
  DIV: 'Division',
  DOC: 'Document',
  DR: 'Debit',
  DT: 'Date',
  DUR: 'Duration',
  EFF: 'Effective',
  EMP: 'Employee',
  EXCH: 'Exchange',
  EXP: 'Expiry',
  EXT: 'External',
  FLG: 'Flag',
  FIN: 'Financial',
  FISC: 'Fiscal',
  FLD: 'Field',
  FRM: 'From',
  FY: 'Fiscal Year',
  GL: 'General Ledger',
  GRP: 'Group',
  HDR: 'Header',
  ID: 'ID',
  IDX: 'Index',
  IND: 'Indicator',
  INT: 'Interest',
  INV: 'Invoice',
  ITM: 'Item',
  KEY: 'Key',
  LBL: 'Label',
  LGR: 'Ledger',
  LN: 'Line',
  LOC: 'Location',
  LVL: 'Level',
  MATL: 'Material',
  MAX: 'Maximum',
  MGR: 'Manager',
  MIN: 'Minimum',
  MOD: 'Modified',
  MTH: 'Month',
  NBR: 'Number',
  NM: 'Name',
  NO: 'Number',
  NUM: 'Number',
  ORD: 'Order',
  ORG: 'Organization',
  OVR: 'Override',
  PAY: 'Payment',
  PCT: 'Percent',
  PD: 'Period',
  PER: 'Period',
  PH: 'Phone',
  PKG: 'Package',
  PO: 'Purchase Order',
  POST: 'Posting',
  PREV: 'Previous',
  PRC: 'Price',
  PROD: 'Product',
  PROJ: 'Project',
  PUR: 'Purchase',
  QTY: 'Quantity',
  REF: 'Reference',
  REG: 'Region',
  REJ: 'Rejected',
  REQ: 'Request',
  RET: 'Return',
  REV: 'Revenue',
  RTE: 'Rate',
  SLS: 'Sales',
  SRC: 'Source',
  ST: 'Status',
  STAT: 'Status',
  STK: 'Stock',
  STR: 'Street',
  SUB: 'Sub',
  TAX: 'Tax',
  TGT: 'Target',
  TM: 'Time',
  TOT: 'Total',
  TRX: 'Transaction',
  TYP: 'Type',
  UNT: 'Unit',
  UPD: 'Updated',
  USR: 'User',
  VAL: 'Value',
  VND: 'Vendor',
  VOL: 'Volume',
  WHS: 'Warehouse',
  WK: 'Week',
  YR: 'Year',
};

export interface ExpansionResult {
  naturalName: string;
  confidence: number;
  unknownTokens: string[];
}

/**
 * Strip SAP BW namespace prefixes common in HANA schemas.
 * /BIC/ZREVENUE → ZREVENUE, /BI0/0MATERIAL → MATERIAL, 0COSTCENTER → COSTCENTER
 */
export function stripSapPrefix(columnName: string): string {
  let name = columnName;
  name = name.replace(/^\/BIC\//, '');
  name = name.replace(/^\/BI0\//, '');
  name = name.replace(/^0+/, '');
  // Also strip leading Z (custom indicator in BW)
  if (name.length > 1 && name.startsWith('Z')) {
    name = name.substring(1);
  }
  return name || columnName;
}

/**
 * Split an identifier into tokens at underscores and camelCase boundaries.
 */
export function splitIdentifier(identifier: string): string[] {
  // First split on underscores
  const parts = identifier.split('_').filter(Boolean);
  const tokens: string[] = [];
  for (const part of parts) {
    // Split camelCase: insertBefore uppercase letters that follow lowercase
    const camelParts = part.replace(/([a-z])([A-Z])/g, '$1_$2').split('_');
    tokens.push(...camelParts.filter(Boolean));
  }
  return tokens;
}

/**
 * Expand a single token using the abbreviation lookup.
 */
export function expandToken(token: string): { expanded: string; known: boolean } {
  const upper = token.toUpperCase();
  if (ABBREVIATION_MAP[upper]) {
    return { expanded: ABBREVIATION_MAP[upper], known: true };
  }
  // If it's already a full English word (>= 4 chars, all alpha), keep it title-cased
  if (/^[a-zA-Z]{4,}$/.test(token)) {
    return {
      expanded: token.charAt(0).toUpperCase() + token.slice(1).toLowerCase(),
      known: true,
    };
  }
  // Unknown abbreviation — title-case it but flag
  return {
    expanded: token.charAt(0).toUpperCase() + token.slice(1).toLowerCase(),
    known: false,
  };
}

/**
 * Expand a full column/field name to natural language.
 */
export function expandColumnName(columnName: string): ExpansionResult {
  const stripped = stripSapPrefix(columnName);
  const tokens = splitIdentifier(stripped);
  const unknownTokens: string[] = [];
  const expandedParts: string[] = [];

  for (const token of tokens) {
    const { expanded, known } = expandToken(token);
    expandedParts.push(expanded);
    if (!known) {
      unknownTokens.push(token);
    }
  }

  const naturalName = expandedParts.join(' ');
  const confidence = tokens.length === 0
    ? 0.5
    : unknownTokens.length === 0
      ? 1.0
      : Math.max(0.5, 1.0 - (unknownTokens.length / tokens.length) * 0.4);

  return { naturalName, confidence, unknownTokens };
}

/** Expose the abbreviation map for testing/extension. */
export const KNOWN_ABBREVIATIONS = ABBREVIATION_MAP;

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import * as cds from "@sap/cds";
const { validateSqlIdentifier } = require("./validation-utils");

/** Map of element names to their @anonymize annotation parameter values. */
export interface AnonymizedElements {
  [elementName: string]: string;
}

/** Known SAP HANA Cloud anonymization algorithm type. */
export type AnonymizeAlgorithm = string;

/** Result row from SYS.VIEWS count query. */
interface ViewExistsRow {
  count: number;
}

/**
 * Known SAP HANA Cloud anonymization algorithm prefixes.
 * Used to whitelist the algorithm clause in CREATE VIEW ... WITH ANONYMIZATION.
 */
const VALID_ANONYMIZATION_ALGORITHM_PREFIXES: readonly string[] = [
  "ALGORITHM 'K-ANONYMITY'",
  "ALGORITHM 'L-DIVERSITY'",
  "ALGORITHM 'DIFFERENTIAL_PRIVACY'",
];

/**
 * Validates that the anonymization algorithm string starts with a known prefix.
 * This prevents DDL injection via the unquoted algorithm clause.
 *
 * @param algorithm - The algorithm clause from the @anonymize CDS annotation.
 * @throws If the algorithm does not match any known prefix.
 */
function validateAnonymizationAlgorithm(algorithm: unknown): asserts algorithm is string {
  if (typeof algorithm !== "string" || algorithm.trim().length === 0) {
    throw new Error("Invalid anonymization algorithm: must be a non-empty string.");
  }
  const normalized = algorithm.trim().toUpperCase();
  const isValid = VALID_ANONYMIZATION_ALGORITHM_PREFIXES.some((prefix) => normalized.startsWith(prefix.toUpperCase()));
  if (!isValid) {
    throw new Error(
      `Invalid anonymization algorithm: "${algorithm}". ` +
        `Must start with one of: ${VALID_ANONYMIZATION_ALGORITHM_PREFIXES.join(", ")}.`
    );
  }
}

/**
 * Escapes single quotes in a string value for use within SQL single-quoted literals.
 * Replaces each ' with '' (standard SQL escaping).
 *
 * @param value - The value to escape.
 * @returns The escaped value.
 */
function escapeSqlSingleQuote(value: unknown): string {
  if (typeof value !== "string") {
    throw new Error(`Invalid annotation value: must be a string. Received: ${typeof value}`);
  }
  return value.replace(/'/g, "''");
}

export async function createAnonymizedView(
  schemaName: string,
  entityName: string,
  anonymizeAlgorithm: AnonymizeAlgorithm,
  anonymizedElements: AnonymizedElements
): Promise<void> {
  // Validate inputs
  validateSqlIdentifier(schemaName, "schemaName");
  validateAnonymizationAlgorithm(anonymizeAlgorithm);

  const entityViewName: string = entityName.toUpperCase().replace(/\./g, "_");
  const viewName: string = entityViewName + "_ANOMYZ_V";

  // Validate derived identifiers
  validateSqlIdentifier(entityViewName, "entityViewName");
  validateSqlIdentifier(viewName, "viewName");

  // Validate all column names from anonymizedElements
  const columnNames: string[] = Object.keys(anonymizedElements);
  for (const colName of columnNames) {
    validateSqlIdentifier(colName.toUpperCase(), `anonymizedElement column "${colName}"`);
  }

  // Check if anonymized view already exists using parameterized query (Finding #4)
  const viewExists = (await cds.db.run(
    `SELECT count(1) as "count" FROM SYS.VIEWS WHERE VIEW_NAME = ? AND SCHEMA_NAME = ?`,
    [viewName, schemaName]
  )) as ViewExistsRow[];

  //check if anonymized view already exists. If already present, drop it.
  if (viewExists[0].count === 1) {
    try {
      // viewName is validated above — safe to use in double-quoted identifier (Finding #5)
      await cds.db.run(`DROP VIEW "${viewName}"`);
      console.log(`Anonymized view '${viewName}' dropped.`);
    } catch (e) {
      console.log(`Cannot drop view "${viewName}" . Error: `, e);
      throw e;
    }
  }
  console.log(`Creating anonymized view "${viewName}" in HANA.`);

  //Dynamically construct anonymization create view query and execute it
  // All identifiers are validated above; annotation values are escaped (Finding #6a, #6b, #6c)
  let anonymizedViewQuery: string = ` CREATE VIEW "${viewName}" AS SELECT ${columnNames.map((item) => `"${item.toUpperCase()}"`).join(", ")}`;
  anonymizedViewQuery += ` FROM "${entityViewName}" \n WITH ANONYMIZATION  (${anonymizeAlgorithm}\n`;
  for (const [key, value] of Object.entries(anonymizedElements)) {
    const escapedValue: string = escapeSqlSingleQuote(value);
    anonymizedViewQuery += `COLUMN "${key.toUpperCase()}" PARAMETERS '${escapedValue}'\n`;
  }

  anonymizedViewQuery += `)`;
  try {
    await cds.db.run(anonymizedViewQuery);
    console.log(`Anonymized view "${viewName}" created in HANA.`);
  } catch (e) {
    console.log(`Creating of anonymized view "${viewName}" failed. Error: `, e);
    throw e;
  }

  try {
    //refresh the anonymized view (Finding #7 — viewName validated above)
    await cds.db.run(`REFRESH VIEW "${viewName}" ANONYMIZATION`);
    console.log(`Refreshed Anonymized view "${viewName}" in HANA.`);
  } catch (e) {
    console.log(`Refreshing anonymized view "${viewName}" failed. Error: `, e);
    throw e;
  }
}

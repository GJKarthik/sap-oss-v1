// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.createAnonymizedView = createAnonymizedView;
const cds = __importStar(require("@sap/cds"));
const { validateSqlIdentifier } = require("./validation-utils");
/**
 * Known SAP HANA Cloud anonymization algorithm prefixes.
 * Used to whitelist the algorithm clause in CREATE VIEW ... WITH ANONYMIZATION.
 */
const VALID_ANONYMIZATION_ALGORITHM_PREFIXES = [
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
function validateAnonymizationAlgorithm(algorithm) {
    if (typeof algorithm !== "string" || algorithm.trim().length === 0) {
        throw new Error("Invalid anonymization algorithm: must be a non-empty string.");
    }
    const normalized = algorithm.trim().toUpperCase();
    const isValid = VALID_ANONYMIZATION_ALGORITHM_PREFIXES.some((prefix) => normalized.startsWith(prefix.toUpperCase()));
    if (!isValid) {
        throw new Error(`Invalid anonymization algorithm: "${algorithm}". ` +
            `Must start with one of: ${VALID_ANONYMIZATION_ALGORITHM_PREFIXES.join(", ")}.`);
    }
}
/**
 * Escapes single quotes in a string value for use within SQL single-quoted literals.
 * Replaces each ' with '' (standard SQL escaping).
 *
 * @param value - The value to escape.
 * @returns The escaped value.
 */
function escapeSqlSingleQuote(value) {
    if (typeof value !== "string") {
        throw new Error(`Invalid annotation value: must be a string. Received: ${typeof value}`);
    }
    return value.replace(/'/g, "''");
}
async function createAnonymizedView(schemaName, entityName, anonymizeAlgorithm, anonymizedElements) {
    // Validate inputs
    validateSqlIdentifier(schemaName, "schemaName");
    validateAnonymizationAlgorithm(anonymizeAlgorithm);
    const entityViewName = entityName.toUpperCase().replace(/\./g, "_");
    const viewName = entityViewName + "_ANOMYZ_V";
    // Validate derived identifiers
    validateSqlIdentifier(entityViewName, "entityViewName");
    validateSqlIdentifier(viewName, "viewName");
    // Validate all column names from anonymizedElements
    const columnNames = Object.keys(anonymizedElements);
    for (const colName of columnNames) {
        validateSqlIdentifier(colName.toUpperCase(), `anonymizedElement column "${colName}"`);
    }
    // Check if anonymized view already exists using parameterized query (Finding #4)
    const viewExists = (await cds.db.run(`SELECT count(1) as "count" FROM SYS.VIEWS WHERE VIEW_NAME = ? AND SCHEMA_NAME = ?`, [viewName, schemaName]));
    //check if anonymized view already exists. If already present, drop it.
    if (viewExists[0].count === 1) {
        try {
            // viewName is validated above — safe to use in double-quoted identifier (Finding #5)
            await cds.db.run(`DROP VIEW "${viewName}"`);
            console.log(`Anonymized view '${viewName}' dropped.`);
        }
        catch (e) {
            console.log(`Cannot drop view "${viewName}" . Error: `, e);
            throw e;
        }
    }
    console.log(`Creating anonymized view "${viewName}" in HANA.`);
    //Dynamically construct anonymization create view query and execute it
    // All identifiers are validated above; annotation values are escaped (Finding #6a, #6b, #6c)
    let anonymizedViewQuery = ` CREATE VIEW "${viewName}" AS SELECT ${columnNames.map((item) => `"${item.toUpperCase()}"`).join(", ")}`;
    anonymizedViewQuery += ` FROM "${entityViewName}" \n WITH ANONYMIZATION  (${anonymizeAlgorithm}\n`;
    for (const [key, value] of Object.entries(anonymizedElements)) {
        const escapedValue = escapeSqlSingleQuote(value);
        anonymizedViewQuery += `COLUMN "${key.toUpperCase()}" PARAMETERS '${escapedValue}'\n`;
    }
    anonymizedViewQuery += `)`;
    try {
        await cds.db.run(anonymizedViewQuery);
        console.log(`Anonymized view "${viewName}" created in HANA.`);
    }
    catch (e) {
        console.log(`Creating of anonymized view "${viewName}" failed. Error: `, e);
        throw e;
    }
    try {
        //refresh the anonymized view (Finding #7 — viewName validated above)
        await cds.db.run(`REFRESH VIEW "${viewName}" ANONYMIZATION`);
        console.log(`Refreshed Anonymized view "${viewName}" in HANA.`);
    }
    catch (e) {
        console.log(`Refreshing anonymized view "${viewName}" failed. Error: `, e);
        throw e;
    }
}
//# sourceMappingURL=anonymization-helper.js.map
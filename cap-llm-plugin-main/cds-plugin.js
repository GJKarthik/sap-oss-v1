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
const cds = __importStar(require("@sap/cds"));
const anonymization_helper_1 = require("./lib/anonymization-helper");
const LOG = cds.log("cap-llm-plugin");
if (cds.requires["cap-llm-plugin"]) {
    // we register ourselves to the cds once served event
    // a one-time event, emitted when all services have been bootstrapped and added to the express app
    cds.once("served", async () => {
        /**
         * anonymization features starts
         */
        // go through all services
        let schemaName = "";
        // go through all services
        for (const srv of cds.services) {
            if (srv.name === "db") {
                schemaName = srv?.options?.credentials?.schema ?? "";
            }
            // go through all entities
            for (const entity of srv.entities) {
                const anonymizedElements = {};
                let anonymizeAlgorithm = "";
                // go through all elements in the entity and collect those with @anonymize annotation
                if (entity["@anonymize"] && entity.projection) {
                    anonymizeAlgorithm = entity["@anonymize"];
                    for (const key in entity.elements) {
                        const element = entity.elements[key];
                        // check if there is an annotation called anonymize on the element
                        if (element["@anonymize"]) {
                            anonymizedElements[element.name] = element["@anonymize"];
                        }
                    }
                    if (cds?.db?.kind === "hana") {
                        if (!schemaName) {
                            LOG.warn(`Skipping anonymization for entity "${entity.name}": HANA schema name could not be resolved from db service credentials.`);
                        }
                        else {
                            (0, anonymization_helper_1.createAnonymizedView)(schemaName, entity.name, anonymizeAlgorithm, anonymizedElements);
                        }
                    }
                    else {
                        LOG.warn("The anonymization feature is only supported with SAP HANA Cloud. Ensure the cds db is configured to use SAP HANA Cloud.");
                    }
                }
            }
        }
    });
}
//# sourceMappingURL=cds-plugin.js.map
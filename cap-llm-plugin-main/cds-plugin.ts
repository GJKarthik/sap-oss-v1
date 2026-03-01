// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import * as cds from "@sap/cds";
import { createAnonymizedView } from "./lib/anonymization-helper";

const LOG = (cds as any).log("cap-llm-plugin") as {
  debug: (...args: unknown[]) => void;
  info: (...args: unknown[]) => void;
  warn: (...args: unknown[]) => void;
  error: (...args: unknown[]) => void;
};

/** Map of element names to their @anonymize annotation values. */
interface AnonymizedElements {
  [elementName: string]: string;
}

if (cds.requires["cap-llm-plugin"]) {
  // we register ourselves to the cds once served event
  // a one-time event, emitted when all services have been bootstrapped and added to the express app
  cds.once("served", async (): Promise<void> => {
    /**
     * anonymization features starts
     */

    // go through all services
    let schemaName: string = "";

    // go through all services
    for (const srv of cds.services) {
      if (srv.name === "db") {
        schemaName = srv?.options?.credentials?.schema ?? "";
      }

      // go through all entities
      for (const entity of srv.entities) {
        const anonymizedElements: AnonymizedElements = {};
        let anonymizeAlgorithm: string = "";
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
              LOG.warn(
                `Skipping anonymization for entity "${entity.name}": HANA schema name could not be resolved from db service credentials.`
              );
            } else {
              createAnonymizedView(schemaName, entity.name, anonymizeAlgorithm, anonymizedElements);
            }
          } else {
            LOG.warn(
              "The anonymization feature is only supported with SAP HANA Cloud. Ensure the cds db is configured to use SAP HANA Cloud."
            );
          }
        }
      }
    }
  });
}

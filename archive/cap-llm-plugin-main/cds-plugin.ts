// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import * as cds from "@sap/cds";
import { createAnonymizedView } from "./lib/anonymization-helper";
import { AgUiAgentService, AgUiAgentConfig } from "./srv/ag-ui/agent-service";

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
     * AG-UI route registration
     *
     * Mounts /ag-ui/run (SSE streaming) and /ag-ui/tool-result (tool callbacks)
     * on the CAP Express app.  Only registered when the cap-llm-plugin requires
     * block includes an 'ag-ui' key or 'ag-ui.enabled' is truthy.
     */
    const agUiCfg = (cds.requires as any)["ag-ui"] as (AgUiAgentConfig & { enabled?: boolean }) | undefined;
    if (agUiCfg?.enabled !== false) {
      const app = (cds as any).app as any;
      if (app && typeof app.post === 'function') {
        const agentConfig: AgUiAgentConfig = {
          chatModelName: agUiCfg?.chatModelName ?? "Qwen/Qwen3.5-35B",
          resourceGroup: agUiCfg?.resourceGroup ?? "default",
          ...agUiCfg,
        };
        const agentService = new AgUiAgentService(agentConfig, null);

        // POST /ag-ui/run  — initiates an SSE streaming agent run
        app.post("/ag-ui/run", async (req: any, res: any) => {
          try {
            const body = req.body;
            if (!body || typeof body !== "object" || Array.isArray(body)) {
              res.status(400).json({ error: "Invalid request body" });
              return;
            }
            const messages: Array<{ role: string; content: string }> = [];
            if (Array.isArray(body.messages)) {
              for (const m of body.messages) {
                if (m && typeof m.role === "string" && typeof m.content === "string") {
                  messages.push({ role: m.role, content: m.content });
                }
              }
            }
            const VALID_BACKENDS = new Set(["vllm", "pal", "rag", "aicore-streaming", "blocked"]);
            const forceBackend =
              typeof body.forceBackend === "string" && VALID_BACKENDS.has(body.forceBackend)
                ? body.forceBackend
                : undefined;
            const sanitizedRequest = {
              threadId: typeof body.threadId === "string" ? body.threadId : undefined,
              runId: typeof body.runId === "string" ? body.runId : undefined,
              messages,
              forceBackend,
            };
            await agentService.handleRunRequest(sanitizedRequest as any, res);
          } catch (err) {
            LOG.error("[ag-ui] /run error:", err);
            if (!res.headersSent) {
              res.status(500).json({ error: (err as Error).message });
            }
          }
        });

        // POST /ag-ui/tool-result  — agent calls back with frontend tool result
        app.post("/ag-ui/tool-result", async (req: any, res: any) => {
          try {
            await agentService.handleToolResult(req.body);
            res.json({ success: true });
          } catch (err) {
            LOG.error("[ag-ui] /tool-result error:", err);
            if (!res.headersSent) {
              res.status(500).json({ error: (err as Error).message });
            }
          }
        });

        LOG.info("[ag-ui] Routes registered: POST /ag-ui/run, POST /ag-ui/tool-result");
      } else {
        LOG.warn("[ag-ui] cds.app not available; AG-UI routes not registered.");
      }
    }

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

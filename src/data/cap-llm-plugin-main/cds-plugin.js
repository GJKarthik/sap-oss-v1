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
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
const cds = __importStar(require("@sap/cds"));
const anonymization_helper_1 = require("./lib/anonymization-helper");
const agent_service_1 = require("./srv/ag-ui/agent-service");
const LOG = cds.log("cap-llm-plugin");
if (cds.requires["cap-llm-plugin"]) {
    // we register ourselves to the cds once served event
    // a one-time event, emitted when all services have been bootstrapped and added to the express app
    cds.once("served", async () => {
        /**
         * AG-UI route registration
         *
         * Mounts /ag-ui/run (SSE streaming) and /ag-ui/tool-result (tool callbacks)
         * on the CAP Express app.  Only registered when the cap-llm-plugin requires
         * block includes an 'ag-ui' key or 'ag-ui.enabled' is truthy.
         */
        const agUiCfg = cds.requires["ag-ui"];
        if (agUiCfg?.enabled !== false) {
            const app = cds.app;
            if (app && typeof app.post === 'function') {
                const agentConfig = {
                    chatModelName: agUiCfg?.chatModelName ?? "Qwen/Qwen3.5-35B",
                    resourceGroup: agUiCfg?.resourceGroup ?? "default",
                    ...agUiCfg,
                };
                const agentService = new agent_service_1.AgUiAgentService(agentConfig, null);
                // POST /ag-ui/run  — initiates an SSE streaming agent run
                app.post("/ag-ui/run", async (req, res) => {
                    try {
                        const body = req.body;
                        if (!body || typeof body !== "object" || Array.isArray(body)) {
                            res.status(400).json({ error: "Invalid request body" });
                            return;
                        }
                        const messages = [];
                        if (Array.isArray(body.messages)) {
                            for (const m of body.messages) {
                                if (m && typeof m.role === "string" && typeof m.content === "string") {
                                    messages.push({ role: m.role, content: m.content });
                                }
                            }
                        }
                        const VALID_BACKENDS = new Set(["vllm", "pal", "rag", "aicore-streaming", "blocked"]);
                        const forceBackend = typeof body.forceBackend === "string" && VALID_BACKENDS.has(body.forceBackend)
                            ? body.forceBackend
                            : undefined;
                        const sanitizedRequest = {
                            threadId: typeof body.threadId === "string" ? body.threadId : undefined,
                            runId: typeof body.runId === "string" ? body.runId : undefined,
                            messages,
                            forceBackend,
                        };
                        await agentService.handleRunRequest(sanitizedRequest, res);
                    }
                    catch (err) {
                        LOG.error("[ag-ui] /run error:", err);
                        if (!res.headersSent) {
                            res.status(500).json({ error: err.message });
                        }
                    }
                });
                // POST /ag-ui/tool-result  — agent calls back with frontend tool result
                app.post("/ag-ui/tool-result", async (req, res) => {
                    try {
                        await agentService.handleToolResult(req.body);
                        res.json({ success: true });
                    }
                    catch (err) {
                        LOG.error("[ag-ui] /tool-result error:", err);
                        if (!res.headersSent) {
                            res.status(500).json({ error: err.message });
                        }
                    }
                });
                LOG.info("[ag-ui] Routes registered: POST /ag-ui/run, POST /ag-ui/tool-result");
            }
            else {
                LOG.warn("[ag-ui] cds.app not available; AG-UI routes not registered.");
            }
        }
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
# Comprehensive Comparison Report

## elastic-claw/src/elasticclaw_analyser vs sap-oss-v1/src/intelligence/ai-core-pal

**Analysis Date**: March 30, 2026  
**Report Type**: Full Directory Comparison

---

## Executive Summary

The `elasticclaw_analyser` (elastic-claw) is a **significantly enhanced fork** of `ai-core-pal` (sap-oss-v1). While both share the same core foundation (KùzuDB graph store, Mangle rules, Zig-based MCP gateway), elastic-claw has been extensively extended with:

1. **Elastic Agent Builder Integration** - Full MCP server with 16 tools for Kibana delegation
2. **SAP HANA Production Connectivity** - Complete hdbcli integration with PAL procedures
3. **Multi-agent Delegation System** - 5 specialist agents (OECD Tax, Financial, Macro, Schema, Quant)
4. **AWS Deployment Ready** - App Runner, ECS Fargate deployment documentation
5. **Comprehensive Test Suite** - 18 test files vs 2 in sap-oss-v1

---

## 1. Directory Structure Differences

### Files ONLY in elastic-claw (Not in sap-oss-v1)

| Category | Files | Purpose |
|----------|-------|---------|
| **Root** | `.env`, `Dockerfile.python`, `requirements.txt` | Production deployment configs |
| **Agent** | `btp_kuzu_seeder.py`, `btp_server_client.py`, `discover_pal_tables.py`, `hana_client.py` | SAP HANA integration modules |
| **MCP Server** | `btp_pal_mcp_server.py`, `a2a_delegation_server.py` | Full MCP implementation with delegation |
| **Deploy** | `AWS_DEPLOYMENT_PLAN.md`, `deploy-aws.sh` | AWS deployment automation |
| **Scripts** | `deploy_workflows.py`, `provision_*.py` (7 files), `validate_agent_builder.py`, `run_schema_analytics.py` | Agent provisioning and workflows |
| **Tests** | 16 additional test files | Comprehensive test coverage |
| **Workflows** | `company-weekly-digest.yaml`, `oecd-daily-briefing.yaml`, `pipeline-health-check.yaml` | Automated workflow definitions |
| **Zig** | `fabric_es.zig`, `fabric_stub.zig` | Elasticsearch fabric integration |

### Files ONLY in sap-oss-v1 (Not in elastic-claw)

| Category | Files | Purpose |
|----------|-------|---------|
| **Root** | `TECHNICAL-ASSESSMENT.md` | Technical documentation |
| **Zig** | `mcp_openai_bridge.zig` | OpenAI bridge (different implementation) |
| **Zig/zig-out** | Build output directory | Compiled binaries |

---

## 2. Docker Configuration Differences

### elastic-claw/Dockerfile
```dockerfile
# Key differences:
FROM ubuntu:22.04  # Standard Ubuntu base
# Uses shell fallback for build failures
# Environment: MCPPAL_PORT=9881, MCPPAL_HOST=0.0.0.0
# Includes netcat-openbsd for fallback health checks
```

### sap-oss-v1/Dockerfile
```dockerfile
# Key differences:
FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04  # GPU-enabled base
# Standard build without fallback
# Environment: PORT=8080, CUDA_VISIBLE_DEVICES=0
# GPU-specific: NVIDIA_VISIBLE_DEVICES=all, NVIDIA_DRIVER_CAPABILITIES=compute,utility
EXPOSE 8080 9090  # Different ports
```

**Summary**: elastic-claw targets CPU-only AWS deployment; sap-oss-v1 targets GPU-enabled SAP AI Core deployment.

---

## 3. Python Module Differences

### 3.1 Agent Module (`agent/`)

| Feature | elastic-claw | sap-oss-v1 |
|---------|-------------|------------|
| **aicore_pal_agent.py** | 1,150+ lines with BTP integration | 550 lines, basic implementation |
| **hana_client.py** | Full implementation (600+ lines) | Not present |
| **btp_server_client.py** | REST API client for BTP server | Not present |
| **btp_kuzu_seeder.py** | Seeds BTP schema into KùzuDB | Not present |
| **discover_pal_tables.py** | Table discovery utilities | Not present |

### 3.2 MangleEngine Differences

**elastic-claw** (extended tool set):
```python
self.facts["agent_can_use"] = {
    "pal_classification", "pal_regression", "pal_clustering",
    "pal_forecast", "pal_anomaly", "mangle_query",
    "kuzu_index", "kuzu_query",
    # BTP schema integration tools
    "btp_registry_query", "btp_registry_query_domain", "btp_search",
    "search_schema_registry", "list_domains", "hana_tables",
    "kuzu_seed_btp",
    # Direct PAL calls via hdbcli
    "pal_arima", "pal_anomaly_detection",
    # PAL calls from BTP tables
    "pal_arima_from_table", "pal_anomaly_from_table",
    # Analytics metadata discovery
    "get_forecastable_columns", "get_dimension_columns", "get_date_columns",
    # Hierarchical reconciliation
    "reconcile_hierarchical_forecasts",
}
```

**sap-oss-v1** (basic tool set):
```python
self.facts["agent_can_use"] = {
    "pal_classification", "pal_regression", "pal_clustering",
    "pal_forecast", "pal_anomaly", "mangle_query",
    "kuzu_index", "kuzu_query"
}
```

### 3.3 AICorePALAgent Methods

| Method | elastic-claw | sap-oss-v1 |
|--------|-------------|------------|
| `handle_btp_registry_query()` | ✅ | ❌ |
| `handle_btp_search()` | ✅ | ❌ |
| `handle_kuzu_seed_btp()` | ✅ | ❌ |
| `handle_pal_arima()` | ✅ | ❌ |
| `handle_pal_anomaly_detection()` | ✅ | ❌ |
| `handle_pal_arima_from_table()` | ✅ | ❌ |
| `handle_pal_anomaly_from_table()` | ✅ | ❌ |
| `handle_hana_tables()` | ✅ | ❌ |
| `handle_list_domains()` | ✅ | ❌ |
| `handle_get_forecastable_columns()` | ✅ | ❌ |
| `handle_get_dimension_columns()` | ✅ | ❌ |
| `handle_get_date_columns()` | ✅ | ❌ |
| `analyze_pal_request()` | ✅ | ❌ |
| `_parse_pal_intent()` | ✅ | ❌ |
| `_discover_table_for_intent()` | ✅ | ❌ |

---

## 4. MCP Server Differences

### elastic-claw/mcp_server/

| File | Lines | Description |
|------|-------|-------------|
| `btp_pal_mcp_server.py` | 700+ | **Full MCP server with 16 tools** |
| `a2a_delegation_server.py` | New | Agent-to-agent delegation |
| `kuzu_store.py` | Same | Identical to sap-oss-v1 |

### sap-oss-v1/mcp_server/

| File | Lines | Description |
|------|-------|-------------|
| `kuzu_store.py` | ~250 | Graph store only |
| **No btp_pal_mcp_server.py** | - | Missing MCP server |

### MCP Tool Inventory (elastic-claw only)

```
1. btp_registry_query - Query SCHEMA_REGISTRY
2. btp_search - Search fields across HANA + ES
3. pal_arima - Time series forecast (synthetic data)
4. pal_anomaly_detection - Anomaly detection (synthetic data)
5. pal_anomaly_from_table - Anomaly detection (real BTP table)
6. pal_arima_from_table - Time series forecast (real BTP table)
7. hana_tables - Discover PAL-suitable tables
8. list_domains - List domains from SCHEMA_REGISTRY
9. search_schema_registry - Search SCHEMA_REGISTRY fields
10. kuzu_query - Graph query placeholder
11. delegate_to_oecd_tax_expert - Delegate to OECD tax specialist
12. delegate_to_financial_analyst - Delegate to financial specialist
13. delegate_to_macro_strategist - Delegate to macro specialist
14. delegate_to_schema_navigator - Delegate to schema specialist
15. delegate_to_quant_analyst - Delegate to quant specialist
16. list_available_specialists - List delegation specialists
```

---

## 5. Dependencies Differences

### elastic-claw/requirements.txt (present)
```
hdbcli>=2.19.0      # SAP HANA connectivity
hana-ml>=2.19.0     # HANA ML library
mcp>=1.0.0          # MCP protocol
fastmcp>=0.1.0      # FastMCP server
aiohttp>=3.9.0      # Async HTTP
uvicorn>=0.25.0     # ASGI server
requests>=2.31.0    # HTTP client for Kibana
python-dotenv>=1.0.0
pandas>=2.0.0
numpy>=1.24.0
```

### sap-oss-v1 (no requirements.txt)
Dependencies not explicitly declared at module level.

---

## 6. Test Suite Differences

### elastic-claw/tests/ (18 files)

| Test File | Purpose |
|-----------|---------|
| `test_btp_integration.py` | BTP server integration |
| `test_btp_timeseries.py` | BTP time series PAL |
| `test_deploy_workflows.py` | Workflow deployment |
| `test_docker_mcp.py` | Docker MCP testing |
| `test_existing_pal_table.py` | PAL on existing tables |
| `test_kuzu_store.py` | Graph store |
| `test_mcp_btp_tools.py` | MCP BTP tools |
| `test_mcp_server.py` | MCP server |
| `test_pal_from_tables.py` | PAL from real tables |
| `test_pal_simple.py` | Simple PAL tests |
| `test_provision_agent_builder.py` | Agent Builder provisioning |
| `test_provision_financial_analyst_agent.py` | Financial agent |
| `test_provision_macro_strategist_agent.py` | Macro agent |
| `test_provision_oecd_tax_agent.py` | OECD tax agent |
| `test_provision_schema_navigator_agent.py` | Schema agent |
| `test_validate_agent_builder.py` | Agent Builder validation |
| `debug_pal_issue.py` | PAL debugging |
| `list_hana_tables.py` | Table listing utility |

### sap-oss-v1/tests/ (2 files)

| Test File | Purpose |
|-----------|---------|
| `__init__.py` | Package init |
| `test_kuzu_store.py` | Graph store only |

---

## 7. Deployment Configuration Differences

### elastic-claw/deploy/

| File | Purpose |
|------|---------|
| `AWS_DEPLOYMENT_PLAN.md` | **Comprehensive AWS deployment guide** |
| `deploy-aws.sh` | AWS deployment script |
| `aicore/deployment-config.json` | Same as sap-oss-v1 |
| `aicore/serving-template.yaml` | Same as sap-oss-v1 |

### sap-oss-v1/deploy/

| File | Purpose |
|------|---------|
| `aicore/deployment-config.json` | SAP AI Core config |
| `aicore/serving-template.yaml` | Serving template |

**Key Difference**: elastic-claw has AWS deployment documentation; sap-oss-v1 only has SAP AI Core.

---

## 8. Zig Implementation Differences

### Main.zig Comparison

Both files are nearly identical (~2,200 lines each) with these differences:

**elastic-claw additions**:
```zig
// Elasticsearch fabric integration
const fabric_es = @import("fabric_es.zig");

// Additional file in zig/src/:
// fabric_es.zig - Elasticsearch fabric connector
// fabric_stub.zig - Fabric stub for testing
```

**sap-oss-v1 additions**:
```zig
// OpenAI bridge (different approach)
const mcp_openai_bridge = @import("mcp_openai_bridge.zig");
```

### zig/src/ File Differences

| File | elastic-claw | sap-oss-v1 |
|------|-------------|------------|
| `fabric_es.zig` | ✅ | ❌ |
| `fabric_stub.zig` | ✅ | ❌ |
| `mcp_openai_bridge.zig` | ❌ | ✅ |
| `zig-out/` (build output) | ❌ | ✅ |

---

## 9. Scripts Differences

### elastic-claw/scripts/ (11 files)

| Script | Purpose |
|--------|---------|
| `deploy_to_aicore.sh` | AI Core deployment |
| `deploy_workflows.py` | Workflow deployment |
| `provision_a2a_delegation.py` | A2A delegation setup |
| `provision_agent_builder.py` | Agent Builder provisioning |
| `provision_financial_analyst_agent.py` | Financial agent |
| `provision_macro_strategist_agent.py` | Macro agent |
| `provision_oecd_tax_agent.py` | OECD tax agent |
| `provision_quant_analyst_agent.py` | Quant agent |
| `provision_schema_navigator_agent.py` | Schema agent |
| `run_schema_analytics.py` | Schema analytics |
| `validate_agent_builder.py` | Validation script |

### sap-oss-v1/scripts/ (1 file)

| Script | Purpose |
|--------|---------|
| `deploy_to_aicore.sh` | AI Core deployment only |

---

## 10. Workflow Files (elastic-claw only)

| Workflow | Description |
|----------|-------------|
| `company-weekly-digest.yaml` | Weekly company analysis workflow |
| `oecd-daily-briefing.yaml` | Daily OECD tax briefing |
| `pipeline-health-check.yaml` | Pipeline health monitoring |

---

## 11. hana_client.py Analysis (elastic-claw only)

This is the **most significant addition** in elastic-claw - a complete SAP HANA Cloud client:

### Capabilities

| Function | Description |
|----------|-------------|
| `query_schema_registry()` | Query BTP.SCHEMA_REGISTRY |
| `search_schema_registry()` | Full-text search across registry |
| `list_domains()` | List distinct domains |
| `discover_pal_tables()` | Find PAL-suitable tables |
| `call_pal_arima()` | Execute PAL ARIMA via hana-ml |
| `call_pal_anomaly_detection()` | Execute PAL anomaly detection |
| `call_pal_arima_from_table()` | ARIMA directly on BTP table |
| `call_pal_anomaly_from_table()` | Anomaly detection on BTP table |
| `_run_arima_multi_dimension()` | Multi-dimension forecasting |

### Environment Variables

```
HANA_HOST, HANA_PORT (443), HANA_USER, HANA_PASSWORD
HANA_ENCRYPT (true), HANA_SSL_VALIDATE_CERTIFICATE (true)
HANA_SCHEMA (BTP)
```

---

## 12. Integration Architecture

### elastic-claw Integration Points

```
┌─────────────────────────────────────────────────────────────┐
│                    Elastic Agent Builder                     │
│                   (Kibana AI Assistant)                      │
└─────────────────────────┬───────────────────────────────────┘
                          │ MCP Protocol (HTTP POST /mcp)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                  btp_pal_mcp_server.py                       │
│                    (16 MCP Tools)                            │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────────────────┐│
│  │ BTP Tools   │ │ PAL Tools   │ │ Delegation Tools       ││
│  │ - registry  │ │ - arima     │ │ - oecd_tax_expert      ││
│  │ - search    │ │ - anomaly   │ │ - financial_analyst    ││
│  │ - domains   │ │ - tables    │ │ - macro_strategist     ││
│  └──────┬──────┘ └──────┬──────┘ └──────────┬──────────────┘│
└─────────┼───────────────┼───────────────────┼───────────────┘
          │               │                   │
          ▼               ▼                   ▼
    ┌──────────┐    ┌──────────┐        ┌──────────┐
    │ hana_    │    │ hana-ml  │        │ Kibana   │
    │ client.py│    │ PAL      │        │ Converse │
    └────┬─────┘    └────┬─────┘        │ API      │
         │               │              └──────────┘
         ▼               ▼
    ┌──────────────────────┐
    │   SAP HANA Cloud     │
    │   BTP.SCHEMA_REGISTRY│
    │   PAL Algorithms     │
    └──────────────────────┘
```

### sap-oss-v1 Integration Points

```
┌─────────────────────────────────────────────────────────────┐
│                    SAP AI Core                               │
│                  (GPU-Accelerated)                           │
└─────────────────────────┬───────────────────────────────────┘
                          │ OpenAI API / MCP
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              Zig mcp-mesh-gateway                            │
│              (mcppal-mesh-gateway-v1)                        │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────────────────┐│
│  │ PAL Catalog │ │ Schema      │ │ Graph Tools            ││
│  │ - list      │ │ - explore   │ │ - publish              ││
│  │ - search    │ │ - describe  │ │ - query                ││
│  │ - spec/sql  │ │ - refresh   │ │                        ││
│  └──────┬──────┘ └──────┬──────┘ └──────────┬──────────────┘│
└─────────┼───────────────┼───────────────────┼───────────────┘
          │               │                   │
          ▼               ▼                   ▼
    ┌──────────┐    ┌──────────┐        ┌──────────┐
    │ PAL      │    │ HANA     │        │ KùzuDB   │
    │ Catalog  │    │ Schema   │        │ Graph    │
    │ YAML     │    │ Discovery│        │ Store    │
    └──────────┘    └──────────┘        └──────────┘
```

---

## 13. Summary Table

| Aspect | elastic-claw | sap-oss-v1 |
|--------|-------------|------------|
| **Primary Target** | Elastic Cloud / AWS | SAP AI Core |
| **Base Image** | Ubuntu 22.04 | NVIDIA CUDA 12.2 |
| **Default Port** | 9881 | 8080 |
| **Python Dependencies** | Explicit requirements.txt | Not declared |
| **MCP Server** | Full 16-tool implementation | Not present |
| **HANA Client** | Complete hana_client.py | Not present |
| **Specialist Agents** | 5 delegation agents | None |
| **Test Coverage** | 18 test files | 2 test files |
| **Deployment Docs** | AWS + AI Core | AI Core only |
| **Workflow YAML** | 3 workflow files | None |
| **Agent Scripts** | 11 scripts | 1 script |

---

## 14. Recommendations

### If using sap-oss-v1 and need:

1. **Elastic Agent Builder integration** → Adopt elastic-claw's `btp_pal_mcp_server.py`
2. **Real HANA PAL execution** → Adopt `hana_client.py`
3. **Multi-agent delegation** → Adopt the delegation system
4. **AWS deployment** → Use elastic-claw's deployment docs

### If using elastic-claw and need:

1. **GPU acceleration** → Adopt sap-oss-v1's CUDA Dockerfile
2. **OpenAI bridge** → Adopt `mcp_openai_bridge.zig`

---

## 15. Conclusion

**elastic-claw/src/elasticclaw_analyser** is a **production-ready fork** of **sap-oss-v1/src/intelligence/ai-core-pal** that has been significantly enhanced for:

1. **Elastic Cloud integration** via MCP protocol
2. **Real SAP HANA Cloud connectivity** via hdbcli/hana-ml
3. **Enterprise multi-agent patterns** with specialist delegation
4. **AWS deployment** alongside SAP AI Core

The core Zig MCP gateway and KùzuDB graph store remain nearly identical, making the Python/MCP additions the primary differentiation.
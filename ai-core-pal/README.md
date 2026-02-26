# BDC MCP PAL

Model Context Protocol (MCP) integration with SAP PAL (Predictive Analysis Library).

## Features

- **MCP Server**: Standard MCP server implementation
- **PAL Integration**: Connect to SAP HANA PAL procedures
- **ML Operations**: Classification, regression, clustering
- **Time Series**: Forecasting and anomaly detection

## Architecture

```
┌──────────────────────────────────────┐
│         MCP Client (AI Agent)        │
└─────────────────┬────────────────────┘
                  │ MCP Protocol
┌─────────────────▼────────────────────┐
│           MCP PAL Server             │
│  ┌─────────────────────────────────┐ │
│  │  Tool: pal_classification       │ │
│  │  Tool: pal_regression           │ │
│  │  Tool: pal_clustering           │ │
│  │  Tool: pal_forecast             │ │
│  └─────────────────────────────────┘ │
└─────────────────┬────────────────────┘
                  │ SQL
┌─────────────────▼────────────────────┐
│         SAP HANA (PAL)               │
└──────────────────────────────────────┘
```

## MCP Tools

| Tool | Description |
|------|-------------|
| `pal_classification` | Run PAL classification |
| `pal_regression` | Run PAL regression analysis |
| `pal_clustering` | Run PAL clustering (k-means, etc.) |
| `pal_forecast` | Run PAL time series forecasting |
| `pal_anomaly` | Detect anomalies in data |

## Quick Start

```bash
# Build
cd zig && zig build -Doptimize=ReleaseFast

# Run MCP server
./zig-out/bin/ai-core-pal --port 8084
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_PORT` | 8084 | MCP server port |
| `HANA_HOST` | - | SAP HANA hostname |
| `HANA_PORT` | 443 | SAP HANA port |
| `HANA_USER` | - | HANA username |
| `HANA_SCHEMA` | - | Default schema |

## Usage Example

```json
{
  "method": "tools/call",
  "params": {
    "name": "pal_forecast",
    "arguments": {
      "table": "SALES_DATA",
      "target_column": "AMOUNT",
      "periods": 12,
      "algorithm": "ARIMA"
    }
  }
}
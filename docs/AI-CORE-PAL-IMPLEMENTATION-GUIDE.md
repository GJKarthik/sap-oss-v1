# SAP OSS ai-core-pal Implementation Guide

## Step-by-Step Deployment to SAP BTP Kyma

**Target Environment**: SAP BTP Kyma (Kubernetes)  
**HANA Instance**: `fea6d8c0-6075-4a0d-8429-28412013ab85.hana.prod-ap11.hanacloud.ondemand.com`  
**Schema**: `AINUCLEUS`  
**PAL Algorithms**: classification, regression, clustering, forecast, anomaly

---

## Implementation Checklist

| Step | Component | Status | Action Required |
|------|-----------|--------|-----------------|
| 1 | HANA Connectivity | ❌ Missing | Create `hana_client.py` |
| 2 | Sample Table Creation | ❌ Missing | DDL scripts for PAL tables |
| 3 | Sample Records Population | ❌ Missing | DML scripts with test data |
| 4 | PAL MCP Server | ❌ Missing | Create `btp_pal_mcp_server.py` |
| 5 | Kyma Deployment | ❌ Missing | StatefulSet + Service YAML |
| 6 | Test Scripts | ❌ Missing | Integration tests |
| 7 | requirements.txt | ❌ Missing | Python dependencies |

---

## Step 1: HANA Connectivity

### What's Missing
- `src/intelligence/ai-core-pal/agent/hana_client.py` - **DOES NOT EXIST**

### What Will Be Created
```
src/intelligence/ai-core-pal/
├── agent/
│   ├── __init__.py           # Update with hana imports
│   └── hana_client.py        # NEW - HANA Cloud client
├── .env.example              # NEW - Environment template
└── requirements.txt          # NEW - Python dependencies
```

### Environment Variables Needed
```bash
HANA_HOST=fea6d8c0-6075-4a0d-8429-28412013ab85.hana.prod-ap11.hanacloud.ondemand.com
HANA_PORT=443
HANA_USER=AINUCLEUS
HANA_PASSWORD=hU0*Waf5C&
HANA_ENCRYPT=true
HANA_SSL_VALIDATE_CERTIFICATE=false
HANA_SCHEMA=AINUCLEUS
```

---

## Step 2: Sample Table Creation

### Tables to Create

#### 2.1 Financial Time Series Table (for forecasting)
```sql
CREATE COLUMN TABLE AINUCLEUS.PAL_TIMESERIES_DATA (
    ID INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    RECORD_DATE DATE NOT NULL,
    AMOUNT_USD DECIMAL(15,2),
    CATEGORY NVARCHAR(50),
    REGION NVARCHAR(50),
    CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### 2.2 Anomaly Detection Table
```sql
CREATE COLUMN TABLE AINUCLEUS.PAL_ANOMALY_DATA (
    ID INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    SENSOR_ID NVARCHAR(20),
    METRIC_VALUE DOUBLE,
    METRIC_TIMESTAMP TIMESTAMP,
    METRIC_TYPE NVARCHAR(50)
);
```

#### 2.3 Clustering Table (customer segmentation)
```sql
CREATE COLUMN TABLE AINUCLEUS.PAL_CLUSTERING_DATA (
    ID INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    CUSTOMER_ID NVARCHAR(20),
    AGE INTEGER,
    INCOME DECIMAL(12,2),
    SPEND_SCORE INTEGER,
    REGION NVARCHAR(50)
);
```

#### 2.4 Classification Table
```sql
CREATE COLUMN TABLE AINUCLEUS.PAL_CLASSIFICATION_DATA (
    ID INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    FEATURE_1 DOUBLE,
    FEATURE_2 DOUBLE,
    FEATURE_3 DOUBLE,
    LABEL NVARCHAR(20)
);
```

#### 2.5 Regression Table
```sql
CREATE COLUMN TABLE AINUCLEUS.PAL_REGRESSION_DATA (
    ID INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    X1 DOUBLE,
    X2 DOUBLE,
    X3 DOUBLE,
    Y_TARGET DOUBLE
);
```

---

## Step 3: Sample Records Population

### 3.1 Time Series Data (24 months of sales)
```sql
INSERT INTO AINUCLEUS.PAL_TIMESERIES_DATA (RECORD_DATE, AMOUNT_USD, CATEGORY, REGION)
SELECT 
    ADD_MONTHS(TO_DATE('2024-01-01'), SERIES.ELEMENT_NUMBER - 1) AS RECORD_DATE,
    ROUND(50000 + (RAND() * 30000) + (SIN(SERIES.ELEMENT_NUMBER * 0.5) * 10000), 2) AS AMOUNT_USD,
    'SALES' AS CATEGORY,
    'APAC' AS REGION
FROM SERIES_GENERATE_INTEGER(1, 1, 24) AS SERIES;
```

### 3.2 Anomaly Data (sensor readings)
```sql
-- Normal readings
INSERT INTO AINUCLEUS.PAL_ANOMALY_DATA (SENSOR_ID, METRIC_VALUE, METRIC_TIMESTAMP, METRIC_TYPE)
SELECT 
    'SENSOR_001',
    50 + (RAND() * 10), -- Normal range: 50-60
    ADD_SECONDS(CURRENT_TIMESTAMP, -SERIES.ELEMENT_NUMBER * 3600),
    'TEMPERATURE'
FROM SERIES_GENERATE_INTEGER(1, 1, 100) AS SERIES;

-- Inject anomalies
INSERT INTO AINUCLEUS.PAL_ANOMALY_DATA (SENSOR_ID, METRIC_VALUE, METRIC_TIMESTAMP, METRIC_TYPE)
VALUES 
    ('SENSOR_001', 95.5, ADD_DAYS(CURRENT_TIMESTAMP, -5), 'TEMPERATURE'),
    ('SENSOR_001', 12.3, ADD_DAYS(CURRENT_TIMESTAMP, -10), 'TEMPERATURE'),
    ('SENSOR_001', 105.8, ADD_DAYS(CURRENT_TIMESTAMP, -15), 'TEMPERATURE');
```

### 3.3 Clustering Data (100 customers)
```sql
INSERT INTO AINUCLEUS.PAL_CLUSTERING_DATA (CUSTOMER_ID, AGE, INCOME, SPEND_SCORE, REGION)
SELECT 
    'CUST_' || LPAD(SERIES.ELEMENT_NUMBER, 5, '0'),
    20 + FLOOR(RAND() * 50),  -- Age 20-70
    30000 + FLOOR(RAND() * 150000),  -- Income 30k-180k
    FLOOR(RAND() * 100),  -- Spend score 0-100
    CASE WHEN RAND() < 0.3 THEN 'APAC' WHEN RAND() < 0.6 THEN 'EMEA' ELSE 'AMER' END
FROM SERIES_GENERATE_INTEGER(1, 1, 100) AS SERIES;
```

### 3.4 Classification Data (binary classification)
```sql
INSERT INTO AINUCLEUS.PAL_CLASSIFICATION_DATA (FEATURE_1, FEATURE_2, FEATURE_3, LABEL)
SELECT 
    RAND() * 10,
    RAND() * 10,
    RAND() * 10,
    CASE WHEN RAND() < 0.5 THEN 'CLASS_A' ELSE 'CLASS_B' END
FROM SERIES_GENERATE_INTEGER(1, 1, 200) AS SERIES;
```

### 3.5 Regression Data
```sql
INSERT INTO AINUCLEUS.PAL_REGRESSION_DATA (X1, X2, X3, Y_TARGET)
SELECT 
    RAND() * 100 AS X1,
    RAND() * 50 AS X2,
    RAND() * 25 AS X3,
    -- Y = 2*X1 + 3*X2 + noise
    (2 * RAND() * 100) + (3 * RAND() * 50) + (RAND() * 10) AS Y_TARGET
FROM SERIES_GENERATE_INTEGER(1, 1, 150) AS SERIES;
```

---

## Step 4: PAL MCP Server

### Files to Create

```
src/intelligence/ai-core-pal/
├── mcp_server/
│   ├── __init__.py
│   ├── btp_pal_mcp_server.py    # NEW - Main MCP server
├── agent/
│   ├── __init__.py
│   ├── aicore_pal_agent.py      # EXISTING - needs HANA methods
│   └── hana_client.py           # NEW
├── requirements.txt             # NEW
├── Dockerfile.python            # NEW - Python-only Dockerfile
└── .env.example                 # NEW
```

### MCP Tools to Implement

| Tool | Description | HANA Query |
|------|-------------|------------|
| `pal_forecast` | Time series forecasting | PAL_SINGLEEXPONENTIALSMOOTHING |
| `pal_anomaly` | Anomaly detection | IQR statistical method |
| `pal_clustering` | K-Means clustering | PAL_KMEANS |
| `pal_classification` | Random Forest classifier | PAL_RANDOMFOREST |
| `pal_regression` | Linear regression | PAL_LASSO |
| `mangle_query` | Datalog inference | Mangle engine |

---

## Step 5: Kyma Deployment

### 5.1 Namespace and Secret
```yaml
# deploy/kyma/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ai-core-pal
---
apiVersion: v1
kind: Secret
metadata:
  name: hana-credentials
  namespace: ai-core-pal
type: Opaque
stringData:
  HANA_HOST: fea6d8c0-6075-4a0d-8429-28412013ab85.hana.prod-ap11.hanacloud.ondemand.com
  HANA_PORT: "443"
  HANA_USER: AINUCLEUS
  HANA_PASSWORD: "hU0*Waf5C&"
  HANA_SCHEMA: AINUCLEUS
```

### 5.2 StatefulSet
```yaml
# deploy/kyma/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ai-core-pal
  namespace: ai-core-pal
spec:
  serviceName: ai-core-pal
  replicas: 1
  selector:
    matchLabels:
      app: ai-core-pal
  template:
    metadata:
      labels:
        app: ai-core-pal
    spec:
      containers:
      - name: mcp-server
        image: ghcr.io/gjkarthik/ai-core-pal:latest
        ports:
        - containerPort: 8084
          name: mcp
        - containerPort: 9881
          name: http
        envFrom:
        - secretRef:
            name: hana-credentials
        env:
        - name: HANA_ENCRYPT
          value: "true"
        - name: HANA_SSL_VALIDATE_CERTIFICATE
          value: "false"
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8084
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8084
          initialDelaySeconds: 5
          periodSeconds: 5
```

### 5.3 Service
```yaml
# deploy/kyma/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ai-core-pal
  namespace: ai-core-pal
spec:
  type: ClusterIP
  ports:
  - name: mcp
    port: 8084
    targetPort: 8084
  - name: http
    port: 9881
    targetPort: 9881
  selector:
    app: ai-core-pal
---
apiVersion: gateway.kyma-project.io/v1beta1
kind: APIRule
metadata:
  name: ai-core-pal
  namespace: ai-core-pal
spec:
  gateway: kyma-gateway.kyma-system.svc.cluster.local
  host: ai-core-pal
  rules:
  - path: /.*
    methods: ["GET", "POST"]
    accessStrategies:
    - handler: noop
  service:
    name: ai-core-pal
    port: 8084
```

---

## Step 6: Test Scripts

### 6.1 Connection Test
```python
# tests/test_hana_connection.py
def test_hana_connection():
    from agent.hana_client import is_available, list_tables
    assert is_available(), "HANA not connected"
    tables = list_tables(schema="AINUCLEUS")
    assert len(tables) > 0
```

### 6.2 PAL Forecast Test
```python
# tests/test_pal_forecast.py
def test_pal_forecast():
    from agent.hana_client import call_pal_forecast_from_table
    result = call_pal_forecast_from_table(
        table_name="AINUCLEUS.PAL_TIMESERIES_DATA",
        date_column="RECORD_DATE",
        value_column="AMOUNT_USD",
        horizon=6
    )
    assert result["status"] == "success"
    assert len(result["forecast"]) == 6
```

### 6.3 MCP Server Test
```python
# tests/test_mcp_server.py
import requests

def test_mcp_tools_list():
    resp = requests.post("http://localhost:8084/mcp", json={
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list"
    })
    data = resp.json()
    tools = [t["name"] for t in data["result"]["tools"]]
    assert "pal_forecast" in tools
    assert "pal_anomaly" in tools
```

---

## File Creation Order

### Phase 1: Core Infrastructure
1. `requirements.txt`
2. `.env.example`
3. `agent/hana_client.py`
4. Update `agent/__init__.py`

### Phase 2: MCP Server
5. `mcp_server/btp_pal_mcp_server.py`
6. Update `mcp_server/__init__.py`

### Phase 3: Database Setup
7. `scripts/create_tables.sql`
8. `scripts/populate_data.sql`

### Phase 4: Deployment
9. `Dockerfile.python`
10. `deploy/kyma/namespace.yaml`
11. `deploy/kyma/statefulset.yaml`
12. `deploy/kyma/service.yaml`

### Phase 5: Testing
13. `tests/test_hana_connection.py`
14. `tests/test_pal_forecast.py`
15. `tests/test_mcp_server.py`

---

## Ready to Implement?

I will create all these files in the following order. Confirm to proceed:

1. **requirements.txt** - Python dependencies (hdbcli, hana-ml, mcp, fastmcp)
2. **hana_client.py** - SAP HANA Cloud connectivity with PAL functions
3. **SQL scripts** - Table creation and data population
4. **btp_pal_mcp_server.py** - MCP server with 8 tools
5. **Kyma deployment YAMLs** - StatefulSet, Service, APIRule
6. **Test scripts** - Integration tests

Shall I start creating these files now?

#!/usr/bin/env python3
"""
Populate HANA tables via ai-core-pal MCP server.
"""
import json
import requests
from datetime import date, timedelta
import random
import math

MCP_URL = "https://ai-core-pal.c-054c570.kyma.ondemand.com/mcp"

def execute_sql(sql: str) -> dict:
    """Execute SQL via MCP server."""
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "execute_sql",
            "arguments": {"sql": sql}
        }
    }
    resp = requests.post(MCP_URL, json=payload)
    result = resp.json()
    content = result.get("result", {}).get("content", [{}])[0].get("text", "{}")
    return json.loads(content)


def populate_esg_data():
    """Insert 24 months of ESG carbon emissions data."""
    print("Populating ESG_CARBON_EMISSIONS...")
    
    # Delete existing data
    execute_sql("DELETE FROM AINUCLEUS.ESG_CARBON_EMISSIONS WHERE COMPANY_CODE = 'SAP1000'")
    
    base_date = date.today() - timedelta(days=730)  # 2 years ago
    
    for i in range(24):
        month_date = base_date + timedelta(days=30 * i)
        month = month_date.month
        
        # Seasonal variation - higher in winter
        seasonal = 1 + 0.15 * math.cos(3.14159 * month / 6)
        
        # Decreasing trend over time
        trend = 1 - 0.02 * i / 24
        
        scope1 = round(1250 * seasonal * trend + random.uniform(-50, 50), 2)
        scope2 = round(850 * seasonal * trend + random.uniform(-30, 30), 2)
        scope3 = round(4500 * seasonal * trend + random.uniform(-200, 200), 2)
        total = round(scope1 + scope2 + scope3, 2)
        
        sql = f"""INSERT INTO AINUCLEUS.ESG_CARBON_EMISSIONS 
            (COMPANY_CODE, REPORTING_PERIOD, SCOPE_1_EMISSIONS, SCOPE_2_EMISSIONS, 
             SCOPE_3_EMISSIONS, TOTAL_EMISSIONS, ENERGY_CONSUMPTION, RENEWABLE_PERCENT)
            VALUES ('SAP1000', '{month_date.strftime('%Y-%m-%d')}', {scope1}, {scope2}, 
                    {scope3}, {total}, {8500 * seasonal:.2f}, {35 + i * 1.5:.2f})"""
        
        result = execute_sql(sql)
        if result.get("status") == "error":
            print(f"  Error: {result.get('error')}")
        else:
            print(f"  Inserted {month_date}")
    
    # Count rows
    result = execute_sql("SELECT COUNT(*) as CNT FROM AINUCLEUS.ESG_CARBON_EMISSIONS")
    print(f"  Total rows: {result}")


def populate_revenue_data():
    """Insert 18 months of financial revenue data."""
    print("Populating FI_REVENUE_ACTUALS...")
    
    execute_sql("DELETE FROM AINUCLEUS.FI_REVENUE_ACTUALS WHERE COMPANY_CODE = 'SAP1000'")
    
    base_date = date.today() - timedelta(days=540)  # 18 months ago
    
    for i in range(18):
        month_date = base_date + timedelta(days=30 * i)
        month = month_date.month
        
        # Q4 higher, Q1 lower
        if month in (10, 11, 12):
            seasonal = 1.15
        elif month in (1, 2):
            seasonal = 0.85
        else:
            seasonal = 1.0
        
        revenue = round(12500000 * (1 + 0.03 * i/18) * seasonal + random.uniform(-500000, 500000), 2)
        cost = round(revenue * 0.65 + random.uniform(-200000, 200000), 2)
        margin = round(revenue - cost, 2)
        margin_pct = round((revenue - cost) / revenue * 100, 2)
        
        sql = f"""INSERT INTO AINUCLEUS.FI_REVENUE_ACTUALS 
            (COMPANY_CODE, FISCAL_PERIOD, PROFIT_CENTER, REVENUE_ACTUAL, COST_ACTUAL, 
             GROSS_MARGIN, MARGIN_PERCENT)
            VALUES ('SAP1000', '{month_date.strftime('%Y-%m-%d')}', 'PC-CLOUD', 
                    {revenue}, {cost}, {margin}, {margin_pct})"""
        
        result = execute_sql(sql)
        if result.get("status") == "error":
            print(f"  Error: {result.get('error')}")
        else:
            print(f"  Inserted {month_date}")
    
    result = execute_sql("SELECT COUNT(*) as CNT FROM AINUCLEUS.FI_REVENUE_ACTUALS")
    print(f"  Total rows: {result}")


if __name__ == "__main__":
    print("=== Populating HANA tables via MCP ===\n")
    populate_esg_data()
    print()
    populate_revenue_data()
    print("\n=== Done ===")
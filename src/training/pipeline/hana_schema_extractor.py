"""
hana_schema_extractor.py — Extract schemas from HANA Cloud via AI Core PAL MCP.

This module queries HANA Cloud system views through the AI Core PAL MCP service
to extract live table metadata for training data generation.
"""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from typing import Optional

import httpx

from .simula_config import HanaSourceConfig
from .schema_registry import SchemaRegistry, TableSchema, Column, Domain

logger = logging.getLogger(__name__)


@dataclass
class MCPRequest:
    """JSON-RPC 2.0 request for MCP protocol."""
    method: str
    params: dict
    id: int = 1
    
    def to_dict(self) -> dict:
        return {
            "jsonrpc": "2.0",
            "method": self.method,
            "id": self.id,
            "params": self.params,
        }


@dataclass
class ExtractedTable:
    """Raw table data extracted from HANA."""
    schema_name: str
    table_name: str
    table_type: str
    row_count: int = 0
    columns: list[dict] = field(default_factory=list)


class HanaSchemaExtractor:
    """
    Extract schemas from HANA Cloud via AI Core PAL MCP.
    
    Uses the MCP tools:
    - hana_tables: Discover available tables
    - execute_sql: Query SYS.TABLE_COLUMNS for metadata
    """
    
    def __init__(self, config: HanaSourceConfig | None = None):
        self.config = config or HanaSourceConfig()
        self._client: httpx.AsyncClient | None = None
        self._request_id = 0
    
    @property
    def client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                timeout=self.config.timeout,
            )
        return self._client
    
    async def close(self):
        """Close the HTTP client."""
        if self._client and not self._client.is_closed:
            await self._client.aclose()
    
    def _next_request_id(self) -> int:
        self._request_id += 1
        return self._request_id
    
    async def _mcp_call(self, tool_name: str, arguments: dict) -> dict:
        """
        Make an MCP tools/call request.
        
        Args:
            tool_name: Name of the MCP tool to call
            arguments: Tool arguments
            
        Returns:
            Tool result content
        """
        request = MCPRequest(
            method="tools/call",
            params={
                "name": tool_name,
                "arguments": arguments,
            },
            id=self._next_request_id(),
        )
        
        try:
            response = await self.client.post(
                self.config.mcp_url,
                json=request.to_dict(),
                headers={"Content-Type": "application/json"},
            )
            response.raise_for_status()
            data = response.json()
            
            if "error" in data:
                error = data["error"]
                raise RuntimeError(f"MCP error {error.get('code')}: {error.get('message')}")
            
            result = data.get("result", {})
            content = result.get("content", [])
            
            # Extract text content from MCP response
            if content and isinstance(content, list):
                for item in content:
                    if item.get("type") == "text":
                        text = item.get("text", "")
                        # Try to parse as JSON
                        try:
                            return json.loads(text)
                        except json.JSONDecodeError:
                            return {"raw": text}
            
            return result
            
        except httpx.HTTPStatusError as e:
            logger.error(f"MCP request failed: {e.response.status_code} - {e.response.text}")
            raise
        except Exception as e:
            logger.error(f"MCP request error: {e}")
            raise
    
    async def discover_tables(self) -> list[dict]:
        """
        Discover available tables using hana_tables MCP tool.
        
        Returns:
            List of table info dicts
        """
        logger.info("Discovering HANA tables via MCP...")
        result = await self._mcp_call("hana_tables", {})
        
        if isinstance(result, dict) and "tables" in result:
            return result["tables"]
        elif isinstance(result, list):
            return result
        else:
            logger.warning(f"Unexpected hana_tables response: {result}")
            return []
    
    async def execute_sql(self, sql: str) -> list[dict]:
        """
        Execute SQL query on HANA Cloud.
        
        Args:
            sql: SQL query to execute
            
        Returns:
            List of result rows as dicts
        """
        logger.debug(f"Executing SQL: {sql[:100]}...")
        result = await self._mcp_call("execute_sql", {"sql": sql})
        
        if isinstance(result, dict):
            if "rows" in result:
                return result["rows"]
            elif "raw" in result:
                # Try to parse raw text as rows
                lines = result["raw"].strip().split("\n")
                if len(lines) > 1:
                    # Assume first line is headers
                    headers = [h.strip() for h in lines[0].split("|")]
                    rows = []
                    for line in lines[1:]:
                        values = [v.strip() for v in line.split("|")]
                        if len(values) == len(headers):
                            rows.append(dict(zip(headers, values)))
                    return rows
            return [result]
        elif isinstance(result, list):
            return result
        else:
            return []
    
    async def get_table_columns(self, schema: str, table: str) -> list[dict]:
        """
        Get column metadata for a specific table.
        
        Args:
            schema: Schema name
            table: Table name
            
        Returns:
            List of column metadata dicts
        """
        sql = f'''
            SELECT 
                "COLUMN_NAME",
                "DATA_TYPE_NAME",
                "LENGTH",
                "SCALE",
                "IS_NULLABLE",
                "DEFAULT_VALUE",
                "COMMENTS"
            FROM "SYS"."TABLE_COLUMNS"
            WHERE "SCHEMA_NAME" = '{schema}'
              AND "TABLE_NAME" = '{table}'
            ORDER BY "POSITION"
        '''
        return await self.execute_sql(sql)
    
    async def get_tables_in_schema(self, schema: str, pattern: str | None = None) -> list[dict]:
        """
        Get all tables in a schema.
        
        Args:
            schema: Schema name
            pattern: Optional LIKE pattern for table names
            
        Returns:
            List of table metadata dicts
        """
        sql = f'''
            SELECT 
                "SCHEMA_NAME",
                "TABLE_NAME",
                "TABLE_TYPE",
                "RECORD_COUNT"
            FROM "SYS"."TABLES"
            WHERE "SCHEMA_NAME" = '{schema}'
        '''
        
        if pattern:
            sql += f" AND \"TABLE_NAME\" LIKE '{pattern}'"
        
        sql += " ORDER BY \"TABLE_NAME\""
        
        return await self.execute_sql(sql)
    
    async def get_primary_keys(self, schema: str, table: str) -> list[str]:
        """
        Get primary key columns for a table.
        
        Args:
            schema: Schema name
            table: Table name
            
        Returns:
            List of primary key column names
        """
        sql = f'''
            SELECT "COLUMN_NAME"
            FROM "SYS"."CONSTRAINTS"
            WHERE "SCHEMA_NAME" = '{schema}'
              AND "TABLE_NAME" = '{table}'
              AND "IS_PRIMARY_KEY" = 'TRUE'
        '''
        rows = await self.execute_sql(sql)
        return [r.get("COLUMN_NAME", "") for r in rows if r.get("COLUMN_NAME")]
    
    def _infer_domain(self, schema_name: str, table_name: str) -> Domain:
        """
        Infer domain from schema/table names.
        
        Args:
            schema_name: Schema name
            table_name: Table name
            
        Returns:
            Inferred Domain enum value
        """
        name_lower = (schema_name + "_" + table_name).lower()
        
        if any(kw in name_lower for kw in ["esg", "carbon", "emission", "climate", "green"]):
            return Domain.ESG
        elif any(kw in name_lower for kw in ["treasury", "fx", "rate", "yield", "position"]):
            return Domain.TREASURY
        else:
            return Domain.PERFORMANCE
    
    def _convert_data_type(self, hana_type: str, length: int | None, scale: int | None) -> str:
        """
        Convert HANA data type to simplified type string.
        
        Args:
            hana_type: HANA data type name
            length: Column length
            scale: Column scale
            
        Returns:
            Simplified type string
        """
        hana_type = (hana_type or "").upper()
        
        if hana_type in ("NVARCHAR", "VARCHAR", "NCHAR", "CHAR"):
            if length:
                return f"VARCHAR({length})"
            return "VARCHAR"
        elif hana_type in ("INTEGER", "INT", "SMALLINT", "TINYINT", "BIGINT"):
            return "INTEGER"
        elif hana_type in ("DECIMAL", "DOUBLE", "FLOAT", "REAL"):
            if length and scale:
                return f"DECIMAL({length},{scale})"
            return "DECIMAL"
        elif hana_type in ("DATE",):
            return "DATE"
        elif hana_type in ("TIME",):
            return "TIME"
        elif hana_type in ("TIMESTAMP", "SECONDDATE"):
            return "TIMESTAMP"
        elif hana_type in ("BOOLEAN",):
            return "BOOLEAN"
        elif hana_type in ("BLOB", "CLOB", "NCLOB"):
            return "LOB"
        else:
            return hana_type or "VARCHAR"
    
    async def extract_table(self, schema: str, table: str) -> TableSchema:
        """
        Extract full metadata for a single table.
        
        Args:
            schema: Schema name
            table: Table name
            
        Returns:
            TableSchema object
        """
        # Get column metadata
        columns_data = await self.get_table_columns(schema, table)
        
        # Get primary keys
        try:
            pk_columns = await self.get_primary_keys(schema, table)
        except Exception:
            pk_columns = []
        
        pk_set = set(pk_columns)
        
        # Convert to Column objects
        columns = []
        for col in columns_data:
            col_name = col.get("COLUMN_NAME", "")
            data_type = self._convert_data_type(
                col.get("DATA_TYPE_NAME", ""),
                col.get("LENGTH"),
                col.get("SCALE"),
            )
            
            columns.append(Column(
                name=col_name,
                data_type=data_type,
                description=col.get("COMMENTS", "") or "",
                is_key=col_name in pk_set,
                nullable=col.get("IS_NULLABLE", "TRUE") == "TRUE",
            ))
        
        return TableSchema(
            name=table,
            schema_name=schema,
            domain=self._infer_domain(schema, table),
            columns=columns,
            hierarchy_levels=[],
            row_count=0,
            description=f"Table {schema}.{table}",
        )
    
    async def extract_all(self, schemas: list[str] | None = None) -> SchemaRegistry:
        """
        Extract all tables from specified schemas into a SchemaRegistry.
        
        Args:
            schemas: List of schema names (defaults to config.schemas)
            
        Returns:
            Populated SchemaRegistry
        """
        schemas = schemas or self.config.schemas
        registry = SchemaRegistry()
        
        logger.info(f"Extracting schemas: {schemas}")
        
        for schema in schemas:
            try:
                # Get all tables in schema
                tables = await self.get_tables_in_schema(
                    schema,
                    self.config.table_pattern,
                )
                
                logger.info(f"Found {len(tables)} tables in schema {schema}")
                
                # Extract each table
                for table_info in tables:
                    table_name = table_info.get("TABLE_NAME", "")
                    if not table_name:
                        continue
                    
                    try:
                        table_schema = await self.extract_table(schema, table_name)
                        
                        # Update row count if available
                        if "RECORD_COUNT" in table_info:
                            try:
                                table_schema.row_count = int(table_info["RECORD_COUNT"])
                            except (ValueError, TypeError):
                                pass
                        
                        registry.add_table(table_schema)
                        logger.debug(f"Extracted table: {schema}.{table_name} ({len(table_schema.columns)} columns)")
                        
                    except Exception as e:
                        logger.warning(f"Failed to extract table {schema}.{table_name}: {e}")
                        continue
                        
            except Exception as e:
                logger.error(f"Failed to process schema {schema}: {e}")
                continue
        
        logger.info(f"Extracted {registry.table_count()} tables total")
        return registry
    
    async def extract_to_json(self, schemas: list[str] | None = None) -> dict:
        """
        Extract schemas and return as JSON-serializable dict.
        
        Args:
            schemas: List of schema names
            
        Returns:
            Dict with tables list
        """
        registry = await self.extract_all(schemas)
        return {
            "schemas": schemas or self.config.schemas,
            "tables": registry.to_dict(),
            "table_count": registry.table_count(),
        }


async def extract_hana_schemas(
    config: HanaSourceConfig | None = None,
    schemas: list[str] | None = None,
) -> SchemaRegistry:
    """
    Convenience function to extract HANA schemas.
    
    Args:
        config: HANA source configuration
        schemas: List of schema names (overrides config)
        
    Returns:
        Populated SchemaRegistry
    """
    extractor = HanaSchemaExtractor(config)
    try:
        return await extractor.extract_all(schemas)
    finally:
        await extractor.close()


def extract_hana_schemas_sync(
    config: HanaSourceConfig | None = None,
    schemas: list[str] | None = None,
) -> SchemaRegistry:
    """Synchronous wrapper for extract_hana_schemas."""
    return asyncio.run(extract_hana_schemas(config, schemas))


# CLI for testing
if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Extract HANA schemas via MCP")
    parser.add_argument("--schemas", default="PAL_STORE", help="Comma-separated schema names")
    parser.add_argument("--mcp-url", default=None, help="MCP endpoint URL")
    parser.add_argument("--output", default=None, help="Output JSON file")
    
    args = parser.parse_args()
    
    logging.basicConfig(level=logging.INFO)
    
    config = HanaSourceConfig()
    if args.mcp_url:
        config.mcp_url = args.mcp_url
    
    schemas = [s.strip() for s in args.schemas.split(",")]
    
    async def main():
        extractor = HanaSchemaExtractor(config)
        try:
            result = await extractor.extract_to_json(schemas)
            
            if args.output:
                with open(args.output, "w") as f:
                    json.dump(result, f, indent=2)
                print(f"Saved to {args.output}")
            else:
                print(json.dumps(result, indent=2))
                
        finally:
            await extractor.close()
    
    asyncio.run(main())
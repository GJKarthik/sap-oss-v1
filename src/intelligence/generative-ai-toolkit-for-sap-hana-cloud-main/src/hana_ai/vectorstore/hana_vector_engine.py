# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
HANA vector store to save and get embeddings for hana-ml.

The following class is available:

    * :class `HANAMLinVectorEngine`
"""

#pylint: disable=no-name-in-module
#pylint: disable=redefined-builtin

import logging
import re
import pandas as pd
from hana_ml import ConnectionContext, dataframe

from hana_ai.vectorstore.code_templates import get_code_templates
from hana_ai.mangle.client import get_config_value

logger = logging.getLogger(__name__) #pylint: disable=invalid-name

_DEFAULT_MODEL_VERSION = get_config_value("default_model_version", "embedding", "SAP_NEB.20240715")

_SAFE_IDENTIFIER = re.compile(r'^[a-zA-Z_][a-zA-Z0-9_.]*$')

def _validate_identifier(name: str) -> str:
    """Validate SQL identifier to prevent injection."""
    if not name or not _SAFE_IDENTIFIER.match(name):
        raise ValueError(f"Invalid SQL identifier: {name!r}")
    return name

def _escape_sql_string(value: str, max_length: int = 10000) -> str:
    """Escape a string value for safe SQL embedding."""
    return value.replace("'", "''")[:max_length]

class HANAMLinVectorEngine(object):
    """
    HANA vector engine.

    Parameters
    ----------
    connection_context: ConnectionContext
        Connection context.
    table_name: str
        Table name.
    schema: str, optional
        Schema name. Default to None.
    model_version: str, optional
        Model version. Default to 'SAP_NEB.20240715'.
    """
    connection_context: ConnectionContext = None
    table_name: str = None
    schema: str = None
    vector_length: int = None
    columns: list = None
    def __init__(self, connection_context, table_name, schema=None, model_version=_DEFAULT_MODEL_VERSION):
        self.connection_context = connection_context
        self.table_name = table_name
        self.schema = schema
        self.model_version = _validate_identifier(model_version)
        self.current_query_distance = None
        self.current_query_rows = None
        if schema is None:
            self.schema = self.connection_context.get_current_schema()
        if not self.connection_context.has_table(table=self.table_name, schema=self.schema):
            safe_model_version = _escape_sql_string(self.model_version)
            self.connection_context.create_table(table=self.table_name,
                                                 schema=self.schema,
                                                 table_structure={"id": "VARCHAR(5000) PRIMARY KEY",
                                                                  "description": "VARCHAR(5000)",
                                                                  "example": "NCLOB",
                                                                  "embeddings": f"REAL_VECTOR GENERATED ALWAYS AS VECTOR_EMBEDDING(\"description\", 'DOCUMENT', '{safe_model_version}')"})

    def get_knowledge(self):
        """
        Get knowledge dataframe.
        """
        return self.connection_context.table(table=self.table_name, schema=self.schema)

    def create_knowledge(self, option='python'):
        """
        Create knowledge base.

        Parameters
        ----------
        option: {'python', 'sql'}, optional
            The option of language.  Default to 'python'.
        """
        self.upsert_knowledge(get_code_templates(option=option))

    def upsert_knowledge(self,
                         knowledge):
        """
        Upsert knowledge.

        Parameters
        ----------
        knowledge: dict
            Knowledge data. {'id': '1', 'description': 'description', 'example': 'example'}
        """
        dataframe.create_dataframe_from_pandas(connection_context=self.connection_context,
                                               pandas_df=pd.DataFrame(knowledge, columns=['id', 'description', 'example']),
                                               table_name=self.table_name,
                                               schema=self.schema,
                                               upsert=True,
                                               table_structure={"id": "VARCHAR(5000) PRIMARY KEY",
                                                                "description": "VARCHAR(5000)",
                                                                "example": "NCLOB",
                                                                "embeddings": f"REAL_VECTOR GENERATED ALWAYS AS VECTOR_EMBEDDING(\"description\", 'DOCUMENT', '{_escape_sql_string(self.model_version)}')"})

    def query(self, input, top_n=1, distance='cosine_similarity'):
        """
        Query.

        Parameters
        ----------
        input: str
            Input text.
        top_n: int, optional
            Top n. Default to 1.
        distance: str, optional
            Distance. Default to 'cosine_similarity'.
        """
        schema = self.schema
        if self.columns is None:
            self.columns = self.connection_context.table(table=self.table_name, schema=self.schema).columns
        if self.schema is None:
            schema = self.connection_context.get_current_schema()

        safe_input = _escape_sql_string(input)
        safe_model_version = _escape_sql_string(self.model_version)
        safe_distance = _validate_identifier(distance.upper())
        safe_schema = _validate_identifier(schema)
        safe_table = _validate_identifier(self.table_name)
        safe_col0 = _validate_identifier(self.columns[0])
        safe_col2 = _validate_identifier(self.columns[2])
        safe_col3 = _validate_identifier(self.columns[3])
        top_n = int(top_n)
        sql = """SELECT TOP {} "{}", {}("{}", TO_REAL_VECTOR(VECTOR_EMBEDDING('{}', 'QUERY', '{}'))) AS "DISTANCE", "{}" "MODEL_TYPE" FROM "{}"."{}" ORDER BY "DISTANCE" DESC""".format(top_n, safe_col2, safe_distance, safe_col3, safe_input, safe_model_version, safe_col0, safe_schema, safe_table)
        result = self.connection_context.sql(sql).collect()
        self.current_query_rows = result.shape[0]
        if self.current_query_rows < top_n:
            top_n = self.current_query_rows
        self.current_query_distance = result.iloc[top_n-1, 1]
        self.model_type = result.iloc[top_n-1, 2]
        return result.iloc[top_n-1, 0]

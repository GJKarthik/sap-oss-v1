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

logger = logging.getLogger(__name__) #pylint: disable=invalid-name

_IDENTIFIER_PATTERN = re.compile(r'^[A-Za-z0-9_]+$')
_ALLOWED_MODEL_VERSIONS = {
    'SAP_NEB.20240715',
    'SAP_GXY.20250407',
}
_ALLOWED_DISTANCE_FUNCTIONS = {
    'COSINE_SIMILARITY': 'DESC',
    'L2DISTANCE': 'ASC',
}


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

    def __init__(self, connection_context, table_name, schema=None, model_version='SAP_NEB.20240715'):
        self.connection_context = connection_context
        self.table_name = self._validate_identifier(table_name, 'table_name')
        self.schema = self._validate_identifier(schema, 'schema') if schema is not None else None
        self.model_version = self._validate_model_version(model_version)
        self.current_query_distance = None
        self.current_query_rows = None
        if schema is None:
            self.schema = self._validate_identifier(self.connection_context.get_current_schema(), 'schema')
        if not self.connection_context.has_table(table=self.table_name, schema=self.schema):
            self.connection_context.create_table(table=self.table_name,
                                                 schema=self.schema,
                                                 table_structure={"id": "VARCHAR(5000) PRIMARY KEY",
                                                                  "description": "VARCHAR(5000)",
                                                                  "example": "NCLOB",
                                                                  "embeddings": self._build_embedding_column_definition()})

    @staticmethod
    def _validate_identifier(value, field_name):
        if not isinstance(value, str) or not _IDENTIFIER_PATTERN.fullmatch(value):
            raise ValueError(field_name + ' must contain only letters, numbers, and underscores')
        return value

    @staticmethod
    def _validate_model_version(model_version):
        if model_version not in _ALLOWED_MODEL_VERSIONS:
            raise ValueError('Unsupported model_version')
        return model_version

    @staticmethod
    def _validate_top_n(top_n):
        if not isinstance(top_n, int) or top_n <= 0:
            raise ValueError('top_n must be a positive integer')
        return top_n

    @staticmethod
    def _validate_distance(distance):
        if not isinstance(distance, str):
            raise ValueError('Unsupported distance')
        normalized_distance = distance.upper()
        if normalized_distance not in _ALLOWED_DISTANCE_FUNCTIONS:
            raise ValueError('Unsupported distance')
        return normalized_distance, _ALLOWED_DISTANCE_FUNCTIONS[normalized_distance]

    def _build_embedding_column_definition(self):
        return ''.join([
            'REAL_VECTOR GENERATED ALWAYS AS VECTOR_EMBEDDING("description", \'DOCUMENT\', \'',
            self.model_version,
            "')",
        ])

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
                                                                "embeddings": self._build_embedding_column_definition()})

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
        top_n = self._validate_top_n(top_n)
        distance_function, sort_direction = self._validate_distance(distance)
        schema = self.schema
        if self.columns is None:
            self.columns = self.connection_context.table(table=self.table_name, schema=self.schema).columns
        if self.schema is None:
            schema = self._validate_identifier(self.connection_context.get_current_schema(), 'schema')

        result_column = self._validate_identifier(self.columns[2], 'result column')
        embedding_column = self._validate_identifier(self.columns[3], 'embedding column')
        model_type_column = self._validate_identifier(self.columns[0], 'model type column')

        sql = ''.join([
            'SELECT TOP ', str(top_n),
            ' "', result_column,
            '", ', distance_function,
            '("', embedding_column,
            '", TO_REAL_VECTOR(VECTOR_EMBEDDING(?, \'QUERY\', ?))) AS "DISTANCE", "',
            model_type_column,
            '" "MODEL_TYPE" FROM "', schema,
            '"."', self.table_name,
            '" ORDER BY "DISTANCE" ', sort_direction,
        ])
        result = self.connection_context.sql(sql, parameters=[input, self.model_version]).collect()
        self.current_query_rows = result.shape[0]
        if self.current_query_rows < top_n:
            top_n = self.current_query_rows
        self.current_query_distance = result.iloc[top_n-1, 1]
        self.model_type = result.iloc[top_n-1, 2]
        return result.iloc[top_n-1, 0]

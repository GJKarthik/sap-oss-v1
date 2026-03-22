# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
This module includes embedding service from local embedding model or from llm_commons

The following classes are available:

    * :class `PALModelEmbeddings`
    * :class `HANAVectorEmbeddings`
"""

# pylint: disable=redefined-builtin
# pylint: disable=unnecessary-dunder-call
# pylint: disable=unused-argument

import logging
from typing import List
import uuid

try:
    from gen_ai_hub.proxy.langchain import init_embedding_model as gen_ai_hub_embedding_model
except ImportError as exc:
    raise ImportError("Package 'sap-ai-sdk-gen[all]' is required. Install with: pip install 'sap-ai-sdk-gen[all]'") from exc

import pandas as pd
from langchain.embeddings.base import Embeddings
from hana_ml.dataframe import ConnectionContext, create_dataframe_from_pandas
from hana_ml.text.pal_embeddings import PALEmbeddings
from hana_ml.algorithms.pal.pal_base import try_drop

DEFAULT_MAX_TEXT_LENGTH = 8192
DEGENERATE_EMBEDDING_NORM_THRESHOLD = 1e-9

logger = logging.getLogger(__name__)


def _validate_single_text(text, max_text_length, input_name="Embedding input"):
    if text is None:
        raise ValueError(f"{input_name} cannot be None.")
    if not isinstance(text, str):
        raise ValueError(f"{input_name} must be a string.")
    if text == "":
        raise ValueError(f"{input_name} cannot be empty.")
    if len(text) > max_text_length:
        raise ValueError(
            f"{input_name} exceeds maximum length of {max_text_length} characters."
        )
    return text


def _validate_text_list(texts, max_text_length, input_name="Embedding input list"):
    if texts is None:
        raise ValueError(f"{input_name} cannot be None.")
    if not isinstance(texts, list):
        raise ValueError(f"{input_name} must be a list of strings.")
    if not texts:
        raise ValueError(f"{input_name} cannot be empty.")
    return [
        _validate_single_text(text, max_text_length, f"Embedding input at index {index}")
        for index, text in enumerate(texts)
    ]


def _validate_text_input(input_value, max_text_length):
    if isinstance(input_value, list):
        return _validate_text_list(input_value, max_text_length)
    return [_validate_single_text(input_value, max_text_length)]


def _normalize_embeddings(result):
    if not isinstance(result, list):
        raise ValueError("Embedding result must be a list.")
    if result and all(isinstance(value, (int, float)) for value in result):
        return [[float(value) for value in result]]

    normalized = []
    for index, vector in enumerate(result):
        if vector is None:
            raise ValueError(f"Embedding result at index {index} cannot be None.")
        try:
            normalized.append([float(value) for value in vector])
        except (TypeError, ValueError) as exc:
            raise ValueError(
                f"Embedding result at index {index} must be an iterable of numeric values."
            ) from exc
    return normalized


def _validate_embeddings(result, source):
    vectors = _normalize_embeddings(result)
    if not vectors:
        raise ValueError(f"{source} returned no embeddings.")

    expected_dimension = len(vectors[0])
    if expected_dimension == 0:
        raise ValueError(f"{source} returned an empty embedding vector.")

    for index, vector in enumerate(vectors):
        if len(vector) != expected_dimension:
            raise ValueError(
                f"{source} returned inconsistent embedding dimensions within the batch."
            )
        if any(value != value for value in vector):
            raise ValueError(f"{source} returned a NaN embedding value at index {index}.")
        if all(value == 0.0 for value in vector):
            raise ValueError(f"{source} returned an all-zero embedding vector at index {index}.")

        norm = sum(value * value for value in vector) ** 0.5
        if norm < DEGENERATE_EMBEDDING_NORM_THRESHOLD:
            logger.warning(
                "%s returned a degenerate embedding at index %s with norm %.3e",
                source,
                index,
                norm,
            )

    return vectors


def _build_cc_embed_query_statements(temporary_table: str):
    return (
        'CREATE LOCAL TEMPORARY COLUMN TABLE {} ("ID" INTEGER, "TEXT" NCLOB)'.format(temporary_table),
        'INSERT INTO {} ("ID", "TEXT") VALUES (?, ?)'.format(temporary_table),
        'SELECT "TEXT" FROM {} ORDER BY "ID"'.format(temporary_table),
    )

class PALModelEmbeddings(Embeddings):
    """
    PAL embedding model.

    Parameters
    ----------
    connection_context : ConnectionContext
        Connection context.
    model_version : str, optional
        Model version. Default to None.
    batch_size : int, optional
        Batch size. Default to None.
    thread_number : int, optional
        Thread number. Default to None.
    is_query : bool, optional
        Use different embedding model for query purpose. Default to None.
    """
    model_version: str
    connection_context: ConnectionContext
    batch_size: int
    thread_number: int
    is_query: bool

    def __init__(self, connection_context, model_version=None, batch_size=None, thread_number=None, is_query=None, max_text_length=DEFAULT_MAX_TEXT_LENGTH, **kwargs):
        """
        Init PAL embedding model.
        """
        self.model_version = model_version
        self.connection_context = connection_context
        self.batch_size = batch_size
        self.thread_number = thread_number
        self.is_query = is_query
        self.max_text_length = max_text_length
        self.kwargs = kwargs

    def __call__(self, input):
        input = _validate_text_input(input, self.max_text_length)
        pe = PALEmbeddings(self.model_version)
        temporary_table = "#PAL_EMBEDDINGS_" + str(uuid.uuid4()).replace("-", "_")
        df = create_dataframe_from_pandas(self.connection_context, pandas_df=pd.DataFrame({"ID": range(len(input)), "TEXT": input}), table_name=temporary_table, disable_progressbar=True, table_type="COLUMN")
        result = pe.fit_transform(data=df, key="ID", target="TEXT", thread_number=self.thread_number, batch_size=self.batch_size, is_query=self.is_query, **self.kwargs)
        self.model_version = pe.stat_.collect().iat[1, 1]
        result = list(map(lambda x: list(x[0]), result[result.columns[-2]].collect().to_numpy()))
        try_drop(self.connection_context, temporary_table)
        try_drop(self.connection_context, pe._fit_output_table_names)
        return _validate_embeddings(result, self.__class__.__name__)

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        """
        Embed multiple documents.

        Parameters
        ----------
        texts : List[str]
            List of texts.

        Returns
        -------
        List[List[float]]
            List of embeddings.
        """
        _validate_text_list(texts, self.max_text_length, "Embedding input list")
        return self.__call__(texts)

    def embed_query(self, text: str) -> List[float]:
        """
        Embed a single query.

        Parameters
        ----------
        text : str
            Text.

        Returns
        -------
        List[float]
            Embedding.
        """
        _validate_single_text(text, self.max_text_length, "Embedding query")
        return self.__call__(text)[0]

    def get_text_embedding_batch(self, texts: List[str], show_progress=False, **kwargs):
        """
        Get text embedding batch.

        Parameters
        ----------
        texts : List[str]
            List of texts.

        Returns
        -------
        List[List[float]]
            List of embeddings.
        """
        return self.embed_documents(texts)

class HANAVectorEmbeddings(Embeddings):
    """
    PAL embedding model.

    Parameters
    ----------
    connection_context : ConnectionContext
        Connection context.
    model_version : str, optional
        Model version.  Default to 'SAP_NEB.20240715'
    """
    model_version: str
    connection_context: ConnectionContext

    def __init__(self, connection_context, model_version='SAP_NEB.20240715', max_text_length=DEFAULT_MAX_TEXT_LENGTH):
        """
        Init PAL embedding model.
        """
        self.model_version = model_version
        self.connection_context = connection_context
        self.max_text_length = max_text_length

    def __call__(self, input):
        input = _validate_text_input(input, self.max_text_length)
        # Always get batch embeddings and coerce all values to Python float
        result = _cc_embed_query(self.connection_context, input, model_version=self.model_version)
        return _validate_embeddings(result, self.__class__.__name__)

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        """
        Embed multiple documents.

        Parameters
        ----------
        texts : List[str]
            List of texts.

        Returns
        -------
        List[List[float]]
            List of embeddings.
        """
        _validate_text_list(texts, self.max_text_length, "Embedding input list")
        return self.__call__(texts)

    def embed_query(self, text: str) -> List[float]:
        """
        Embed a single query.

        Parameters
        ----------
        text : str
            Text.

        Returns
        -------
        List[float]
            Embedding.
        """
        _validate_single_text(text, self.max_text_length, "Embedding query")
        return self.__call__(text)[0]

    def get_text_embedding_batch(self, texts: List[str], show_progress=False, **kwargs):
        """
        Get text embedding batch.

        Parameters
        ----------
        texts : List[str]
            List of texts.

        Returns
        -------
        List[List[float]]
            List of embeddings.
        """
        return self.embed_documents(texts)

class GenAIHubEmbeddings(Embeddings):
    """
    A class representing the embedding service for GenAIHub.

    Parameters
    ----------
    model_id: str
        Model ID. Defaults to 'text-embedding-ada-002'.
    """
    model: Embeddings
    def __init__(self, model_id='text-embedding-ada-002', max_text_length=DEFAULT_MAX_TEXT_LENGTH, **kwargs):
        """
        Init embedding service from llm_commons.
        """
        self.max_text_length = max_text_length
        self.model = gen_ai_hub_embedding_model(model_id, **kwargs)

    def __call__(self, input):
        if isinstance(input, list):
            texts = _validate_text_list(input, self.max_text_length)
            result = self.model.embed_documents(texts)
        else:
            text = _validate_single_text(input, self.max_text_length)
            result = [self.model.embed_query(text)]
        return _validate_embeddings(result, self.__class__.__name__)

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        """
        Embed multiple documents.

        Parameters
        ----------
        texts : List[str]
            List of texts.

        Returns
        -------
        List[List[float]]
            List of embeddings.
        """
        _validate_text_list(texts, self.max_text_length, "Embedding input list")
        return self.__call__(texts)

    def embed_query(self, text: str) -> List[float]:
        """
        Embed a single query.

        Parameters
        ----------
        text : str
            Text.

        Returns
        -------
        List[float]
            Embedding.
        """
        _validate_single_text(text, self.max_text_length, "Embedding query")
        return self.__call__(text)[0]

    def get_text_embedding_batch(self, texts: List[str], show_progress=False, **kwargs):
        """
        Get text embedding batch.

        Parameters
        ----------
        texts : List[str]
            List of texts.

        Returns
        -------
        List[List[float]]
            List of embeddings.
        """
        return self.embed_documents(texts)

def _cc_embed_query(connection_context, query, model_version='SAP_NEB.20240715'):
    """
    Create a query embedding and return a vector.

    Parameters
    ----------
    connection_context : ConnectionContext
        The HANA connection context.
    query : str or list of str
        The query to embed.
    model_version : str, optional
        Text Embedding Model version. Options are 'SAP_NEB.20240715' and 'SAP_GXY.20250407'.

        Defaults to 'SAP_NEB.20240715'.

    Returns
    -------
    list of float when query is str, list of list of float when query is list of str
    """
    # Normalize input to a list for consistent handling
    queries = list(query) if isinstance(query, (list, tuple)) else [query]

    temporary_table = "#CC_EMBED_QUERY_" + uuid.uuid4().hex.upper()
    create_sql, insert_sql, select_sql = _build_cc_embed_query_statements(temporary_table)

    try:
        with connection_context.connection.cursor() as cursor:
            cursor.execute(create_sql)
            cursor.executemany(insert_sql, list(enumerate(queries)))

        df = connection_context.sql(select_sql) \
            .add_vector("TEXT", text_type='QUERY', embed_col="EMBEDDING", model_version=model_version) \
            .select(["EMBEDDING"]).collect()
    finally:
        try_drop(connection_context, temporary_table)

    # Convert to numpy-like array of rows, then extract the vector from first column
    rows = df.to_numpy()
    vectors: List[List[float]] = []
    for row in rows:
        v = row[0]
        seq = None
        # Try common iterable conversions
        try:
            seq = list(v)
        except Exception:
            pass
        if seq is None:
            try:
                # Some vector objects expose tolist()
                seq = v.tolist()  # type: ignore[attr-defined]
            except Exception:
                pass
        if seq is None:
            # As a last resort, wrap single scalar or raise informative error
            try:
                vectors.append([float(v)])
                continue
            except Exception as exc:  # pragma: no cover
                raise ValueError(f"Unexpected embedding type from HANA: {type(v)}; value: {v}") from exc
        vectors.append([float(x) for x in seq])

    return vectors

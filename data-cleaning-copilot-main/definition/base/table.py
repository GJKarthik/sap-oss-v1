from __future__ import annotations

import os
import typing
from typing import Mapping, Sequence, Type, ClassVar

import pandera.pandas as pa
from pandera.errors import SchemaErrors
import pandas as pd
from pydantic import BaseModel, create_model

pd.options.mode.copy_on_write = True

TableColumn = tuple[str, str]  # (referenced table name, column)


class Table(pa.DataFrameModel):
    """
    Base class for Pandera‑validated tables with PK/FK metadata
    and on‑demand Pydantic row models.
    """

    _pks: ClassVar[list[str]] = []
    _fks: ClassVar[Mapping[str, TableColumn]] = {}

    def __init_subclass__(
        cls,
        *,
        primary_keys: Sequence[str] | None = None,
        foreign_keys: Mapping[str, TableColumn] | None = None,
        **kwargs,
    ):
        super().__init_subclass__(**kwargs)

        # store metadata
        cls._pks = list(primary_keys or [])
        cls._fks = dict(foreign_keys or {})

        # schema sanity checks
        missing_pk = [c for c in cls._pks if c not in cls.__annotations__]
        if missing_pk:
            raise ValueError(f"{cls.__name__}: primary key column(s) not declared: {missing_pk}")

        missing_fk = [c for c in cls._fks if c not in cls.__annotations__]
        if missing_fk:
            raise ValueError(f"{cls.__name__}: foreign key column(s) not declared: {missing_fk}")

    # public helpers
    @classmethod
    def primary_keys(cls) -> list[str]:
        return cls._pks.copy()

    @classmethod
    def foreign_keys(cls) -> Mapping[str, TableColumn]:
        return dict(cls._fks)

    @classmethod
    def columns(cls) -> dict[str, pa.Column]:
        """
        Return a mapping:
            column_name → pa.Column
        """
        schema = cls.to_schema()
        return schema.columns

    @classmethod
    def to_context(cls, table_name: str) -> "TableSchema":
        """Convert table to LLM context format."""
        from definition.llm.models import TableSchema

        schema = cls.to_schema()

        return TableSchema(
            name=table_name,
            table_schema_json=schema,
            primary_keys=cls.primary_keys(),
            foreign_keys=dict(cls.foreign_keys()),
        )

    # ──────────────────────────────────────────────────────────
    # IO helpers
    @classmethod
    def load_from_csv(
        cls, path: "str | os.PathLike[str]", delimiter: str = ",", limit: int | None = None, check_sanity: bool = True
    ) -> tuple[pd.DataFrame, SchemaErrors | None]:
        """Load a delimited text file into a DataFrame adhering to the table schema.

        Parameters
        ----------
        path:
            File path to read – forwarded to :pyfunc:`pandas.read_csv`.
        delimiter:
            Column delimiter; defaults to comma (CSV).
        limit:
            If provided, only the first *limit* rows are loaded. ``None`` means load
            the entire file.
        check_sanity:
            If *True*, validate the loaded DataFrame against the table's Pandera
            schema. Any validation problems are captured and returned in an *error
            report* rather than raising immediately.

        Returns
        -------
        (df, error_report):
            *df* is the loaded (and possibly validated) DataFrame.
            *error_report* is a mapping: ``column_name → List[str]`` describing
            validation issues. It is empty if no problems are detected or
            ``check_sanity`` is *False*.
        """
        # ── read file ──
        abs_path = os.fspath(path)
        df = pd.read_csv(
            abs_path,
            delimiter=delimiter,
            nrows=limit,
            dtype=str,  # Read all columns as strings to preserve leading zeros
            keep_default_na=True,  # Keep default NA values
            na_values=[""],  # Only treat empty strings as NA, not other common NA representations
        )

        # ── column name mapping and validation ──
        table_attrs = set(cls.__annotations__.keys())
        csv_columns = set(df.columns)

        # Create normalized lookup: normalized_name -> original_attr_name
        def normalize_name(name: str) -> str:
            """Normalize column name: remove underscores, convert to lowercase."""
            return name.replace("_", "").lower()

        attr_lookup = {normalize_name(attr): attr for attr in table_attrs}

        # Build column mapping: csv_column -> table_attr
        column_mapping = {}
        unmapped_columns = []

        for csv_col in csv_columns:
            normalized_csv = normalize_name(csv_col)
            if normalized_csv in attr_lookup:
                table_attr = attr_lookup[normalized_csv]
                column_mapping[csv_col] = table_attr
            else:
                unmapped_columns.append(csv_col)

        # Log warning about unmapped columns but don't raise error
        if unmapped_columns:
            from loguru import logger

            logger.warning(
                f"Ignoring {len(unmapped_columns)} CSV columns not defined in table schema: "
                f"{unmapped_columns[:5]}{'...' if len(unmapped_columns) > 5 else ''}"
            )

        # Rename columns to match table attributes
        df = df.rename(columns=column_mapping)

        # Keep only columns that are defined in the table schema and add missing ones as None
        table_columns = list(table_attrs)

        # Add missing columns as None/NaN
        missing_columns = [col for col in table_columns if col not in df.columns]
        if missing_columns:
            from loguru import logger

            logger.info(
                f"Adding {len(missing_columns)} missing columns as None: {missing_columns[:5]}{'...' if len(missing_columns) > 5 else ''}"
            )
            for col in missing_columns:
                df[col] = None

        # Select only the table columns in the correct order
        df = df[table_columns]

        # ── type conversion ──
        def convert_column_type(series: pd.Series, target_type) -> pd.Series:
            """Attempt to convert a pandas Series to the target type."""
            try:
                # Handle Optional types (Optional[T] is Union[T, None])
                if hasattr(target_type, "__origin__"):
                    if target_type.__origin__ is typing.Union:
                        # For Optional[T] or Union[T, None], get the non-None type
                        args = [arg for arg in target_type.__args__ if arg is not type(None)]
                        if args:
                            target_type = args[0]
                        else:
                            return series  # Can't determine target type

                # Convert common string representations of missing values to NaN
                # This handles cases where everything was read as strings initially
                na_values = ["", "NA", "NULL", "null", "NaN", "nan", "None", "<NA>"]
                # Use infer_objects to handle the downcasting behavior explicitly
                series = series.replace(na_values, pd.NA).infer_objects()

                # Handle common type conversions
                if target_type == str:
                    # For strings, ensure dtype is object/string even if all values are NA
                    # First convert to string dtype to handle any float NaN values
                    series = series.astype("object")
                    # Then convert pd.NA/NaN back to None for consistency
                    return series.where(series.notna(), None)
                elif target_type == int:
                    # Use nullable integer type to handle NaN values
                    return pd.to_numeric(series, errors="coerce").astype("Int64")
                elif target_type == float:
                    return pd.to_numeric(series, errors="coerce")
                elif target_type == bool:
                    return series.astype(bool)
                else:
                    # Try direct astype conversion for other types
                    return series.astype(target_type)

            except Exception:
                # If conversion fails, return original series unchanged
                return series

        # Apply type conversion to each column
        for col_name in df.columns:
            if col_name in cls.__annotations__:
                target_type = cls.__annotations__[col_name]
                df[col_name] = convert_column_type(df[col_name], target_type)

        error: SchemaErrors | None = None
        if check_sanity:
            try:
                df = cls.validate(df, lazy=True)
            except SchemaErrors as err:
                error = err
        return df, error

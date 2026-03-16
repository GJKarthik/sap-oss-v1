# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Create Predict Table for Time Series

The following classes are available:

    * :class `TSMakeFutureTableTool`
    * :class `TSMakeFutureTableForMassiveForecastTool`
"""

from datetime import date, datetime
import logging
import math
import numbers
import re
from typing import Optional, Type
import uuid
from pydantic import BaseModel, Field

from langchain_core.tools import BaseTool
from hana_ml import ConnectionContext

logger = logging.getLogger(__name__)

_IDENTIFIER_PATTERN = re.compile(r'^[A-Za-z0-9_]+$')
_NUMERIC_LITERAL_PATTERN = re.compile(r'^-?[0-9]+(?:\.[0-9]+)?$')
_DATETIME_LITERAL_PATTERN = re.compile(r'^[0-9T:\-+ .]+$')
_ALLOWED_INCREMENT_TYPES = {
    'SECOND': ('SECONDS', 1, 1, 'second'),
    'SECONDS': ('SECONDS', 1, 1, 'second'),
    'DAY': ('DAYS', 86400, 1, 'day'),
    'DAYS': ('DAYS', 86400, 1, 'day'),
    'WEEK': ('DAYS', 604800, 7, 'week'),
    'WEEKS': ('DAYS', 604800, 7, 'week'),
    'MONTH': ('MONTHS', 2592000, 1, 'month'),
    'MONTHS': ('MONTHS', 2592000, 1, 'month'),
    'QUARTER': ('MONTHS', 7776000, 3, 'quarter'),
    'QUARTERS': ('MONTHS', 7776000, 3, 'quarter'),
    'YEAR': ('YEARS', 31536000, 1, 'year'),
    'YEARS': ('YEARS', 31536000, 1, 'year'),
}


def _validate_identifier(value, field_name):
    if not isinstance(value, str) or not _IDENTIFIER_PATTERN.fullmatch(value):
        raise ValueError(field_name + ' must contain only letters, numbers, and underscores')
    return value


def _quote_identifier(value, field_name):
    return '"' + _validate_identifier(value, field_name) + '"'


def _validate_numeric_literal(value, field_name):
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        raise ValueError(field_name + ' must be numeric')
    if not math.isfinite(float(value)):
        raise ValueError(field_name + ' must be finite')
    text = str(int(value)) if float(value).is_integer() else str(value)
    if not _NUMERIC_LITERAL_PATTERN.fullmatch(text):
        raise ValueError(field_name + ' must be a safe numeric literal')
    return text


def _validate_datetime_literal(value):
    if isinstance(value, datetime):
        literal = value.isoformat(sep=' ')
    elif isinstance(value, date):
        literal = value.isoformat()
    else:
        literal = str(value)

    if not _DATETIME_LITERAL_PATTERN.fullmatch(literal):
        raise ValueError('forecast_start must be a safe datetime string')

    try:
        if ' ' in literal or 'T' in literal:
            datetime.fromisoformat(literal.replace(' ', 'T', 1))
        else:
            date.fromisoformat(literal)
    except ValueError as exc:
        raise ValueError('forecast_start must be a valid datetime string') from exc

    return literal


def _normalize_increment_type(increment_type, timedelta_seconds):
    if not isinstance(increment_type, str):
        raise ValueError('Unsupported increment_type')

    increment_key = increment_type.strip().upper()
    if increment_key not in _ALLOWED_INCREMENT_TYPES:
        raise ValueError('Unsupported increment_type')

    sql_increment, divisor, multiplier, interval_name = _ALLOWED_INCREMENT_TYPES[increment_key]
    step = timedelta_seconds if divisor == 1 else round(timedelta_seconds / divisor)
    if divisor != 1 and step == 0:
        raise ValueError('The interval between the training time series is less than one ' + interval_name + '.')
    return sql_increment, step * multiplier


def _format_group_literal(group, group_id_type):
    if 'INT' in group_id_type.upper():
        return _validate_numeric_literal(group, 'group')
    return "'" + _validate_identifier(str(group), 'group') + "'"


def make_future_dataframe(data, key=None, periods=1, increment_type='seconds'):
    """
    Create a new dataframe for time series prediction.

    Parameters
    ----------
    data : DataFrame, optional
        The training data contains the index.

        Defaults to the data used in the fit().

    key : str, optional
        The index defined in the training data.

        Defaults to the specified key in fit function or the data.index or the first column of the data.

    periods : int, optional
        The number of rows created in the predict dataframe.

        Defaults to 1.

    increment_type : {'seconds', 'days', 'months', 'years'}, optional
        The increment type of the time series.

        Defaults to 'seconds'.

    Returns
    -------
    DataFrame

    """

    if key is None:
        if data.index is None:
            key = data.columns[0]
        else:
            key = data.index
    key = _validate_identifier(key, 'key')
    key_sql = _quote_identifier(key, 'key')
    max_ = data.select(key).max()
    sec_max_ = data.select(key).distinct().sort_values(key, ascending=False).head(2).collect().iat[1, 0]
    delta = max_ - sec_max_
    is_int = 'INT' in data.get_table_structure()[key]
    if is_int:
        forecast_start_sql = _validate_numeric_literal(max_ + delta, 'forecast_start')
        timedelta_sql = _validate_numeric_literal(delta, 'timedelta')
    else:
        forecast_start_sql = "'" + _validate_datetime_literal(max_ + delta) + "'"
        sql_increment, normalized_timedelta = _normalize_increment_type(increment_type, delta.total_seconds())
        timedelta_sql = _validate_numeric_literal(normalized_timedelta, 'timedelta')
    timeframe = []
    for period in range(0, periods):
        period_sql = _validate_numeric_literal(period, 'period')
        if is_int:
            timeframe.append(''.join([
                'SELECT TO_INT(', forecast_start_sql, ' + ', timedelta_sql, ' * ', period_sql,
                ') AS ', key_sql, ' FROM DUMMY',
            ]))
        else:
            timeframe.append(''.join([
                'SELECT ADD_', sql_increment, '(', forecast_start_sql, ', ', timedelta_sql, ' * ', period_sql,
                ') AS ', key_sql, ' FROM DUMMY',
            ]))
    sql = ' UNION ALL '.join(timeframe)
    return data.connection_context.sql(sql).sort_values(key)

def make_future_dataframe_for_massive_forecast(data=None, key=None, group_key=None, periods=1, increment_type='seconds'):
    """
    Create a new dataframe for time series prediction.

    Parameters
    ----------
    data : DataFrame, optional
        The training data contains the index.

        Defaults to the data used in the fit().

    key : str, optional
        The index defined in the training data.

        Defaults to the specified key in fit() or the value in data.index or the PAL's default key column position.

    group_key : str, optional
        Specify the group id column.

        This parameter is only valid when ``massive`` is True.

        Defaults to the specified group_key in fit() or the first column of the dataframe.

    periods : int, optional
        The number of rows created in the predict dataframe.

        Defaults to 1.

    increment_type : {'seconds', 'days', 'months', 'years'}, optional
        The increment type of the time series.

        Defaults to 'seconds'.

    Returns
    -------
    DataFrame

    """
    if group_key is None:
        group_key = data.columns[0]
    if key is None:
        if data.index is None:
            key = data.columns[1]
        else:
            key = data.index
    group_key = _validate_identifier(group_key, 'group_key')
    key = _validate_identifier(key, 'key')
    group_key_sql = _quote_identifier(group_key, 'group_key')
    key_sql = _quote_identifier(key, 'key')
    group_id_type = data.get_table_structure()[group_key]
    group_list = data.select(group_key).distinct().collect()[group_key]
    timeframe = []
    for group in group_list:
        group_literal = _format_group_literal(group, group_id_type)
        m_data = data.filter(''.join([group_key_sql, '=', group_literal]))
        max_ = m_data.select(key).max()
        sec_max_ = m_data.select(key).distinct().sort_values(key, ascending=False).head(2).collect().iat[1, 0]
        delta = max_ - sec_max_
        is_int = 'INT' in m_data.get_table_structure()[key]
        if is_int:
            forecast_start_sql = _validate_numeric_literal(max_ + delta, 'forecast_start')
            timedelta_sql = _validate_numeric_literal(delta, 'timedelta')
        else:
            forecast_start_sql = "'" + _validate_datetime_literal(max_ + delta) + "'"
            sql_increment, normalized_timedelta = _normalize_increment_type(increment_type, delta.total_seconds())
            timedelta_sql = _validate_numeric_literal(normalized_timedelta, 'timedelta')
        for period in range(0, periods):
            period_sql = _validate_numeric_literal(period, 'period')
            if is_int:
                timeframe.append(''.join([
                    'SELECT ', group_literal, ' AS ', group_key_sql,
                    ', TO_INT(', forecast_start_sql, ' + ', timedelta_sql, ' * ', period_sql,
                    ') AS ', key_sql, ' FROM DUMMY',
                ]))
            else:
                timeframe.append(''.join([
                    'SELECT ', group_literal, ' AS ', group_key_sql,
                    ', ADD_', sql_increment, '(', forecast_start_sql, ', ', timedelta_sql, ' * ', period_sql,
                    ') AS ', key_sql, ' FROM DUMMY',
                ]))
    sql = ' UNION ALL '.join(timeframe)

    return data.connection_context.sql(sql).sort_values([group_key, key])

class MakeFutureTableToolInput(BaseModel):
    """
    The input schema for the TSMakeFutureTableTool.
    """
    train_table: str = Field(description="The name of the training table in HANA")
    train_schema: Optional[str] = Field(default=None, description="The schema of the training table, it is optional")
    key: Optional[str] = Field(default=None, description="The index defined in the training data.")
    periods: Optional[int] = Field(default=1, description="The number of rows created in the predict dataframe.")
    increment_type: Optional[str] = Field(default='seconds', description="The increment type of the time series. Options are 'seconds', 'days', 'months', 'years'.")
    predict_table: Optional[str] = Field(default=None, description="The name of the target table to store the predict dataframe in HANA")

class MakeFutureTableForMassiveForecastToolInput(BaseModel):
    """
    The input schema for the TSMakeFutureTableForMassiveForecastTool.
    """
    train_table: str = Field(description="The name of the training table in HANA")
    train_schema: Optional[str] = Field(default=None, description="The schema of the training table, it is optional")
    key: Optional[str] = Field(default=None, description="The index defined in the training data.")
    group_key: Optional[str] = Field(default=None, description="Specify the group id column.")
    periods: Optional[int] = Field(default=1, description="The number of rows created in the predict dataframe.")
    increment_type: Optional[str] = Field(default='seconds', description="The increment type of the time series. Options are 'seconds', 'days', 'months', 'years'.")
    predict_table: Optional[str] = Field(default=None, description="The name of the target table to store the predict dataframe in HANA")

class TSMakeFutureTableTool(BaseTool):
    """
    This tool creates a predict table for time series forecasting in HANA.

    Parameters
    ----------
    connection_context : ConnectionContext
        Connection context to the HANA database.

    Returns
    -------
    str
        Operation result message

    """
    name: str = "ts_make_future_table"
    """Name of the tool."""
    description: str = "Create a predict table for time series forecasting in HANA."
    """Description of the tool."""
    connection_context: ConnectionContext = None
    """Connection context to the HANA database."""
    args_schema: Type[BaseModel] = MakeFutureTableToolInput
    """Input schema of the tool."""
    return_direct: bool = False

    def __init__(
        self,
        connection_context: ConnectionContext,
        return_direct: bool = False
    ) -> None:
        super().__init__(  # type: ignore[call-arg]
            connection_context=connection_context,
            return_direct=return_direct
        )

    def _run(
        self, **kwargs
    ) -> str:
        """Use the tool."""
        # 从kwargs字典中提取参数
        train_table = kwargs.get('train_table')
        train_schema = kwargs.get('train_schema', None)
        key = kwargs.get('key', None)
        periods = kwargs.get('periods', 1)
        increment_type = kwargs.get('increment_type', 'seconds')
        # predict_table_gen from uuid
        uuid_str = str(uuid.uuid4()).replace('-', '_').upper()
        predict_table_gen = f"#FUTURE_INPUT_TABLE_{uuid_str}"
        predict_table = kwargs.get('predict_table', predict_table_gen)
        try:
            # 读取训练数据
            train_data = self.connection_context.table(train_table, schema=train_schema)
            # 创建预测数据
            predict_data = make_future_dataframe(train_data, key, periods, increment_type)
            # 将预测数据保存到HANA表中
            predict_data.smart_save(predict_table)
            return f"Successfully created the forecast input table '{predict_table}' with {periods} rows."
        except Exception as e:
            logger.error("Error creating the forecast input table: %s", str(e))
            return f"Operation failed: {str(e)}"

    async def _arun(
        self, **kwargs
    ) -> str:
        """Use the tool asynchronously."""
        return self._run(**kwargs)

class TSMakeFutureTableForMassiveForecastTool(BaseTool):
    """
    This tool creates a predict table for massive time series forecasting in HANA.

    Parameters
    ----------
    connection_context : ConnectionContext
        Connection context to the HANA database.

    Returns
    -------
    str
        Operation result message

    """
    name: str = "ts_make_future_table_for_massive_forecast"
    """Name of the tool."""
    description: str = "Create a predict table for massive time series forecasting in HANA."
    """Description of the tool."""
    connection_context: ConnectionContext = None
    """Connection context to the HANA database."""
    args_schema: Type[BaseModel] = MakeFutureTableForMassiveForecastToolInput
    """Input schema of the tool."""
    return_direct: bool = False

    def __init__(
        self,
        connection_context: ConnectionContext,
        return_direct: bool = False
    ) -> None:
        super().__init__(  # type: ignore[call-arg]
            connection_context=connection_context,
            return_direct=return_direct
        )

    def _run(
        self, **kwargs
    ) -> str:
        """Use the tool."""
        # 从kwargs字典中提取参数
        train_table = kwargs.get('train_table')
        train_schema = kwargs.get('train_schema', None)
        key = kwargs.get('key', None)
        group_key = kwargs.get('group_key', None)
        periods = kwargs.get('periods', 1)
        increment_type = kwargs.get('increment_type', 'seconds')
        # predict_table_gen from uuid
        uuid_str = str(uuid.uuid4()).replace('-', '_').upper()
        predict_table_gen = f"#FUTURE_INPUT_TABLE_{uuid_str}"
        predict_table = kwargs.get('predict_table', predict_table_gen)
        try:
            # 读取训练数据
            train_data = self.connection_context.table(train_table, schema=train_schema)
            # 创建预测数据
            predict_data = make_future_dataframe_for_massive_forecast(train_data, key, group_key, periods, increment_type)
            # 将预测数据保存到HANA表中
            predict_data.smart_save(predict_table)
            return f"Successfully created the forecast input table '{predict_table}' with {periods} rows per group."
        except Exception as e:
            logger.error("Error creating the forecast input table: %s", str(e))
            return f"Operation failed: {str(e)}"

    async def _arun(
        self, **kwargs
    ) -> str:
        """Use the tool asynchronously."""
        return self._run(**kwargs)

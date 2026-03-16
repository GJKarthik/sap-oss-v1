# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
This module contains utility functions used for agents.
"""
import json
import logging
import os
import re


logger = logging.getLogger(__name__)

DEFAULT_REQUEST_TIMEOUT = 30
REQUEST_TIMEOUT_ENV_VAR = "HANA_AI_HTTP_TIMEOUT"
_SQL_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9_]{1,128}$")


def _validate_sql_identifier(name: str) -> str:
    if not isinstance(name, str) or not _SQL_IDENTIFIER_PATTERN.fullmatch(name):
        raise ValueError(
            "SQL identifier must contain only letters, numbers, and underscores and be at most 128 characters"
        )
    return name


def _escape_sql_string_literal(value: str) -> str:
    return value.replace("'", "''")

def _get_request_timeout():
    value = os.environ.get(REQUEST_TIMEOUT_ENV_VAR)
    if not value:
        return DEFAULT_REQUEST_TIMEOUT
    try:
        if "," in value:
            parts = [p.strip() for p in value.split(",")]
            if len(parts) != 2:
                raise ValueError("Expect two comma-separated numbers for connect,read")
            return (float(parts[0]), float(parts[1]))
        return float(value)
    except Exception as exc:
        logger.warning(
            "Invalid %s value '%s': %s. Using default %s.",
            REQUEST_TIMEOUT_ENV_VAR,
            value,
            str(exc),
            DEFAULT_REQUEST_TIMEOUT,
        )
        return DEFAULT_REQUEST_TIMEOUT

def _concatenate_ai_core_certificate_string(credentials: dict) -> str:
    """
    Create a properly formatted AI Core certificate string.

    Parameters
    ----------
    credentials : dict
        The certificate string to be formatted.

    Returns
    -------
    str
        The formatted certificate string.
    """
    result = None
    key_certificate = credentials.get("key", "")
    certificate = credentials.get("certificate", "")

    if key_certificate and certificate:
        result = key_certificate + certificate

    return result

def _get_access_token(credentials: dict) -> str:
    """
    Get access token from credentials.

    Parameters
    ----------
    credentials : dict
        The credentials dictionary.

    Returns
    -------
    str
        The access token.
    """
    # Use requests library to send request
    import requests
    import urllib.parse
    import tempfile

    certurl = credentials.get("certurl")
    clientid = credentials.get("clientid")
    certificate = credentials.get("certificate", "")
    key_certificate = credentials.get("key", "")
    # Save certificate and private key to temporary files certificate.pem and private_key.pem

    with tempfile.NamedTemporaryFile(delete=False) as cert_file:
        cert_file.write(certificate.encode())
        cert_file_path = cert_file.name
    with tempfile.NamedTemporaryFile(delete=False) as key_file:
        key_file.write(key_certificate.encode())
        key_file_path = key_file.name
    token_url = urllib.parse.urljoin(certurl, "/oauth/token")
    data = {
        "grant_type": "client_credentials",
        "client_id": clientid
    }
    response = requests.post(token_url, data=data, cert=(cert_file_path, key_file_path), timeout=_get_request_timeout())
    if response.status_code == 200:
        token_data = response.json()
        access_token = token_data.get("access_token", "")
        logger.info("Successfully obtained access token.")
        # If temporary files exist, delete them
        if os.path.exists(cert_file_path):
            os.remove(cert_file_path)
        if os.path.exists(key_file_path):
            os.remove(key_file_path)
        logger.info("Temporary certificate files removed.")
        return access_token
    else:
        # Delete temporary files
        if os.path.exists(cert_file_path):
            os.remove(cert_file_path)
        if os.path.exists(key_file_path):
            os.remove(key_file_path)
        logger.info("Temporary certificate files removed.")
        raise Exception(f"Failed to get access token: {response.status_code} {response.text}")

def _get_deployment_id(credentials: dict) -> str:
    """
    Get deployment ID from credentials.

    Parameters
    ----------
    credentials : dict
        The credentials dictionary.

    Returns
    -------
    str
        The deployment ID.
    """
    import requests
    ai_api_url = credentials.get("serviceurls", {}).get("AI_API_URL")
    access_token = _get_access_token(credentials)
    headers = {
        "Authorization": f"Bearer {access_token}",
        "AI-Resource-Group": "default"
    }
    deployments_url = f"{ai_api_url}/v2/lm/deployments"
    response = requests.get(deployments_url, headers=headers, timeout=_get_request_timeout())

    if response.status_code == 200:
        deployments_data = response.json()
        logger.info("Deployments details: %s", deployments_data)
        resources = deployments_data.get("resources", [])
        if resources:
            for res in resources:
                d_id = res.get("id", None)
                if res.get("scenarioId", None) == "orchestration":
                    logger.info("Successfully obtained deployment ID: %s", d_id)
                    return d_id
        else:
            raise Exception("No deployments found.")
    else:
        raise Exception(f"Failed to get deployments: {response.status_code} {response.text}")

def _create_pse_sql_string(credentials: dict, pse_name: str) -> str:
    """
    Create PSE SQL string for AI Core credentials.

    Parameters
    ----------
    credentials : dict
        The credentials dictionary.
    pse_name : str
        The name of the PSE.

    Returns
    -------
    str
        The PSE SQL string.
    """
    validated_pse_name = _validate_sql_identifier(pse_name)
    certificate_string = _escape_sql_string_literal(
        _concatenate_ai_core_certificate_string(credentials) or ""
    )
    pse_sql = (
        "CREATE PSE "
        + validated_pse_name
        + ";\nALTER PSE "
        + validated_pse_name
        + " SET OWN CERTIFICATE '\n"
        + certificate_string
        + "';"
    )
    return pse_sql

def _create_ai_core_remote_source_sql_string(credentials: dict, remote_source_name: str, pse_name: str) -> str:
    """
    Create remote source SQL string for AI Core credentials.

    Parameters
    ----------
    credentials : dict
        The credentials dictionary.
    remote_source_name : str
        The name of the remote source.
    pse_name : str
        The name of the PSE.

    Returns
    -------
    str
        The remote source SQL string.
    """
    validated_remote_source_name = _validate_sql_identifier(remote_source_name)
    validated_pse_name = _validate_sql_identifier(pse_name)
    ai_api_url = credentials.get("serviceurls", {}).get("AI_API_URL")
    auth_url = credentials.get("certurl")
    client_id = credentials.get("clientid")
    deployment_id = _get_deployment_id(credentials)

    configuration = "\n".join([
        f"aiApiUrl={ai_api_url};",
        f"     authUrl={auth_url};",
        "     resourceGroup=default;",
        f"     deploymentId={deployment_id};",
        f"     clientId={client_id}",
    ])

    remote_source_sql = (
        "CREATE REMOTE SOURCE "
        + validated_remote_source_name
        + " ADAPTER \"sapgenaihub\" CONFIGURATION\n    '"
        + _escape_sql_string_literal(configuration)
        + "'\nWITH CREDENTIAL TYPE 'X509' PSE "
        + validated_pse_name
        + ";"
    )
    return remote_source_sql

def _execute_sql_string(connection_context, sql_string: str):
    """
    Execute SQL string on the given connection.

    Parameters
    ----------
    connection
        The database connection object.
    sql_string : str
        The SQL string to be executed.
    """
    conn = connection_context.connection
    with connection_context.connection.cursor() as cursor:
        cursor.execute(sql_string)
    conn.commit()


def _add_digicertg5_root_certificate_to_pse(connection_context, pse_name):
    cert_path = os.environ.get("DIGICERTG5_PATH")
    if cert_path is None:
        cert_path = os.path.join(os.path.dirname(__file__), "certificates", "DIGICERTG5.pem")
    certificate = None
    try:
        with open(cert_path, "r", encoding="utf-8") as cert_file:
            certificate = cert_file.read().strip()
    except Exception as exc:
        logger.warning("Failed to read DIGICERTG5.pem: %s", str(exc))
    if certificate:
        _create_certificate_and_add_to_pse(connection_context, "DIGICERTG5", certificate, pse_name)

def _add_x1root_certificate_to_pse(connection_context, pse_name):
    cert_path = os.environ.get("X1ROOT_PATH")
    if cert_path is None:
        cert_path = os.path.join(os.path.dirname(__file__), "certificates", "X1ROOT.pem")
    certificate = None
    try:
        with open(cert_path, "r", encoding="utf-8") as cert_file:
            certificate = cert_file.read().strip()
    except Exception as exc:
        logger.warning("Failed to read X1ROOT.pem: %s", str(exc))
    if certificate:
        _create_certificate_and_add_to_pse(connection_context, "X1ROOT", certificate, pse_name)

def _create_certificate_and_add_to_pse(connection_context, certificate_name, certificate_content, pse_name):
    validated_certificate_name = _validate_sql_identifier(certificate_name)
    validated_pse_name = _validate_sql_identifier(pse_name)
    escaped_certificate_content = _escape_sql_string_literal(certificate_content)
    connection_context.execute_sql(
        "CREATE CERTIFICATE " + validated_certificate_name + " FROM '" + escaped_certificate_content + "'"
    )
    connection_context.execute_sql(
        "ALTER PSE " + validated_pse_name + " ADD CERTIFICATE " + validated_certificate_name
    )

def _create_ai_core_remote_source(connection_context, credentials: dict, pse_name: str, remote_source_name: str, create_pse: bool = True):
    """
    Create PSE and remote source for AI Core credentials.

    Parameters
    ----------
    connection_context
        The database connection object.
    credentials : dict
        The credentials dictionary.
    pse_name : str
        The name of the PSE.
    remote_source_name : str
        The name of the remote source.
    """
    if create_pse:
        create_pse_sql_string = _create_pse_sql_string(credentials, pse_name)
        try:
            logger.info("Creating PSE: %s", pse_name)
            connection_context.execute_sql(create_pse_sql_string)
            _add_digicertg5_root_certificate_to_pse(connection_context, pse_name)
            _add_x1root_certificate_to_pse(connection_context, pse_name)
            logger.info("PSE created successfully.")
        except Exception as exc:
            logger.warning("Warning: Failed to create PSE: %s", str(exc))
            pass
    create_remote_source_sql_string = _create_ai_core_remote_source_sql_string(
        credentials, remote_source_name, pse_name
    )
    logger.info("Creating remote source: %s", remote_source_name)
    logger.info("Executing SQL: %s", create_remote_source_sql_string)
    try:
        _execute_sql_string(connection_context, create_remote_source_sql_string)
        logger.info("Remote source created successfully.")
    except Exception as exc:
        raise Exception("Failed to create remote source: %s" % str(exc))

def _delete_ai_core_pse(connection_context, pse_name: str, cascade: bool = True):
    """
    Drop PSE for AI Core.

    Parameters
    ----------
    connection_context
        The database connection object.
    pse_name : str
        The name of the PSE.
    cascade : bool, optional
        Whether to drop dependent objects as well. Defaults to True.
    """
    validated_pse_name = _validate_sql_identifier(pse_name)
    drop_pse_sql_string = "DROP PSE " + validated_pse_name + (" CASCADE" if cascade else "") + ";"
    try:
        _execute_sql_string(connection_context, drop_pse_sql_string)
    except Exception as exc:
        raise Exception("Failed to drop PSE: %s" % str(exc))

def _drop_ai_core_remote_source(connection_context, remote_source_name: str, cascade: bool = True):
    """
    Drop remote source for AI Core.

    Parameters
    ----------
    connection_context
        The database connection object.
    remote_source_name : str
        The name of the remote source.
    cascade : bool, optional
        Whether to drop dependent objects as well. Defaults to True.
    """
    validated_remote_source_name = _validate_sql_identifier(remote_source_name)
    drop_remote_source_sql_string = (
        "DROP REMOTE SOURCE " + validated_remote_source_name + (" CASCADE" if cascade else "") + ";"
    )
    try:
        _execute_sql_string(connection_context, drop_remote_source_sql_string)
    except Exception as exc:
        raise Exception("Failed to drop remote source: %s" % str(exc))

def _drop_certificate(connection_context, certificate_name: str):
    """
    Drop certificate from the database.

    Parameters
    ----------
    connection_context
        The database connection object.
    certificate_name : str
        The name of the certificate.
    """
    validated_certificate_name = _validate_sql_identifier(certificate_name)
    drop_certificate_sql_string = "DROP CERTIFICATE " + validated_certificate_name + ";"
    try:
        _execute_sql_string(connection_context, drop_certificate_sql_string)
    except Exception as exc:
        raise Exception("Failed to drop certificate: %s" % str(exc))

def _call_agent_sql(query: str, config: dict, schema_name: str, procedure_name: str) -> str:
    """
    Create SQL string to call an agent procedure.

    Parameters
    ----------
    query : str
        The query string.
    config : dict
        The configuration dictionary.
    schema_name : str
        The schema name where the procedure resides (e.g., "SYS", "DD_AGENT_ADMIN").
    procedure_name : str
        The procedure name to invoke (e.g., "DISCOVERY_AGENT", "DATA_AGENT_CUSTOM").

    Returns
    -------
    str
        The SQL string to call the specified procedure.
    """
    validated_schema_name = _validate_sql_identifier(schema_name)
    validated_procedure_name = _validate_sql_identifier(procedure_name)
    config_json = _escape_sql_string_literal(json.dumps(config))
    query = _escape_sql_string_literal(json.dumps(query))
    return (
        "DO\nBEGIN\nDECLARE output NCLOB;\nCALL "
        + validated_schema_name
        + "."
        + validated_procedure_name
        + "('"
        + query
        + "', '"
        + config_json
        + "', output);\nselect :output FROM DUMMY;\nEND"
    )

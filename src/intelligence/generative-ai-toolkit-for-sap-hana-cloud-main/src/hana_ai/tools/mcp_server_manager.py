# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
MCP server management: launching, stopping, and registry of MCP server instances.
"""
import sys
import logging
import threading
import time
import inspect
from typing import Optional, List, Any, Annotated

try:
    from pydantic import Field as PydField
except Exception:
    PydField = None
try:
    from typing_extensions import Doc as TxtDoc
except Exception:
    TxtDoc = None
try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "mcp"])
    from mcp.server.fastmcp import FastMCP

try:
    from fastmcp import FastMCP as FastMCPHTTP
    from fastmcp.tools import Tool as HTTPTool
except ImportError:
    try:
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "fastmcp"])
        from fastmcp import FastMCP as FastMCPHTTP
        from fastmcp.tools import Tool as HTTPTool
    except Exception:
        FastMCPHTTP = None
        HTTPTool = None

from hana_ai.tools.port_manager import is_port_available


class MCPServerManager:
    """Manages MCP server lifecycle: launching, stopping, and registry.

    Parameters
    ----------
    tools : list
        List of tool instances to register with MCP servers.
    """

    # Global registry shared across all MCPServerManager instances
    _global_mcp_servers: dict = {}
    _registry_lock: threading.Lock = threading.Lock()

    def __init__(self, tools: list):
        self._tools = tools

    def _get_tools(self) -> list:
        """Return the current tools list."""
        return self._tools

    def update_tools(self, tools: list):
        """Update the tools list used when launching new servers."""
        self._tools = tools

    def launch(
        self,
        server_name: str = "HANATools",
        host: str = "127.0.0.1",
        transport: str = "stdio",
        port: int = 8001,
        auth_token: Optional[str] = None,
        max_retries: int = 5,
    ):
        """
        Launch the MCP server with the specified configuration.

        This method initializes the MCP server, registers all tools, and starts
        the server in a background thread. If the specified port is occupied, it
        will try the next port up to ``max_retries`` times.

        Parameters
        ----------
        server_name : str
            Name of the server. Default is "HANATools".
        host : str
            Host address for the server.
        transport : {"stdio", "sse", "http"}
            Transport protocol to use. Default is "stdio".
        port : int
            Network port for SSE/HTTP transports. Default is 8001. Ignored for stdio.
        auth_token : str, optional
            Authentication token for the server.
        max_retries : int
            Maximum number of retries to find an available port. Default is 5.
        """
        attempts = 0
        original_port = port

        while attempts < max_retries:
            # Initialize MCP configuration
            server_settings = {
                "name": server_name,
                "host": host,
            }

            # Update port settings
            if transport == "sse":
                # Check port availability
                if not is_port_available(port, host):
                    logging.warning("Port %s occupied, trying next port", port)
                    port += 1
                    attempts += 1
                    time.sleep(0.2)
                    continue

                server_settings.update({
                    "port": port,
                    "sse_path": "/sse",
                })

            # Create MCP instance (stdio/sse use mcp.server.fastmcp; http uses fastmcp)
            if transport == "http":
                if FastMCPHTTP is None or HTTPTool is None:
                    logging.error("HTTP transport requested but 'fastmcp' package is unavailable.")
                    raise RuntimeError("HTTP transport not supported (fastmcp missing)")
                # Build HTTP Tool list with explicit inputSchema
                pre_tools = []
                for tool in self._get_tools():
                    if hasattr(tool, "args_schema") and tool.args_schema:
                        try:
                            schema = None
                            if hasattr(tool.args_schema, "model_json_schema"):
                                schema = tool.args_schema.model_json_schema(by_alias=True)
                            elif hasattr(tool.args_schema, "schema"):
                                schema = tool.args_schema.schema(by_alias=True)
                            if schema is None:
                                continue
                            http_tool = HTTPTool(
                                name=tool.name,
                                title=getattr(tool, "name", None),
                                description=getattr(tool, "description", "") or tool.name,
                                parameters=schema,
                            )
                            pre_tools.append(http_tool)
                        except Exception as exc:
                            logging.warning("Failed to build explicit schema for %s: %s", tool.name, exc)
                # fastmcp constructor takes name as positional arg and supports tools list
                mcp = FastMCPHTTP(
                    server_settings.get("name", "HANATools"),
                    tools=pre_tools,
                    host=server_settings.get("host", "127.0.0.1"),
                    port=port,
                    streamable_http_path="/mcp",
                    json_response=True,
                )
                # Check port availability
                if not is_port_available(port, host):
                    logging.warning("Port %s occupied, trying next port", port)
                    port += 1
                    attempts += 1
                    time.sleep(0.2)
                    continue
            else:
                mcp = FastMCP(**server_settings)

            # Retrieve and register all tools
            tools = self._get_tools()
            registered_tools = []
            for tool in tools:
                # Build a wrapper with real parameter signatures and descriptions
                tool_wrapper = self._build_tool_wrapper(tool)

                # Register with MCP (all transports register the wrapper;
                # non-HTTP additionally overrides the schema)
                mcp.tool()(tool_wrapper)
                if transport != "http":
                    self._override_schema(mcp, tool)
                registered_tools.append(tool.name)
                try:
                    param_list = list(
                        getattr(tool_wrapper, "__signature__", inspect.Signature()).parameters.keys()
                    )
                except Exception:
                    param_list = []
                logging.info("Registered tool: %s", tool.name)
                logging.debug("Params for %s: %s", tool.name, ", ".join(param_list))

            # Server configuration
            server_args = {"transport": transport}
            if transport == "stdio" and not hasattr(sys.stdout, "buffer"):
                logging.warning("Unsupported stdio, switching to SSE")
                transport = "sse"
                port = original_port  # Reset port for retry
                attempts = 0
                continue

            if auth_token:
                server_args["auth_token"] = auth_token
                logging.info("Authentication enabled")

            # Start server thread
            def run_server(mcp_instance, run_args, run_host, run_port):
                try:
                    logging.info("Starting MCP server on port %s...", run_port)
                    if run_args.get("transport") == "http":
                        mcp_instance.run(
                            transport="http",
                            host=run_host,
                            port=run_port,
                            path="/mcp",
                            json_response=True,
                        )
                    else:
                        mcp_instance.run(**run_args)
                except Exception as exc:
                    logging.error("Server crashed: %s", str(exc))

            logging.info("Starting MCP server in background thread...")
            server_thread = threading.Thread(
                target=run_server,
                args=(mcp, server_args, server_settings.get("host", "127.0.0.1"), port),
                name=f"MCP-Server-Port-{port}",
                daemon=True,
            )
            server_thread.start()
            logging.info("MCP server started on port %s with tools: %s", port, registered_tools)

            # Record server instance and thread for later shutdown
            key = (server_settings.get("host", "127.0.0.1"), port, transport)
            with MCPServerManager._registry_lock:
                MCPServerManager._global_mcp_servers[key] = {
                    "instance": mcp,
                    "thread": server_thread,
                    "name": server_settings.get("name", server_name),
                    "host": server_settings.get("host", "127.0.0.1"),
                    "port": port,
                    "transport": transport,
                }
            logging.debug("Registered MCP server in registry: %s", key)
            return  # Successfully started

        # All attempts failed
        logging.error("Failed to start server after %s attempts", max_retries)
        raise RuntimeError(
            f"Could not find available port in range {original_port}-{original_port + max_retries}"
        )

    # ------------------------------------------------------------------
    # Tool wrapper helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _build_tool_wrapper(tool):
        """Build a wrapper function with proper signature and annotations for an MCP tool."""

        def _exec_wrapper(wrapped_tool):
            def _inner(**kwargs):
                try:
                    return wrapped_tool._run(**kwargs)
                except Exception as exc:
                    logging.error("Tool %s failed: %s", wrapped_tool.name, str(exc))
                    return {"error": str(exc), "tool": wrapped_tool.name}
            return _inner

        tool_wrapper = _exec_wrapper(tool)
        tool_wrapper.__name__ = tool.name
        tool_wrapper.__doc__ = tool.description

        # Derive parameter signature and annotations from Pydantic args_schema
        parameters = []
        annotations: dict[str, Any] = {}
        required_fields: list = []

        if hasattr(tool, "args_schema") and tool.args_schema:
            schema_model = tool.args_schema
            # Get required list (compatible with pydantic v1/v2)
            try:
                if hasattr(schema_model, "model_json_schema"):
                    json_schema = schema_model.model_json_schema()
                    required_fields = json_schema.get("required", []) or []
                elif hasattr(schema_model, "schema"):
                    json_schema = schema_model.schema()
                    required_fields = json_schema.get("required", []) or []
            except Exception:
                required_fields = []

            # Extract field list with type/description/default
            if hasattr(schema_model, "model_fields"):
                # pydantic v2
                for field_name, field_info in schema_model.model_fields.items():
                    field_type = getattr(field_info, "annotation", Any)
                    field_desc = getattr(field_info, "description", None)
                    # Use Annotated to inject description
                    if field_desc and PydField is not None:
                        annotated_type = Annotated[field_type, PydField(description=field_desc)]
                    elif field_desc and TxtDoc is not None:
                        annotated_type = Annotated[field_type, TxtDoc(field_desc)]
                    else:
                        annotated_type = field_type

                    annotations[field_name] = annotated_type

                    # Default value: required fields have no default
                    default_exists = hasattr(field_info, "default")
                    if field_name in required_fields:
                        param = inspect.Parameter(
                            field_name,
                            kind=inspect.Parameter.KEYWORD_ONLY,
                            default=inspect._empty,
                        )
                    else:
                        default_value = getattr(field_info, "default", None) if default_exists else None
                        param = inspect.Parameter(
                            field_name,
                            kind=inspect.Parameter.KEYWORD_ONLY,
                            default=default_value,
                        )
                    parameters.append(param)

            elif hasattr(schema_model, "__fields__"):
                # pydantic v1
                for field_name, model_field in schema_model.__fields__.items():
                    field_type = (
                        model_field.outer_type_
                        if hasattr(model_field, "outer_type_")
                        else model_field.type_
                        if hasattr(model_field, "type_")
                        else Any
                    )
                    field_desc = None
                    try:
                        field_desc = getattr(model_field.field_info, "description", None)
                    except Exception:
                        field_desc = None

                    if field_desc and PydField is not None:
                        annotated_type = Annotated[field_type, PydField(description=field_desc)]
                    elif field_desc and TxtDoc is not None:
                        annotated_type = Annotated[field_type, TxtDoc(field_desc)]
                    else:
                        annotated_type = field_type

                    annotations[field_name] = annotated_type

                    # Required check: prefer required list, fall back to model_field.required
                    is_required = field_name in required_fields
                    if not is_required:
                        try:
                            is_required = bool(getattr(model_field, "required", False))
                        except Exception:
                            is_required = False

                    if is_required:
                        param = inspect.Parameter(
                            field_name,
                            kind=inspect.Parameter.KEYWORD_ONLY,
                            default=inspect._empty,
                        )
                    else:
                        default_value = None
                        try:
                            default_value = model_field.default if hasattr(model_field, "default") else None
                        except Exception:
                            default_value = None
                        param = inspect.Parameter(
                            field_name,
                            kind=inspect.Parameter.KEYWORD_ONLY,
                            default=default_value,
                        )
                    parameters.append(param)

        # Apply signature and annotations to wrapper
        if parameters:
            sig = inspect.Signature(parameters=parameters)
            try:
                tool_wrapper.__signature__ = sig
            except Exception:
                pass
        if annotations:
            tool_wrapper.__annotations__ = annotations

        return tool_wrapper

    @staticmethod
    def _override_schema(mcp, tool):
        """Override the MCP tool's parameter schema with the explicit Pydantic JSON schema."""
        try:
            explicit_schema = None
            if hasattr(tool, "args_schema") and tool.args_schema:
                if hasattr(tool.args_schema, "model_json_schema"):
                    explicit_schema = tool.args_schema.model_json_schema(by_alias=True)
                elif hasattr(tool.args_schema, "schema"):
                    explicit_schema = tool.args_schema.schema(by_alias=True)
            if explicit_schema:
                # Get internal Tool and override parameters (list_tools will return this schema)
                info = getattr(mcp, "_tool_manager", None)
                if info is not None:
                    internal_tool = info.get_tool(tool.name)
                    if internal_tool is not None:
                        internal_tool.parameters = explicit_schema
                        logging.debug("Overrode schema for %s", tool.name)
        except Exception as exc:
            logging.warning("Failed to override schema for %s: %s", tool.name, exc)

    # ------------------------------------------------------------------
    # Stop helpers
    # ------------------------------------------------------------------

    def stop(
        self,
        host: str = "127.0.0.1",
        port: int = 8001,
        transport: str = "sse",
        force: bool = False,
        timeout: float = 5.0,
    ) -> bool:
        """
        Stop the MCP server at the specified address and port.

        Parameters
        ----------
        host : str
            MCP server host address.
        port : int
            MCP server port (also used as registration key for stdio transport).
        transport : {"stdio", "sse", "http"}
            Transport type, must match the one used at launch.
        force : bool
            Whether to attempt forceful shutdown if graceful shutdown fails.
        timeout : float
            Maximum seconds to wait for the server thread to exit.

        Returns
        -------
        bool
            True if the server was successfully stopped within the timeout, False otherwise.
        """
        key = (host, port, transport)
        with MCPServerManager._registry_lock:
            info = MCPServerManager._global_mcp_servers.get(key)
        if not info:
            logging.warning("No MCP server found for %s", key)
            return False

        mcp_instance = info.get("instance")
        server_thread: threading.Thread = info.get("thread")

        # Try graceful shutdown via common method names
        stopped_gracefully = False
        for meth_name in ("shutdown", "stop", "close"):
            meth = getattr(mcp_instance, meth_name, None)
            if callable(meth):
                logging.info("Attempting graceful '%s' on MCP server %s", meth_name, key)
                try:
                    meth()
                    stopped_gracefully = True
                    break
                except Exception as exc:
                    logging.warning("'%s' failed for %s: %s", meth_name, key, exc)

        # Wait for thread exit
        if server_thread and server_thread.is_alive():
            try:
                server_thread.join(timeout)
            except Exception:
                pass

        # If still alive and force requested, attempt best-effort termination hooks
        if server_thread and server_thread.is_alive() and force:
            logging.warning(
                "Server thread still alive after graceful attempt; trying forceful shutdown for %s", key
            )
            for attr in ("shutdown_event", "stop_event"):
                event = getattr(mcp_instance, attr, None)
                if event:
                    try:
                        event.set()
                    except Exception:
                        pass
            try:
                server_thread.join(timeout)
            except Exception:
                pass

        alive = server_thread.is_alive() if server_thread else False
        success = stopped_gracefully and not alive

        # Only remove from registry when server has actually stopped
        if success or (not alive):
            with MCPServerManager._registry_lock:
                MCPServerManager._global_mcp_servers.pop(key, None)
            if success:
                logging.info("MCP server stopped: %s", key)
            else:
                logging.info("MCP server already stopped: %s", key)
        else:
            logging.warning("MCP server may still be running: %s", key)
        return success

    def stop_all(self, force: bool = False, timeout: float = 5.0) -> int:
        """
        Stop all registered MCP servers.

        Parameters
        ----------
        force : bool
            Whether to attempt forceful shutdown if graceful shutdown fails.
        timeout : float
            Maximum seconds to wait per server thread.

        Returns
        -------
        int
            Number of servers successfully stopped.
        """
        with MCPServerManager._registry_lock:
            keys = list(MCPServerManager._global_mcp_servers.keys())
        success_count = 0
        for server_host, server_port, server_transport in keys:
            if self.stop(host=server_host, port=server_port, transport=server_transport, force=force, timeout=timeout):
                success_count += 1
        logging.info("Stopped %s MCP servers", success_count)
        return success_count

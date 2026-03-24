#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import base64
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from typing import Any
from urllib.parse import urlencode
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

import websockets

REPO_ROOT = Path(__file__).resolve().parents[1]
API_ROOT = REPO_ROOT / "packages" / "api-server"
API_PYTHON = API_ROOT / ".venv" / "bin" / "python"
NX_SAFE = REPO_ROOT / "scripts" / "nx-safe.sh"
FRONTEND_HOST = os.environ.get("E2E_FRONTEND_HOST", "127.0.0.1")
BACKEND_HOST = os.environ.get("E2E_BACKEND_HOST", "127.0.0.1")
DEFAULT_FRONTEND_PORT = 4200
DEFAULT_BACKEND_PORT = 8000
DEFAULT_CHROME_DEBUG_PORT = 9222
UI_WAIT_SECONDS = float(os.environ.get("E2E_UI_WAIT_SECONDS", "90.0"))
LOGIN_MODE = os.environ.get("E2E_LOGIN_MODE", "component").strip().lower()
ROUTES_TO_CHECK = [
    ("/dashboard", "Dashboard"),
    ("/deployments", "Deployments"),
    ("/streaming", "Streaming Sessions"),
    ("/governance", "Governance Rules"),
    ("/data", "Data Explorer"),
    ("/lineage", "Data Lineage"),
    ("/playground", "Prompt Playground"),
    ("/rag", "RAG Studio"),
]
CHROME_CANDIDATES = [
    Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
]
SUPPORTED_LOGIN_MODES = {"api", "component", "ui"}


class ManagedProcess:
    def __init__(self, name: str, process: subprocess.Popen[str], log_path: Path) -> None:
        self.name = name
        self.process = process
        self.log_path = log_path

    def stop(self) -> None:
        if self.process.poll() is not None:
            return

        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)


class CDPSession:
    def __init__(self, websocket_url: str) -> None:
        self.websocket_url = websocket_url
        self.websocket: websockets.WebSocketClientProtocol | None = None
        self._receiver: asyncio.Task[None] | None = None
        self._next_id = 0
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}
        self.console_errors: list[str] = []
        self.runtime_exceptions: list[str] = []
        self.request_failures: list[str] = []
        self.http_error_responses: list[str] = []
        self._request_urls: dict[str, str] = {}

    async def connect(self) -> None:
        self.websocket = await websockets.connect(self.websocket_url, max_size=10_000_000)
        self._receiver = asyncio.create_task(self._receive_loop())

    async def close(self) -> None:
        if self.websocket is not None:
            await self.websocket.close()
        if self._receiver is not None:
            await self._receiver

    async def _receive_loop(self) -> None:
        assert self.websocket is not None
        async for raw_message in self.websocket:
            message = json.loads(raw_message)
            if "id" in message:
                future = self._pending.pop(message["id"], None)
                if future is None or future.done():
                    continue
                if "error" in message:
                    future.set_exception(RuntimeError(json.dumps(message["error"])))
                else:
                    future.set_result(message.get("result", {}))
                continue

            method = message.get("method")
            params = message.get("params", {})
            if method == "Runtime.consoleAPICalled" and params.get("type") == "error":
                text = " ".join(
                    str(arg.get("value") or arg.get("description") or "")
                    for arg in params.get("args", [])
                ).strip()
                if text:
                    self.console_errors.append(text)
            elif method == "Runtime.exceptionThrown":
                details = params.get("exceptionDetails", {})
                exception_text = details.get("text") or details.get("exception", {}).get("description")
                if exception_text:
                    self.runtime_exceptions.append(str(exception_text))
            elif method == "Log.entryAdded":
                entry = params.get("entry", {})
                if entry.get("level") == "error" and entry.get("text"):
                    self.console_errors.append(str(entry["text"]))
            elif method == "Network.requestWillBeSent":
                self._request_urls[params.get("requestId", "")] = params.get("request", {}).get("url", "")
            elif method == "Network.loadingFailed":
                request_type = params.get("type")
                if request_type not in {"Document", "Fetch", "XHR"}:
                    continue
                url = self._request_urls.get(params.get("requestId", ""), "")
                if url.endswith("/favicon.ico"):
                    continue
                message_text = f"{request_type} {url} {params.get('errorText', 'unknown error')}"
                self.request_failures.append(message_text.strip())
            elif method == "Network.responseReceived":
                request_type = params.get("type")
                if request_type not in {"Document", "Fetch", "XHR"}:
                    continue
                response = params.get("response", {})
                status = int(response.get("status", 0))
                url = str(response.get("url", ""))
                if status < 400 or url.endswith("/favicon.ico"):
                    continue
                self.http_error_responses.append(f"{request_type} {url} HTTP {status}")

    async def send(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        assert self.websocket is not None
        self._next_id += 1
        message_id = self._next_id
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[message_id] = future
        await self.websocket.send(json.dumps({
            "id": message_id,
            "method": method,
            "params": params or {},
        }))
        return await future

    async def enable_domains(self) -> None:
        await self.send("Page.enable")
        await self.send("Runtime.enable")
        await self.send("Network.enable")
        await self.send("Log.enable")

    async def evaluate(self, expression: str) -> Any:
        result = await self.send(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": True,
            },
        )
        if "exceptionDetails" in result:
            raise RuntimeError(str(result["exceptionDetails"]))
        return result.get("result", {}).get("value")

    async def insert_text(self, text: str) -> None:
        await self.send("Input.insertText", {"text": text})

    async def wait_for(self, condition: str, timeout_seconds: float = 30.0) -> None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if await self.evaluate(condition):
                return
            await asyncio.sleep(0.2)
        raise TimeoutError(f"Timed out waiting for condition: {condition}")

    async def navigate(self, url: str) -> None:
        await self.send("Page.navigate", {"url": url})
        await self.wait_for("document.readyState === 'complete'", timeout_seconds=30.0)

    async def screenshot(self, target_path: Path) -> None:
        result = await self.send("Page.captureScreenshot", {"format": "png"})
        target_path.write_bytes(base64.b64decode(result["data"]))


def find_chrome_binary() -> Path:
    for candidate in CHROME_CANDIDATES:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("Google Chrome or Chromium was not found in /Applications")


def start_process(name: str, command: list[str], cwd: Path, env: dict[str, str], log_path: Path) -> ManagedProcess:
    log_file = log_path.open("w", encoding="utf-8")
    try:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
    finally:
        log_file.close()
    return ManagedProcess(name=name, process=process, log_path=log_path)


def fetch_json(url: str) -> Any:
    with urlopen(url, timeout=3) as response:
        return json.loads(response.read().decode("utf-8"))


def choose_port(host: str, env_name: str, default_port: int) -> int:
    if env_name in os.environ:
        return int(os.environ[env_name])

    for candidate in (default_port, 0):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind((host, candidate))
            except OSError:
                continue
            return int(sock.getsockname()[1])
    raise RuntimeError(f"Unable to allocate a free port for {env_name}")


def write_proxy_config(proxy_config_path: Path, backend_base_url: str) -> None:
    proxy_config_path.write_text(
        json.dumps(
            {
                "/api": {
                    "target": backend_base_url,
                    "secure": False,
                    "changeOrigin": True,
                    "logLevel": "warn",
                    "proxyTimeout": 60000,
                    "timeout": 60000,
                }
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def login_via_api(backend_base_url: str) -> dict[str, Any]:
    payload = urlencode({
        "username": "admin",
        "password": "changeme",
    }).encode("utf-8")
    request = Request(
        f"{backend_base_url}/api/v1/auth/login",
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def wait_for_http(
    url: str,
    expected_text: str | None = None,
    timeout_seconds: float = 90.0,
    request_timeout_seconds: float = 10.0,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with urlopen(url, timeout=request_timeout_seconds) as response:
                body = response.read().decode("utf-8", errors="replace")
                if expected_text is None or expected_text in body:
                    return
        except (HTTPError, URLError, TimeoutError) as exc:
            last_error = exc
        time.sleep(0.5)
    raise TimeoutError(f"Timed out waiting for {url}: {last_error}")


def wait_for_chrome_target(chrome_debug_port: int, timeout_seconds: float = 30.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            targets = fetch_json(f"http://127.0.0.1:{chrome_debug_port}/json/list")
            for target in targets:
                if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
                    return str(target["webSocketDebuggerUrl"])
        except Exception:
            pass
        time.sleep(0.2)
    raise TimeoutError("Timed out waiting for a Chrome DevTools page target")


async def login_via_component(session: CDPSession) -> None:
    login_script = """
(() => {
  const host = document.querySelector('app-login');
  const ngApi = window.ng;
  if (!host || !ngApi?.getComponent) {
    return false;
  }
  const component = ngApi.getComponent(host);
  if (!component || typeof component.login !== 'function') {
    return false;
  }
  component.username = 'admin';
  component.password = 'changeme';
  component.loading = false;
  component.error = '';
  component.login();
  return true;
})()
"""
    if not await session.evaluate(login_script):
        raise RuntimeError("Failed to drive the Angular login component")

    await session.wait_for(
        "location.pathname === '/dashboard' || document.body.innerText.includes('Invalid credentials')",
        timeout_seconds=UI_WAIT_SECONDS,
    )
    if await session.evaluate("location.pathname !== '/dashboard'"):
        raise RuntimeError("Angular login component did not navigate to dashboard")


async def logout_via_browser_api(session: CDPSession) -> bool:
    logout_script = """
(async () => {
  const accessToken = localStorage.getItem('auth_token');
  const refreshToken = localStorage.getItem('refresh_token');

  try {
    if (accessToken || refreshToken) {
      await fetch('/api/v1/auth/logout', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
        },
        body: JSON.stringify(refreshToken ? { refresh_token: refreshToken } : {}),
      });
    }
  } catch (error) {
    console.warn('Browser logout request failed during smoke test', error);
  }

  localStorage.removeItem('auth_token');
  localStorage.removeItem('refresh_token');
  localStorage.removeItem('user');
  location.assign('/login');
  return true;
})()
"""
    return bool(await session.evaluate(logout_script))


async def run_browser_flow(
    frontend_base_url: str,
    backend_base_url: str,
    chrome_debug_port: int,
    artifact_dir: Path,
) -> dict[str, Any]:
    websocket_url = wait_for_chrome_target(chrome_debug_port)
    session = CDPSession(websocket_url)
    await session.connect()
    try:
        await session.enable_domains()
        await session.navigate(f"{frontend_base_url}/login")
        await session.wait_for("document.body && document.body.innerText.includes('Sign In')")
        await session.screenshot(artifact_dir / "01-login.png")

        if LOGIN_MODE == "api":
            tokens = login_via_api(backend_base_url)
            inject_session = f"""
(() => {{
  localStorage.setItem('auth_token', {json.dumps(tokens['access_token'])});
  localStorage.setItem('refresh_token', {json.dumps(tokens['refresh_token'])});
  localStorage.setItem('user', JSON.stringify({{
    username: 'admin',
    role: 'admin',
    email: 'admin@sap-ai-fabric.local',
  }}));
  return true;
}})()
"""
            if not await session.evaluate(inject_session):
                raise RuntimeError("Failed to inject the authenticated browser session")
            await session.navigate(f"{frontend_base_url}/dashboard")
        elif LOGIN_MODE == "component":
            await login_via_component(session)
        else:
            focus_username = """
(() => {
  const inner = document.querySelectorAll('ui5-input')[0]?.shadowRoot?.querySelector('input');
  if (!inner) {
    return false;
  }
  inner.focus();
  return true;
})()
"""
            if not await session.evaluate(focus_username):
                raise RuntimeError("Failed to focus the username input")
            await session.insert_text("admin")
            await session.evaluate("""
(() => {
  const host = document.querySelectorAll('ui5-input')[0];
  const inner = host?.shadowRoot?.querySelector('input');
  if (!host || !inner) {
    return false;
  }
  host.value = inner.value;
  host.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  host.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  return true;
})()
""")

            focus_password = """
(() => {
  const inner = document.querySelectorAll('ui5-input')[1]?.shadowRoot?.querySelector('input');
  if (!inner) {
    return false;
  }
  inner.focus();
  return true;
})()
"""
            if not await session.evaluate(focus_password):
                raise RuntimeError("Failed to focus the password input")
            await session.insert_text("changeme")
            await session.evaluate("""
(() => {
  const host = document.querySelectorAll('ui5-input')[1];
  const inner = host?.shadowRoot?.querySelector('input');
  if (!host || !inner) {
    return false;
  }
  host.value = inner.value;
  host.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  host.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  return true;
})()
""")

            submit_login = """
(() => {
  const passwordInput = document.querySelectorAll('ui5-input')[1]?.shadowRoot?.querySelector('input');
  if (passwordInput) {
    passwordInput.blur();
  }
  const button = Array.from(document.querySelectorAll('ui5-button')).find(node => node.textContent?.includes('Sign In'));
  if (!button) {
    return false;
  }
  const innerButton = button.shadowRoot?.querySelector('button');
  if (innerButton) {
    innerButton.click();
  } else {
    button.click();
  }
  return true;
})()
"""
            if not await session.evaluate(submit_login):
                raise RuntimeError("Failed to find and submit the login form")

            await session.wait_for(
                "location.pathname === '/dashboard' || document.body.innerText.includes('Invalid credentials')",
                timeout_seconds=UI_WAIT_SECONDS,
            )
            if await session.evaluate("location.pathname !== '/dashboard'"):
                await session.screenshot(artifact_dir / "02-login-error.png")
                login_page_text = await session.evaluate("document.body.innerText")
                raise RuntimeError(f"Login did not navigate to dashboard. Page text: {login_page_text}")

        await session.wait_for("document.body.innerText.includes('Dashboard')", timeout_seconds=UI_WAIT_SECONDS)
        await session.screenshot(artifact_dir / "02-dashboard.png")

        for index, (route, text) in enumerate(ROUTES_TO_CHECK[1:], start=3):
            await session.navigate(f"{frontend_base_url}{route}")
            await session.wait_for(
                f"location.pathname === {json.dumps(route)}",
                timeout_seconds=UI_WAIT_SECONDS,
            )
            await session.wait_for(
                f"document.body.innerText.includes({json.dumps(text)})",
                timeout_seconds=UI_WAIT_SECONDS,
            )
            await session.screenshot(artifact_dir / f"{index:02d}-{route.strip('/').replace('/', '-')}.png")

        fallback_logout_script = """
(() => {
  const logoutItem = Array.from(document.querySelectorAll('ui5-side-navigation-item'))
    .find(node => node.getAttribute('text') === 'Logout' || node.textContent?.includes('Logout'));
  if (!logoutItem) {
    return false;
  }
  logoutItem.click();
  return true;
})()
"""
        if not await logout_via_browser_api(session) and not await session.evaluate(fallback_logout_script):
            raise RuntimeError("Failed to trigger the logout action")

        await session.wait_for("location.pathname === '/login'", timeout_seconds=UI_WAIT_SECONDS)
        await session.screenshot(artifact_dir / "10-logout.png")

        return {
            "console_errors": session.console_errors,
            "runtime_exceptions": session.runtime_exceptions,
            "request_failures": session.request_failures,
            "http_error_responses": session.http_error_responses,
        }
    finally:
        await session.close()


def main() -> int:
    if not API_PYTHON.exists():
        print(f"Missing backend virtualenv interpreter: {API_PYTHON}", file=sys.stderr)
        return 1
    if not NX_SAFE.exists():
        print(f"Missing Nx wrapper script: {NX_SAFE}", file=sys.stderr)
        return 1
    if LOGIN_MODE not in SUPPORTED_LOGIN_MODES:
        print(
            f"Unsupported E2E_LOGIN_MODE={LOGIN_MODE!r}. Use one of: {', '.join(sorted(SUPPORTED_LOGIN_MODES))}.",
            file=sys.stderr,
        )
        return 1

    chrome_binary = find_chrome_binary()
    temp_root = Path(tempfile.mkdtemp(prefix="sap-ai-fabric-console-e2e-"))
    artifact_dir = temp_root / "artifacts"
    artifact_dir.mkdir(parents=True, exist_ok=True)
    db_path = temp_root / "sap-ai-fabric-console-e2e.sqlite3"
    chrome_profile = temp_root / "chrome-profile"
    proxy_config_path = temp_root / "proxy.conf.json"
    processes: list[ManagedProcess] = []
    frontend_port = choose_port(FRONTEND_HOST, "E2E_FRONTEND_PORT", DEFAULT_FRONTEND_PORT)
    backend_port = choose_port(BACKEND_HOST, "E2E_BACKEND_PORT", DEFAULT_BACKEND_PORT)
    chrome_debug_port = choose_port("127.0.0.1", "E2E_CHROME_DEBUG_PORT", DEFAULT_CHROME_DEBUG_PORT)
    backend_base_url = f"http://{BACKEND_HOST}:{backend_port}"
    frontend_base_url = f"http://{FRONTEND_HOST}:{frontend_port}"
    write_proxy_config(proxy_config_path, backend_base_url)

    backend_env = os.environ.copy()
    backend_env.update({
        "ENVIRONMENT": "development",
        "JWT_SECRET_KEY": "e2e-secret-key",
        "STORE_DATABASE_PATH": str(db_path),
    })

    try:
        processes.append(
            start_process(
                name="backend",
                command=[
                    str(API_PYTHON),
                    "-m",
                    "uvicorn",
                    "src.main:app",
                    "--host",
                    BACKEND_HOST,
                    "--port",
                    str(backend_port),
                ],
                cwd=API_ROOT,
                env=backend_env,
                log_path=temp_root / "backend.log",
            )
        )
        wait_for_http(f"{backend_base_url}/ready", expected_text='"status":"ready"', timeout_seconds=120.0)

        processes.append(
            start_process(
                name="frontend",
                command=[
                    str(NX_SAFE),
                    "run",
                    "angular-shell:serve-smoke:development",
                    "--host",
                    FRONTEND_HOST,
                    "--port",
                    str(frontend_port),
                    "--proxy-config",
                    str(proxy_config_path),
                ],
                cwd=REPO_ROOT,
                env=os.environ.copy(),
                log_path=temp_root / "frontend.log",
            )
        )
        wait_for_http(
            f"{frontend_base_url}/",
            expected_text="SAP AI Fabric Console",
            timeout_seconds=120.0,
        )

        processes.append(
            start_process(
                name="chrome",
                command=[
                    str(chrome_binary),
                    "--headless=new",
                    "--disable-gpu",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-background-networking",
                    "--disable-component-update",
                    f"--remote-debugging-port={chrome_debug_port}",
                    f"--user-data-dir={chrome_profile}",
                    "about:blank",
                ],
                cwd=REPO_ROOT,
                env=os.environ.copy(),
                log_path=temp_root / "chrome.log",
            )
        )

        summary = asyncio.run(
            run_browser_flow(
                frontend_base_url,
                backend_base_url,
                chrome_debug_port,
                artifact_dir,
            )
        )

        print(json.dumps({
            "artifacts": str(artifact_dir),
            **summary,
        }, indent=2))

        if (
            summary["console_errors"]
            or summary["runtime_exceptions"]
            or summary["request_failures"]
            or summary["http_error_responses"]
        ):
            return 1
        return 0
    except Exception as exc:
        print(f"E2E smoke failed: {exc}", file=sys.stderr)
        print(f"Artifacts and logs: {temp_root}", file=sys.stderr)
        return 1
    finally:
        for process in reversed(processes):
            process.stop()


if __name__ == "__main__":
    raise SystemExit(main())

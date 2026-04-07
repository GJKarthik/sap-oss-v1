#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}/aiverify-parity.$$"
mkdir -p "$TMP_DIR"
KV_SERVER_BIN=""
KV_CLI_BIN=""
KV_PORT=""
KV_STREAM="aiverify:worker:task_queue"
KV_GROUP="aiverify_workers"

cleanup() {
  if [ -n "${KV_CLI_BIN:-}" ] && [ -n "${KV_PORT:-}" ]; then
    "$KV_CLI_BIN" -p "$KV_PORT" shutdown nosave >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

MODE="${1:-test-engine-version}"
PYTHON_BIN="${AIVERIFY_PYTHON:-python3}"
QUEUE_BACKEND="${AIVERIFY_QUEUE_BACKEND:-valkey}"
MODE_APIGW_DB_URI=""

usage() {
  echo "Usage: scripts/parity_smoke.sh [mode]"
  echo "Modes:"
  echo "  test-engine-version"
  echo "  test-engine-version-flag"
  echo "  worker-config"
  echo "  apigw-config"
  echo "  apigw-config-hana"
  echo "  apigw-validate-gid-cid"
  echo "  apigw-check-valid-filename"
  echo "  apigw-sanitize-filename"
  echo "  apigw-check-relative-to-base"
  echo "  apigw-file-utils"
  echo "  apigw-plugin-storage-layout"
  echo "  apigw-data-storage-layout"
  echo "  apigw-artifact-io-local"
  echo "  apigw-model-dataset-io-local"
  echo "  apigw-plugin-archive-io-local"
  echo "  apigw-plugin-archive-io-local-hana"
  echo "  apigw-plugin-mdx-bundle-io-local"
  echo "  apigw-plugin-backup-local"
  echo "  worker-once-reclaim"
  echo "  worker-once-reclaim-ack"
  echo "  worker-once-reclaim-empty"
  echo "  worker-once-reclaim-invalid-start"
  echo "  metrics-gap"
  echo "  normalize-plugin-gid"
  echo "Example: scripts/parity_smoke.sh worker-config"
  echo "Environment:"
  echo "  AIVERIFY_QUEUE_BACKEND=valkey|hana (default: valkey)"
  echo "  AIVERIFY_HANA_DB_URI=<hana db uri> (used by *-hana modes)"
}

prepare_kv_bins() {
  if [ -n "${AIVERIFY_VALKEY_SERVER_BIN:-}" ]; then
    KV_SERVER_BIN="$AIVERIFY_VALKEY_SERVER_BIN"
  elif command -v valkey-server >/dev/null 2>&1; then
    KV_SERVER_BIN="$(command -v valkey-server)"
  elif command -v redis-server >/dev/null 2>&1; then
    KV_SERVER_BIN="$(command -v redis-server)"
  else
    return 1
  fi

  if [ -n "${AIVERIFY_VALKEY_CLI_BIN:-}" ]; then
    KV_CLI_BIN="$AIVERIFY_VALKEY_CLI_BIN"
  elif command -v valkey-cli >/dev/null 2>&1; then
    KV_CLI_BIN="$(command -v valkey-cli)"
  elif command -v redis-cli >/dev/null 2>&1; then
    KV_CLI_BIN="$(command -v redis-cli)"
  else
    return 1
  fi

  return 0
}

start_ephemeral_valkey() {
  prepare_kv_bins || {
    echo "[parity] Missing valkey/redis server or cli binary for worker-once-reclaim mode" >&2
    exit 2
  }

  if [ -n "${AIVERIFY_VALKEY_PORT:-}" ]; then
    KV_PORT="$AIVERIFY_VALKEY_PORT"
  else
    KV_PORT="$((20000 + RANDOM % 20000))"
  fi
  local kv_dir="$TMP_DIR/kv"
  mkdir -p "$kv_dir"

  "$KV_SERVER_BIN" \
    --port "$KV_PORT" \
    --save "" \
    --appendonly no \
    --dir "$kv_dir" \
    --pidfile "$kv_dir/kv.pid" \
    --logfile "$kv_dir/kv.log" \
    --daemonize yes

  for _ in $(seq 1 60); do
    if "$KV_CLI_BIN" -h 127.0.0.1 -p "$KV_PORT" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "[parity] Unable to start ephemeral valkey/redis server on port $KV_PORT" >&2
  exit 1
}

prepare_worker_reclaim_fixture() {
  local fixture_mode="$1"
  start_ephemeral_valkey

  local task='{"id":"reclaim-001"}'
  local message_id="1700-0"

  "$KV_CLI_BIN" -h 127.0.0.1 -p "$KV_PORT" XGROUP CREATE "$KV_STREAM" "$KV_GROUP" 0 MKSTREAM >/dev/null
  if [ "$fixture_mode" = "message" ]; then
    "$KV_CLI_BIN" -h 127.0.0.1 -p "$KV_PORT" XADD "$KV_STREAM" "$message_id" task "$task" >/dev/null
    "$KV_CLI_BIN" -h 127.0.0.1 -p "$KV_PORT" XREADGROUP GROUP "$KV_GROUP" seed-consumer COUNT 1 STREAMS "$KV_STREAM" ">" >/dev/null
  fi
}

write_worker_reference() {
  cat >"$TMP_DIR/worker_config_ref.py" <<'PY'
import os
from pathlib import Path

root = Path(os.environ["AIVERIFY_ROOT_DIR"])
default_data_dir = root / "aiverify-test-engine-worker" / "data"
data_dir = Path(os.getenv("TEWORKER_DATA_DIR", str(default_data_dir)))
data_dir.mkdir(parents=True, exist_ok=True)

def parse_u16(raw: str) -> int:
    value = int(raw)
    if value < 0 or value > 65535:
        raise ValueError("invalid u16")
    return value

valkey_port = parse_u16(os.getenv("VALKEY_PORT", "6379"))
docker_registry = os.getenv("DOCKER_REGISTRY")
kubectl_registry = os.getenv("KUBECTL_REGISTRY") or docker_registry or "localhost:5000"
pipeline_error = os.getenv("pipeline_error") or os.getenv("PIPELINE_ERROR") or "apigw_error_update"

lines = [
    "Worker startup preflight",
    f"  data_dir: {data_dir}",
    f"  log_level: {os.getenv('TEWORKER_LOG_LEVEL') or '<unset>'}",
    f"  apigw_url: {os.getenv('APIGW_URL', 'http://127.0.0.1:4000')}",
    f"  valkey_host: {os.getenv('VALKEY_HOST_ADDRESS', '127.0.0.1')}",
    f"  valkey_port: {valkey_port}",
    f"  python_bin: {os.getenv('PYTHON', 'python3')}",
    f"  pipeline_download: {os.getenv('PIPELINE_DOWNLOAD', 'apigw_download')}",
    f"  pipeline_build: {os.getenv('PIPELINE_BUILD', 'virtual_env')}",
    f"  pipeline_validate_input: {os.getenv('PIPELINE_VALIDATE_INPUT', 'validate_input')}",
    f"  pipeline_execute: {os.getenv('PIPELINE_EXECUTE', 'virtual_env_execute')}",
    f"  pipeline_upload: {os.getenv('PIPELINE_UPLOAD', 'apigw_upload')}",
    f"  pipeline_error: {pipeline_error}",
    f"  docker_registry: {docker_registry or '<unset>'}",
    f"  kubectl_registry: {kubectl_registry}",
]

print("\n".join(lines))
PY
}

write_apigw_reference() {
  cat >"$TMP_DIR/apigw_config_ref.py" <<'PY'
import os
from pathlib import Path

root = Path(os.environ["AIVERIFY_ROOT_DIR"])
host = os.getenv("APIGW_HOST_ADDRESS", "127.0.0.1")
port = int(os.getenv("APIGW_PORT", "4000"))
if port < 0 or port > 65535:
    raise ValueError("invalid APIGW_PORT")

data_dir_env = os.getenv("APIGW_DATA_DIR")
if data_dir_env:
    data_dir = data_dir_env
    if not data_dir.startswith("s3://"):
        Path(data_dir).mkdir(parents=True, exist_ok=True)
        Path(data_dir, "asset").mkdir(parents=True, exist_ok=True)
else:
    data_dir_path = (root / "aiverify-apigw" / "data").resolve()
    data_dir_path.mkdir(parents=True, exist_ok=True)
    data_dir_path.joinpath("asset").mkdir(parents=True, exist_ok=True)
    data_dir = str(data_dir_path)

db_uri = os.getenv("APIGW_DB_URI", f"sqlite:///{data_dir}/database.db")

try:
    valkey_port = int(os.getenv("VALKEY_PORT", "6379"))
    if valkey_port < 0 or valkey_port > 65535:
        raise ValueError("invalid u16")
except Exception:
    valkey_port = 6379

lines = [
    "API gateway startup preflight",
    f"  host: {host}",
    f"  port: {port}",
    f"  data_dir: {data_dir}",
    f"  db_uri: {db_uri}",
    f"  valkey_host: {os.getenv('VALKEY_HOST_ADDRESS', '127.0.0.1')}",
    f"  valkey_port: {valkey_port}",
    f"  log_level: {os.getenv('APIGW_LOG_LEVEL') or '<unset>'}",
]

print("\n".join(lines))
PY
}

write_apigw_validate_gid_cid_reference() {
  cat >"$TMP_DIR/apigw_validate_gid_cid_ref.py" <<'PY'
import os
import sys
from pathlib import Path

root = Path(os.environ["AIVERIFY_ROOT_DIR"])
sys.path.insert(0, str(root / "aiverify-apigw"))

from aiverify_apigw.lib.validators import validate_gid_cid  # noqa: E402

cases = [
    ("plain", "aiverify.stock_reports-01"),
    ("slash", "bad/value"),
    ("leading-dot", ".bad"),
    ("trailing-newline", "abc\n"),
]

for label, value in cases:
    print(f"{label}: {'yes' if validate_gid_cid(value) else 'no'}")
PY
}

write_apigw_validate_gid_cid_zig_runner() {
  cat >"$TMP_DIR/apigw_validate_gid_cid_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"

run_case() {
  local label="$1"
  local value="$2"
  local output
  output="$("$ZIG_BIN" apigw validate-gid-cid "$value")"
  output="${output#APIGW gid/cid valid: }"
  echo "${label}: ${output}"
}

run_case "plain" "aiverify.stock_reports-01"
run_case "slash" "bad/value"
run_case "leading-dot" ".bad"
run_case "trailing-newline" $'abc\n'
SH
  chmod +x "$TMP_DIR/apigw_validate_gid_cid_zig.sh"
}

write_apigw_check_valid_filename_reference() {
  cat >"$TMP_DIR/apigw_check_valid_filename_ref.py" <<'PY'
import os
import sys
from pathlib import Path

root = Path(os.environ["AIVERIFY_ROOT_DIR"])
sys.path.insert(0, str(root / "aiverify-apigw"))

from aiverify_apigw.lib.file_utils import check_valid_filename  # noqa: E402

cases = [
    ("plain", "aiverify/report-01.txt"),
    ("windows-separator", "a\\b"),
    ("traversal", "../bad"),
    ("invalid-char", "bad*name"),
    ("empty", ""),
]

for label, value in cases:
    print(f"{label}: {'yes' if check_valid_filename(value) else 'no'}")
PY
}

write_apigw_check_valid_filename_zig_runner() {
  cat >"$TMP_DIR/apigw_check_valid_filename_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"

run_case() {
  local label="$1"
  local value="$2"
  local output
  output="$("$ZIG_BIN" apigw check-valid-filename "$value")"
  output="${output#APIGW filename valid: }"
  echo "${label}: ${output}"
}

run_case "plain" "aiverify/report-01.txt"
run_case "windows-separator" "a\\b"
run_case "traversal" "../bad"
run_case "invalid-char" "bad*name"
run_case "empty" ""
SH
  chmod +x "$TMP_DIR/apigw_check_valid_filename_zig.sh"
}

write_apigw_sanitize_filename_reference() {
  cat >"$TMP_DIR/apigw_sanitize_filename_ref.py" <<'PY'
import os
import sys
from pathlib import Path

root = Path(os.environ["AIVERIFY_ROOT_DIR"])
sys.path.insert(0, str(root / "aiverify-apigw"))

from aiverify_apigw.lib.file_utils import InvalidFilename, sanitize_filename  # noqa: E402

cases = [
    ("plain", "abc-_.txt"),
    ("strip-invalid", "a*b$c"),
    ("slashes", "a/b\\c"),
    ("invalid-leading", "_bad"),
]

for label, value in cases:
    try:
        result = sanitize_filename(value)
        print(f"{label}: {result}")
    except InvalidFilename:
        print(f"{label}: error")
PY
}

write_apigw_sanitize_filename_zig_runner() {
  cat >"$TMP_DIR/apigw_sanitize_filename_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"

run_case() {
  local label="$1"
  local value="$2"
  local output
  if output="$("$ZIG_BIN" apigw sanitize-filename "$value" 2>/dev/null)"; then
    output="${output#APIGW sanitized filename: }"
    echo "${label}: ${output}"
  else
    echo "${label}: error"
  fi
}

run_case "plain" "abc-_.txt"
run_case "strip-invalid" 'a*b$c'
run_case "slashes" 'a/b\c'
run_case "invalid-leading" "_bad"
SH
  chmod +x "$TMP_DIR/apigw_sanitize_filename_zig.sh"
}

write_apigw_check_relative_to_base_reference() {
  cat >"$TMP_DIR/apigw_check_relative_to_base_ref.py" <<'PY'
from pathlib import Path
from urllib.parse import urljoin
import urllib.parse

urllib.parse.uses_relative.append("s3")
urllib.parse.uses_netloc.append("s3")

def check_relative_to_base(base_path, filepath):
    if isinstance(base_path, Path):
        filepath = Path(filepath)
        full_path = base_path / filepath
        return full_path.is_relative_to(base_path)
    return urljoin(base_path, filepath).startswith(base_path)

cases = [
    ("local-relative", Path("/base"), "child"),
    ("local-inside-absolute", Path("/base"), "/base/file.txt"),
    ("local-outside-absolute", Path("/base"), "/tmp/file.txt"),
    ("s3-relative", "s3://bucket/prefix/", "child"),
    ("s3-parent-traversal", "s3://bucket/prefix/", "../escape"),
    ("s3-other-bucket", "s3://bucket/prefix/", "s3://other/prefix/file.txt"),
]

for label, base_path, filepath in cases:
    print(f"{label}: {'yes' if check_relative_to_base(base_path, filepath) else 'no'}")
PY
}

write_apigw_check_relative_to_base_zig_runner() {
  cat >"$TMP_DIR/apigw_check_relative_to_base_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"

run_case() {
  local label="$1"
  local base_path="$2"
  local filepath="$3"
  local output
  output="$("$ZIG_BIN" apigw check-relative-to-base "$base_path" "$filepath")"
  output="${output#APIGW path relative: }"
  echo "${label}: ${output}"
}

run_case "local-relative" "/base" "child"
run_case "local-inside-absolute" "/base" "/base/file.txt"
run_case "local-outside-absolute" "/base" "/tmp/file.txt"
run_case "s3-relative" "s3://bucket/prefix/" "child"
run_case "s3-parent-traversal" "s3://bucket/prefix/" "../escape"
run_case "s3-other-bucket" "s3://bucket/prefix/" "s3://other/prefix/file.txt"
SH
  chmod +x "$TMP_DIR/apigw_check_relative_to_base_zig.sh"
}

write_apigw_file_utils_reference() {
  cat >"$TMP_DIR/apigw_file_utils_ref.py" <<'PY'
import os
import sys
from pathlib import Path

root = Path(os.environ["AIVERIFY_ROOT_DIR"])
sys.path.insert(0, str(root / "aiverify-apigw"))

from aiverify_apigw.lib.file_utils import append_filename, check_file_size, get_stem, get_suffix  # noqa: E402

def emit(label, value):
    print(f"{label}: {value if value else '<empty>'}")

emit("size-max", "yes" if check_file_size(4294967296) else "no")
emit("size-over", "yes" if check_file_size(4294967297) else "no")
emit("append", append_filename("path/to/file.tar.gz", "_v2"))
emit("suffix-upper", get_suffix("file.TXT"))
emit("suffix-hidden", get_suffix(".bashrc"))
emit("stem-tar", get_stem("path/to/file.tar.gz"))
emit("stem-dot", get_stem("."))
PY
}

write_apigw_file_utils_zig_runner() {
  cat >"$TMP_DIR/apigw_file_utils_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"

emit() {
  local label="$1"
  local value="$2"
  if [ -z "$value" ]; then
    value="<empty>"
  fi
  echo "${label}: ${value}"
}

run_size() {
  local label="$1"
  local size="$2"
  local output
  output="$("$ZIG_BIN" apigw check-file-size "$size")"
  output="${output#APIGW file size valid: }"
  emit "$label" "$output"
}

run_append() {
  local label="$1"
  local filename="$2"
  local append_name="$3"
  local output
  output="$("$ZIG_BIN" apigw append-filename "$filename" "$append_name")"
  output="${output#APIGW appended filename: }"
  emit "$label" "$output"
}

run_suffix() {
  local label="$1"
  local filename="$2"
  local output
  output="$("$ZIG_BIN" apigw get-suffix "$filename")"
  output="${output#APIGW suffix: }"
  emit "$label" "$output"
}

run_stem() {
  local label="$1"
  local filename="$2"
  local output
  output="$("$ZIG_BIN" apigw get-stem "$filename")"
  output="${output#APIGW stem: }"
  emit "$label" "$output"
}

run_size "size-max" "4294967296"
run_size "size-over" "4294967297"
run_append "append" "path/to/file.tar.gz" "_v2"
run_suffix "suffix-upper" "file.TXT"
run_suffix "suffix-hidden" ".bashrc"
run_stem "stem-tar" "path/to/file.tar.gz"
run_stem "stem-dot" "."
SH
  chmod +x "$TMP_DIR/apigw_file_utils_zig.sh"
}

write_apigw_plugin_storage_layout_reference() {
  cat >"$TMP_DIR/apigw_plugin_storage_layout_ref.py" <<'PY'
from pathlib import Path
from urllib.parse import urljoin
import urllib.parse

urllib.parse.uses_relative.append("s3")
urllib.parse.uses_netloc.append("s3")

def render_layout(mode: str, base_plugin_dir: str, gid: str, cid: str) -> str:
    plugin_zip_name = f"{gid}.zip"
    plugin_hash_name = f"{gid}.hash"
    algorithm_zip_name = f"{cid}.zip"
    algorithm_hash_name = f"{cid}.hash"

    if mode == "local":
        plugin_folder = Path(base_plugin_dir).joinpath(gid).as_posix()
        mdx_folder = Path(plugin_folder).joinpath("mdx_bundles").as_posix()
        algorithms_folder = Path(plugin_folder).joinpath("algorithms").as_posix()
        plugin_zip_path = Path(plugin_folder).joinpath(plugin_zip_name).as_posix()
        plugin_hash_path = Path(plugin_folder).joinpath(plugin_hash_name).as_posix()
        algorithm_zip_path = Path(algorithms_folder).joinpath(algorithm_zip_name).as_posix()
        algorithm_hash_path = Path(algorithms_folder).joinpath(algorithm_hash_name).as_posix()
        widgets_zip_path = Path(plugin_folder).joinpath("widgets.zip").as_posix()
        widgets_hash_path = Path(plugin_folder).joinpath("widgets.hash").as_posix()
        inputs_zip_path = Path(plugin_folder).joinpath("inputs.zip").as_posix()
        inputs_hash_path = Path(plugin_folder).joinpath("inputs.hash").as_posix()
        mdx_bundle_path = Path(mdx_folder).joinpath(f"{cid}.bundle.json").as_posix()
        mdx_summary_bundle_path = Path(mdx_folder).joinpath(f"{cid}.summary.bundle.json").as_posix()
    else:
        plugin_folder = urljoin(base_plugin_dir, f"{gid}/")
        mdx_folder = urljoin(plugin_folder, "mdx_bundles/")
        algorithms_folder = urljoin(plugin_folder, "algorithms/")
        plugin_zip_path = urljoin(plugin_folder, plugin_zip_name)
        plugin_hash_path = urljoin(plugin_folder, plugin_hash_name)
        algorithm_zip_path = urljoin(algorithms_folder, algorithm_zip_name)
        algorithm_hash_path = urljoin(algorithms_folder, algorithm_hash_name)
        widgets_zip_path = urljoin(plugin_folder, "widgets.zip")
        widgets_hash_path = urljoin(plugin_folder, "widgets.hash")
        inputs_zip_path = urljoin(plugin_folder, "inputs.zip")
        inputs_hash_path = urljoin(plugin_folder, "inputs.hash")
        mdx_bundle_path = urljoin(mdx_folder, f"{cid}.bundle.json")
        mdx_summary_bundle_path = urljoin(mdx_folder, f"{cid}.summary.bundle.json")

    lines = [
        "APIGW plugin storage layout",
        f"  mode: {mode}",
        f"  plugin_folder: {plugin_folder}",
        f"  mdx_bundles_folder: {mdx_folder}",
        f"  algorithms_folder: {algorithms_folder}",
        f"  plugin_zip_path: {plugin_zip_path}",
        f"  plugin_hash_path: {plugin_hash_path}",
        f"  algorithm_zip_path: {algorithm_zip_path}",
        f"  algorithm_hash_path: {algorithm_hash_path}",
        f"  widgets_zip_path: {widgets_zip_path}",
        f"  widgets_hash_path: {widgets_hash_path}",
        f"  inputs_zip_path: {inputs_zip_path}",
        f"  inputs_hash_path: {inputs_hash_path}",
        f"  mdx_bundle_path: {mdx_bundle_path}",
        f"  mdx_summary_bundle_path: {mdx_summary_bundle_path}",
    ]
    return "\n".join(lines)

print(render_layout("local", "/base/plugin", "aiverify.stock_reports-01", "algo-01"))
print(render_layout("prefix", "base/plugin/", "aiverify.stock_reports-01", "algo-01"))
print(render_layout("s3", "s3://bucket/root/plugin/", "aiverify.stock_reports-01", "algo-01"))
PY
}

write_apigw_plugin_storage_layout_zig_runner() {
  cat >"$TMP_DIR/apigw_plugin_storage_layout_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"

"$ZIG_BIN" apigw plugin-storage-layout local /base/plugin aiverify.stock_reports-01 algo-01
"$ZIG_BIN" apigw plugin-storage-layout prefix base/plugin/ aiverify.stock_reports-01 algo-01
"$ZIG_BIN" apigw plugin-storage-layout s3 s3://bucket/root/plugin/ aiverify.stock_reports-01 algo-01
SH
  chmod +x "$TMP_DIR/apigw_plugin_storage_layout_zig.sh"
}

write_apigw_data_storage_layout_reference() {
  cat >"$TMP_DIR/apigw_data_storage_layout_ref.py" <<'PY'
from pathlib import Path
from urllib.parse import urljoin
import urllib.parse
import re

urllib.parse.uses_relative.append("s3")
urllib.parse.uses_netloc.append("s3")

def check_valid_filename(filename: str) -> bool:
    return re.search(r"\.\.", filename) is None and re.search(r"[^a-zA-Z0-9._\-/]", filename.replace("\\", "/")) is None

def check_relative_to_base(base_path, filepath: str) -> bool:
    if isinstance(base_path, Path):
        full_path = base_path / Path(filepath)
        return full_path.is_relative_to(base_path)
    return urljoin(base_path, filepath).startswith(base_path)

def render_layout(
    mode: str,
    base_artifacts_dir: str,
    base_models_dir: str,
    base_dataset_dir: str,
    test_result_id: str,
    filename: str,
    subfolder_raw: str,
) -> str:
    is_local = mode == "local"
    subfolder = None if subfolder_raw in ("", "-") else subfolder_raw
    subfolder_value = subfolder if subfolder else "<none>"

    artifact_folder = (
        Path(base_artifacts_dir).joinpath(test_result_id).as_posix()
        if is_local
        else urljoin(base_artifacts_dir, f"{test_result_id}/")
    )
    artifact_target_path = (
        Path(artifact_folder).joinpath(filename).as_posix()
        if is_local
        else urljoin(artifact_folder, filename)
    )
    artifact_relative_guard = check_relative_to_base(Path(artifact_folder) if is_local else artifact_folder, filename)

    model_folder = (
        (Path(base_models_dir).joinpath(subfolder).as_posix() if subfolder else Path(base_models_dir).as_posix())
        if is_local
        else (urljoin(base_models_dir, f"{subfolder}/") if subfolder else base_models_dir)
    )
    model_path = (
        Path(model_folder).joinpath(filename).as_posix()
        if is_local
        else urljoin(model_folder, filename)
    )
    model_relative_guard = check_relative_to_base(Path(base_models_dir) if is_local else base_models_dir, filename)
    model_sidecar_zip_save_key = f"{filename}.zip"
    model_sidecar_hash_save_key = f"{filename}.hash"
    if is_local:
        model_obj = Path(model_path)
        model_sidecar_zip_lookup = model_obj.parent.joinpath(f"{model_obj.name}.zip").as_posix()
        model_sidecar_hash_lookup = model_obj.parent.joinpath(f"{model_obj.name}.hash").as_posix()
    else:
        model_sidecar_zip_lookup = f"{model_path}.zip"
        model_sidecar_hash_lookup = f"{model_path}.hash"

    dataset_folder = (
        (Path(base_dataset_dir).joinpath(subfolder).as_posix() if subfolder else Path(base_dataset_dir).as_posix())
        if is_local
        else (urljoin(base_dataset_dir, f"{subfolder}/") if subfolder else base_dataset_dir)
    )
    dataset_path = (
        Path(dataset_folder).joinpath(filename).as_posix()
        if is_local
        else urljoin(dataset_folder, filename)
    )
    dataset_relative_guard = check_relative_to_base(Path(base_dataset_dir) if is_local else base_dataset_dir, filename)
    dataset_sidecar_zip_save_key = f"{filename}.zip"
    dataset_sidecar_hash_save_key = f"{filename}.hash"
    if is_local:
        dataset_obj = Path(dataset_path)
        dataset_sidecar_zip_lookup = dataset_obj.parent.joinpath(f"{dataset_obj.name}.zip").as_posix()
        dataset_sidecar_hash_lookup = dataset_obj.parent.joinpath(f"{dataset_obj.name}.hash").as_posix()
    else:
        dataset_sidecar_zip_lookup = f"{dataset_path}.zip"
        dataset_sidecar_hash_lookup = f"{dataset_path}.hash"

    lines = [
        "APIGW data storage layout",
        f"  mode: {mode}",
        f"  subfolder: {subfolder_value}",
        f"  valid_test_result_id: {'yes' if test_result_id.isalnum() else 'no'}",
        f"  valid_filename: {'yes' if check_valid_filename(filename) else 'no'}",
        f"  artifact_folder: {artifact_folder}",
        f"  artifact_target_path: {artifact_target_path}",
        f"  artifact_relative_guard: {'yes' if artifact_relative_guard else 'no'}",
        f"  model_folder: {model_folder}",
        f"  model_path: {model_path}",
        f"  model_relative_guard: {'yes' if model_relative_guard else 'no'}",
        f"  model_sidecar_zip_save_key: {model_sidecar_zip_save_key}",
        f"  model_sidecar_hash_save_key: {model_sidecar_hash_save_key}",
        f"  model_sidecar_zip_lookup: {model_sidecar_zip_lookup}",
        f"  model_sidecar_hash_lookup: {model_sidecar_hash_lookup}",
        f"  dataset_folder: {dataset_folder}",
        f"  dataset_path: {dataset_path}",
        f"  dataset_relative_guard: {'yes' if dataset_relative_guard else 'no'}",
        f"  dataset_sidecar_zip_save_key: {dataset_sidecar_zip_save_key}",
        f"  dataset_sidecar_hash_save_key: {dataset_sidecar_hash_save_key}",
        f"  dataset_sidecar_zip_lookup: {dataset_sidecar_zip_lookup}",
        f"  dataset_sidecar_hash_lookup: {dataset_sidecar_hash_lookup}",
    ]
    return "\n".join(lines)

print(render_layout("local", "/base/artifacts", "/base/models", "/base/datasets", "TR123", "nested/file.bin", "nlp"))
print(render_layout("s3", "s3://bucket/root/artifacts/", "s3://bucket/root/models/", "s3://bucket/root/datasets/", "BAD_ID", "nested/file.bin", "nlp"))
PY
}

write_apigw_data_storage_layout_zig_runner() {
  cat >"$TMP_DIR/apigw_data_storage_layout_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"

"$ZIG_BIN" apigw data-storage-layout local /base/artifacts /base/models /base/datasets TR123 nested/file.bin nlp
"$ZIG_BIN" apigw data-storage-layout s3 s3://bucket/root/artifacts/ s3://bucket/root/models/ s3://bucket/root/datasets/ BAD_ID nested/file.bin nlp
SH
  chmod +x "$TMP_DIR/apigw_data_storage_layout_zig.sh"
}

write_apigw_artifact_io_local_reference() {
  cat >"$TMP_DIR/apigw_artifact_io_local_ref.py" <<'PY'
from pathlib import Path
from urllib.parse import urljoin
import re
import sys

base_artifacts_dir = Path(sys.argv[1])
base_artifacts_dir.mkdir(parents=True, exist_ok=True)

def check_valid_filename(filename: str) -> bool:
    return re.search(r"\.\.", filename) is None and re.search(r"[^a-zA-Z0-9._\-/]", filename.replace("\\", "/")) is None

def check_relative_to_base(base_path: Path, filepath: str) -> bool:
    return (base_path / Path(filepath)).is_relative_to(base_path)

def save_artifact(test_result_id: str, filename: str, data: bytes) -> Path:
    if not test_result_id.isalnum():
        raise ValueError("InvalidTestResultId")
    if not check_valid_filename(filename):
        raise ValueError("InvalidFilename")
    folder = base_artifacts_dir.joinpath(test_result_id)
    folder.mkdir(parents=True, exist_ok=True)
    if not check_relative_to_base(folder, filename):
        raise ValueError("InvalidFilename")
    filepath = folder.joinpath(filename)
    filepath.parent.mkdir(parents=True, exist_ok=True)
    filepath.write_bytes(data)
    return filepath

def get_artifact(test_result_id: str, filename: str) -> bytes:
    if not test_result_id.isalnum():
        raise ValueError("InvalidTestResultId")
    if not check_valid_filename(filename):
        raise ValueError("InvalidFilename")
    folder = base_artifacts_dir.joinpath(test_result_id)
    if not check_relative_to_base(folder, filename):
        raise ValueError("InvalidFilename")
    filepath = folder.joinpath(filename).resolve()
    return filepath.read_bytes()

saved = save_artifact("TR123", "nested/file.bin", b"artifact_payload_01")
print(f"save-ok: path={saved.as_posix()} bytes=19")
content = get_artifact("TR123", "nested/file.bin").decode("utf-8")
print(f"get-ok: content={content}")

try:
    save_artifact("BAD-ID", "file.bin", b"x")
    print("invalid-id: ok")
except Exception:
    print("invalid-id: error")

try:
    save_artifact("TR123", "../bad.bin", b"x")
    print("invalid-filename: ok")
except Exception:
    print("invalid-filename: error")
PY
}

write_apigw_artifact_io_local_zig_runner() {
  cat >"$TMP_DIR/apigw_artifact_io_local_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"
BASE_ARTIFACTS_DIR="$2"

save_output="$("$ZIG_BIN" apigw save-artifact "$BASE_ARTIFACTS_DIR" TR123 nested/file.bin artifact_payload_01)"
save_path="$(printf '%s\n' "$save_output" | sed -n 's/^  path: //p')"
save_bytes="$(printf '%s\n' "$save_output" | sed -n 's/^  bytes: //p')"
save_path="$(python3 - "$save_path" <<'PY'
import os
import sys
print(os.path.normpath(sys.argv[1]))
PY
)"
echo "save-ok: path=$save_path bytes=$save_bytes"

get_output="$("$ZIG_BIN" apigw get-artifact "$BASE_ARTIFACTS_DIR" TR123 nested/file.bin)"
get_content="${get_output#APIGW artifact content: }"
echo "get-ok: content=$get_content"

if "$ZIG_BIN" apigw save-artifact "$BASE_ARTIFACTS_DIR" BAD-ID file.bin x >/dev/null 2>&1; then
  echo "invalid-id: ok"
else
  echo "invalid-id: error"
fi

if "$ZIG_BIN" apigw save-artifact "$BASE_ARTIFACTS_DIR" TR123 ../bad.bin x >/dev/null 2>&1; then
  echo "invalid-filename: ok"
else
  echo "invalid-filename: error"
fi
SH
  chmod +x "$TMP_DIR/apigw_artifact_io_local_zig.sh"
}

write_apigw_model_dataset_io_local_reference() {
  cat >"$TMP_DIR/apigw_model_dataset_io_local_ref.py" <<'PY'
from __future__ import annotations

import hashlib
import os
import re
import shutil
import sys
import zipfile
from io import BytesIO
from pathlib import Path

models_base = Path(sys.argv[1])
datasets_base = Path(sys.argv[2])
model_source = Path(sys.argv[3])
dataset_source = Path(sys.argv[4])
model_dir_source = Path(sys.argv[5])
dataset_dir_source = Path(sys.argv[6])

models_base.mkdir(parents=True, exist_ok=True)
datasets_base.mkdir(parents=True, exist_ok=True)

def check_valid_filename(filename: str) -> bool:
    return re.search(r"\.\.", filename) is None and re.search(r"[^a-zA-Z0-9._\-/]", filename.replace("\\", "/")) is None

def file_sha256(path: Path) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as fp:
        while chunk := fp.read(8192):
            hasher.update(chunk)
    return hasher.hexdigest()

def normalize(path: Path) -> str:
    return os.path.normpath(path.as_posix())

def zip_directory_bytes(folder: Path) -> bytes:
    buffer = BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as zf:
        for path in sorted(folder.rglob("*")):
            rel = path.relative_to(folder).as_posix()
            if path.is_dir():
                zf.mkdir(rel)
            elif path.is_file():
                zf.write(path, rel)
    return buffer.getvalue()

def save_local(base_dir: Path, source_path: Path) -> tuple[Path, str]:
    source_name = source_path.name
    if not source_name or not check_valid_filename(source_name):
        raise ValueError("InvalidFilename")
    if not source_path.exists():
        raise FileNotFoundError("SourceNotFound")
    base_dir.mkdir(parents=True, exist_ok=True)
    target_path = base_dir.joinpath(source_name)
    if source_path.is_dir():
        target_path.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source_path, target_path, dirs_exist_ok=True)
        zip_bytes = zip_directory_bytes(source_path)
        zip_path = Path(f"{target_path}.zip")
        hash_path = Path(f"{target_path}.hash")
        zip_path.write_bytes(zip_bytes)
        filehash = hashlib.sha256(zip_bytes).hexdigest()
        hash_path.write_text(filehash)
        return target_path, filehash
    shutil.copy(source_path, target_path)
    return target_path, file_sha256(source_path)

def get_local(base_dir: Path, filename: str) -> bytes:
    if not check_valid_filename(filename):
        raise ValueError("InvalidFilename")
    target = base_dir.joinpath(filename)
    if target.is_dir():
        zip_path = Path(f"{target}.zip")
        if not zip_path.exists():
            raise FileNotFoundError(filename)
        return zip_path.read_bytes()
    return target.read_bytes()

def delete_local(base_dir: Path, filename: str) -> bool:
    target = base_dir.joinpath(filename)
    if not target.exists():
        return False
    if target.is_dir():
        shutil.rmtree(target, ignore_errors=True)
        Path(f"{target}.zip").unlink(missing_ok=True)
        Path(f"{target}.hash").unlink(missing_ok=True)
        return True
    target.unlink()
    return True

model_target, model_sha = save_local(models_base, model_source)
print(f"model-save-ok: path={normalize(model_target)} sha256={model_sha}")
model_content = get_local(models_base, model_source.name).decode("utf-8")
print(f"model-get-ok: content={model_content}")
print(f"model-delete-first: {'yes' if delete_local(models_base, model_source.name) else 'no'}")
print(f"model-delete-second: {'yes' if delete_local(models_base, model_source.name) else 'no'}")
try:
    save_local(models_base, models_base.joinpath("missing-model.bin"))
    print("model-invalid-source: ok")
except Exception:
    print("model-invalid-source: error")

model_dir_target, model_dir_sha = save_local(models_base, model_dir_source)
print(f"model-dir-save-ok: path={normalize(model_dir_target)} hash-len={len(model_dir_sha)}")
model_dir_content = get_local(models_base, model_dir_source.name)
print(f"model-dir-get-ok: bytes={len(model_dir_content)}")
print(f"model-dir-delete-first: {'yes' if delete_local(models_base, model_dir_source.name) else 'no'}")
print(f"model-dir-delete-second: {'yes' if delete_local(models_base, model_dir_source.name) else 'no'}")

dataset_target, dataset_sha = save_local(datasets_base, dataset_source)
print(f"dataset-save-ok: path={normalize(dataset_target)} sha256={dataset_sha}")
dataset_content = get_local(datasets_base, dataset_source.name).decode("utf-8")
print(f"dataset-get-ok: content={dataset_content}")
print(f"dataset-delete-first: {'yes' if delete_local(datasets_base, dataset_source.name) else 'no'}")
print(f"dataset-delete-second: {'yes' if delete_local(datasets_base, dataset_source.name) else 'no'}")
try:
    save_local(datasets_base, datasets_base.joinpath("missing-dataset.bin"))
    print("dataset-invalid-source: ok")
except Exception:
    print("dataset-invalid-source: error")

dataset_dir_target, dataset_dir_sha = save_local(datasets_base, dataset_dir_source)
print(f"dataset-dir-save-ok: path={normalize(dataset_dir_target)} hash-len={len(dataset_dir_sha)}")
dataset_dir_content = get_local(datasets_base, dataset_dir_source.name)
print(f"dataset-dir-get-ok: bytes={len(dataset_dir_content)}")
print(f"dataset-dir-delete-first: {'yes' if delete_local(datasets_base, dataset_dir_source.name) else 'no'}")
print(f"dataset-dir-delete-second: {'yes' if delete_local(datasets_base, dataset_dir_source.name) else 'no'}")
PY
}

write_apigw_model_dataset_io_local_zig_runner() {
  cat >"$TMP_DIR/apigw_model_dataset_io_local_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"
MODELS_BASE_DIR="$2"
DATASETS_BASE_DIR="$3"
MODEL_SOURCE_PATH="$4"
DATASET_SOURCE_PATH="$5"
MODEL_DIR_SOURCE_PATH="$6"
DATASET_DIR_SOURCE_PATH="$7"

normalize_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.normpath(sys.argv[1]))
PY
}

emit_binary_len() {
  local label="$1"
  local path="$2"
  local prefix="$3"
  python3 - "$label" "$path" "$prefix" <<'PY'
import sys
from pathlib import Path

label = sys.argv[1]
path = Path(sys.argv[2])
prefix = sys.argv[3].encode("utf-8")
data = path.read_bytes()
if not data.startswith(prefix):
    raise SystemExit(f"missing expected prefix for {label}")
payload = data[len(prefix):]
if not payload.endswith(b"\n"):
    raise SystemExit(f"missing trailing newline for {label}")
payload = payload[:-1]
print(f"{label}: bytes={len(payload)}")
PY
}

model_save_output="$("$ZIG_BIN" apigw save-model-local "$MODELS_BASE_DIR" "$MODEL_SOURCE_PATH")"
model_save_path="$(printf '%s\n' "$model_save_output" | sed -n 's/^  path: //p')"
model_save_sha="$(printf '%s\n' "$model_save_output" | sed -n 's/^  sha256: //p')"
model_save_path="$(normalize_path "$model_save_path")"
echo "model-save-ok: path=$model_save_path sha256=$model_save_sha"

model_get_output="$("$ZIG_BIN" apigw get-model-local "$MODELS_BASE_DIR" "$(basename "$MODEL_SOURCE_PATH")")"
model_get_content="${model_get_output#APIGW model content: }"
echo "model-get-ok: content=$model_get_content"

model_delete_first_output="$("$ZIG_BIN" apigw delete-model-local "$MODELS_BASE_DIR" "$(basename "$MODEL_SOURCE_PATH")")"
model_delete_first="${model_delete_first_output#APIGW model deleted: }"
echo "model-delete-first: $model_delete_first"

model_delete_second_output="$("$ZIG_BIN" apigw delete-model-local "$MODELS_BASE_DIR" "$(basename "$MODEL_SOURCE_PATH")")"
model_delete_second="${model_delete_second_output#APIGW model deleted: }"
echo "model-delete-second: $model_delete_second"

if "$ZIG_BIN" apigw save-model-local "$MODELS_BASE_DIR" "$MODELS_BASE_DIR/missing-model.bin" >/dev/null 2>&1; then
  echo "model-invalid-source: ok"
else
  echo "model-invalid-source: error"
fi

model_dir_save_output="$("$ZIG_BIN" apigw save-model-local "$MODELS_BASE_DIR" "$MODEL_DIR_SOURCE_PATH")"
model_dir_save_path="$(printf '%s\n' "$model_dir_save_output" | sed -n 's/^  path: //p')"
model_dir_save_sha="$(printf '%s\n' "$model_dir_save_output" | sed -n 's/^  sha256: //p')"
model_dir_save_path="$(normalize_path "$model_dir_save_path")"
echo "model-dir-save-ok: path=$model_dir_save_path hash-len=${#model_dir_save_sha}"

model_dir_get_path="$MODELS_BASE_DIR/.model_dir_get.out"
"$ZIG_BIN" apigw get-model-local "$MODELS_BASE_DIR" "$(basename "$MODEL_DIR_SOURCE_PATH")" >"$model_dir_get_path"
emit_binary_len "model-dir-get-ok" "$model_dir_get_path" "APIGW model content: "
rm -f "$model_dir_get_path"

model_dir_delete_first_output="$("$ZIG_BIN" apigw delete-model-local "$MODELS_BASE_DIR" "$(basename "$MODEL_DIR_SOURCE_PATH")")"
model_dir_delete_first="${model_dir_delete_first_output#APIGW model deleted: }"
echo "model-dir-delete-first: $model_dir_delete_first"

model_dir_delete_second_output="$("$ZIG_BIN" apigw delete-model-local "$MODELS_BASE_DIR" "$(basename "$MODEL_DIR_SOURCE_PATH")")"
model_dir_delete_second="${model_dir_delete_second_output#APIGW model deleted: }"
echo "model-dir-delete-second: $model_dir_delete_second"

dataset_save_output="$("$ZIG_BIN" apigw save-dataset-local "$DATASETS_BASE_DIR" "$DATASET_SOURCE_PATH")"
dataset_save_path="$(printf '%s\n' "$dataset_save_output" | sed -n 's/^  path: //p')"
dataset_save_sha="$(printf '%s\n' "$dataset_save_output" | sed -n 's/^  sha256: //p')"
dataset_save_path="$(normalize_path "$dataset_save_path")"
echo "dataset-save-ok: path=$dataset_save_path sha256=$dataset_save_sha"

dataset_get_output="$("$ZIG_BIN" apigw get-dataset-local "$DATASETS_BASE_DIR" "$(basename "$DATASET_SOURCE_PATH")")"
dataset_get_content="${dataset_get_output#APIGW dataset content: }"
echo "dataset-get-ok: content=$dataset_get_content"

dataset_delete_first_output="$("$ZIG_BIN" apigw delete-dataset-local "$DATASETS_BASE_DIR" "$(basename "$DATASET_SOURCE_PATH")")"
dataset_delete_first="${dataset_delete_first_output#APIGW dataset deleted: }"
echo "dataset-delete-first: $dataset_delete_first"

dataset_delete_second_output="$("$ZIG_BIN" apigw delete-dataset-local "$DATASETS_BASE_DIR" "$(basename "$DATASET_SOURCE_PATH")")"
dataset_delete_second="${dataset_delete_second_output#APIGW dataset deleted: }"
echo "dataset-delete-second: $dataset_delete_second"

if "$ZIG_BIN" apigw save-dataset-local "$DATASETS_BASE_DIR" "$DATASETS_BASE_DIR/missing-dataset.bin" >/dev/null 2>&1; then
  echo "dataset-invalid-source: ok"
else
  echo "dataset-invalid-source: error"
fi

dataset_dir_save_output="$("$ZIG_BIN" apigw save-dataset-local "$DATASETS_BASE_DIR" "$DATASET_DIR_SOURCE_PATH")"
dataset_dir_save_path="$(printf '%s\n' "$dataset_dir_save_output" | sed -n 's/^  path: //p')"
dataset_dir_save_sha="$(printf '%s\n' "$dataset_dir_save_output" | sed -n 's/^  sha256: //p')"
dataset_dir_save_path="$(normalize_path "$dataset_dir_save_path")"
echo "dataset-dir-save-ok: path=$dataset_dir_save_path hash-len=${#dataset_dir_save_sha}"

dataset_dir_get_path="$DATASETS_BASE_DIR/.dataset_dir_get.out"
"$ZIG_BIN" apigw get-dataset-local "$DATASETS_BASE_DIR" "$(basename "$DATASET_DIR_SOURCE_PATH")" >"$dataset_dir_get_path"
emit_binary_len "dataset-dir-get-ok" "$dataset_dir_get_path" "APIGW dataset content: "
rm -f "$dataset_dir_get_path"

dataset_dir_delete_first_output="$("$ZIG_BIN" apigw delete-dataset-local "$DATASETS_BASE_DIR" "$(basename "$DATASET_DIR_SOURCE_PATH")")"
dataset_dir_delete_first="${dataset_dir_delete_first_output#APIGW dataset deleted: }"
echo "dataset-dir-delete-first: $dataset_dir_delete_first"

dataset_dir_delete_second_output="$("$ZIG_BIN" apigw delete-dataset-local "$DATASETS_BASE_DIR" "$(basename "$DATASET_DIR_SOURCE_PATH")")"
dataset_dir_delete_second="${dataset_dir_delete_second_output#APIGW dataset deleted: }"
echo "dataset-dir-delete-second: $dataset_dir_delete_second"
SH
  chmod +x "$TMP_DIR/apigw_model_dataset_io_local_zig.sh"
}

write_apigw_plugin_archive_io_local_reference() {
  cat >"$TMP_DIR/apigw_plugin_archive_io_local_ref.py" <<'PY'
from __future__ import annotations

import hashlib
import shutil
import sys
import zipfile
from io import BytesIO
from pathlib import Path

base_plugin_dir = Path(sys.argv[1])
plugin_source = Path(sys.argv[2])
algorithm_source = Path(sys.argv[3])
widgets_source = Path(sys.argv[4])
inputs_source = Path(sys.argv[5])

GID = "gid-01"
CID = "cid-01"

def zip_directory_bytes(folder: Path) -> bytes:
    if not folder.exists() or not folder.is_dir():
        raise FileNotFoundError(folder)
    buffer = BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as zf:
        for path in sorted(folder.rglob("*")):
            rel = path.relative_to(folder).as_posix()
            if path.is_dir():
                zf.mkdir(rel)
            elif path.is_file():
                zf.write(path, rel)
    return buffer.getvalue()

def archive_folder(kind: str) -> Path:
    root = base_plugin_dir.joinpath(GID)
    if kind == "algorithm":
        return root.joinpath("algorithms")
    return root

def archive_names(kind: str) -> tuple[str, str]:
    if kind == "plugin":
        return f"{GID}.zip", f"{GID}.hash"
    if kind == "algorithm":
        return f"{CID}.zip", f"{CID}.hash"
    if kind == "widgets":
        return "widgets.zip", "widgets.hash"
    if kind == "inputs":
        return "inputs.zip", "inputs.hash"
    raise ValueError(kind)

def save_archive(kind: str, source: Path) -> str:
    folder = archive_folder(kind)
    folder.mkdir(parents=True, exist_ok=True)
    zip_name, hash_name = archive_names(kind)
    zip_bytes = zip_directory_bytes(source)
    digest = hashlib.sha256(zip_bytes).hexdigest()
    folder.joinpath(zip_name).write_bytes(zip_bytes)
    folder.joinpath(hash_name).write_text(digest)
    return digest

def get_archive(kind: str) -> bytes:
    folder = archive_folder(kind)
    zip_name, _ = archive_names(kind)
    return folder.joinpath(zip_name).read_bytes()

def delete_plugin() -> bool:
    folder = base_plugin_dir.joinpath(GID)
    if not folder.exists():
        return False
    shutil.rmtree(folder, ignore_errors=True)
    return True

plugin_sha = save_archive("plugin", plugin_source)
print(f"plugin-save-ok: hash-len={len(plugin_sha)}")
algorithm_sha = save_archive("algorithm", algorithm_source)
print(f"algorithm-save-ok: hash-len={len(algorithm_sha)}")
widgets_sha = save_archive("widgets", widgets_source)
print(f"widgets-save-ok: hash-len={len(widgets_sha)}")
inputs_sha = save_archive("inputs", inputs_source)
print(f"inputs-save-ok: hash-len={len(inputs_sha)}")

print(f"plugin-get-ok: positive={'yes' if len(get_archive('plugin')) > 0 else 'no'}")
print(f"algorithm-get-ok: positive={'yes' if len(get_archive('algorithm')) > 0 else 'no'}")
print(f"widgets-get-ok: positive={'yes' if len(get_archive('widgets')) > 0 else 'no'}")
print(f"inputs-get-ok: positive={'yes' if len(get_archive('inputs')) > 0 else 'no'}")

print(f"plugin-delete-first: {'yes' if delete_plugin() else 'no'}")
print(f"plugin-delete-second: {'yes' if delete_plugin() else 'no'}")

try:
    get_archive("plugin")
    print("plugin-get-after-delete: ok")
except Exception:
    print("plugin-get-after-delete: error")
PY
}

write_apigw_plugin_archive_io_local_zig_runner() {
  cat >"$TMP_DIR/apigw_plugin_archive_io_local_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"
BASE_PLUGIN_DIR="$2"
PLUGIN_SOURCE="$3"
ALGORITHM_SOURCE="$4"
WIDGETS_SOURCE="$5"
INPUTS_SOURCE="$6"

emit_save() {
  local label="$1"
  shift
  local output
  output="$("$ZIG_BIN" apigw "$@")"
  local sha
  sha="$(printf '%s\n' "$output" | sed -n 's/^  sha256: //p')"
  echo "${label}: hash-len=${#sha}"
}

emit_get() {
  local label="$1"
  shift
  local output
  output="$("$ZIG_BIN" apigw "$@")"
  local bytes
  bytes="${output##*: }"
  local positive="no"
  if [ "$bytes" -gt 0 ]; then
    positive="yes"
  fi
  echo "${label}: positive=${positive}"
}

emit_save "plugin-save-ok" save-plugin-local "$BASE_PLUGIN_DIR" gid-01 "$PLUGIN_SOURCE"
emit_save "algorithm-save-ok" save-plugin-algorithm-local "$BASE_PLUGIN_DIR" gid-01 cid-01 "$ALGORITHM_SOURCE"
emit_save "widgets-save-ok" save-plugin-widgets-local "$BASE_PLUGIN_DIR" gid-01 "$WIDGETS_SOURCE"
emit_save "inputs-save-ok" save-plugin-inputs-local "$BASE_PLUGIN_DIR" gid-01 "$INPUTS_SOURCE"

emit_get "plugin-get-ok" get-plugin-zip-local "$BASE_PLUGIN_DIR" gid-01
emit_get "algorithm-get-ok" get-plugin-algorithm-zip-local "$BASE_PLUGIN_DIR" gid-01 cid-01
emit_get "widgets-get-ok" get-plugin-widgets-zip-local "$BASE_PLUGIN_DIR" gid-01
emit_get "inputs-get-ok" get-plugin-inputs-zip-local "$BASE_PLUGIN_DIR" gid-01

delete_first_output="$("$ZIG_BIN" apigw delete-plugin-local "$BASE_PLUGIN_DIR" gid-01)"
delete_first="${delete_first_output#APIGW plugin deleted: }"
echo "plugin-delete-first: $delete_first"

delete_second_output="$("$ZIG_BIN" apigw delete-plugin-local "$BASE_PLUGIN_DIR" gid-01)"
delete_second="${delete_second_output#APIGW plugin deleted: }"
echo "plugin-delete-second: $delete_second"

if "$ZIG_BIN" apigw get-plugin-zip-local "$BASE_PLUGIN_DIR" gid-01 >/dev/null 2>&1; then
  echo "plugin-get-after-delete: ok"
else
  echo "plugin-get-after-delete: error"
fi
SH
  chmod +x "$TMP_DIR/apigw_plugin_archive_io_local_zig.sh"
}

write_apigw_plugin_mdx_bundle_io_local_reference() {
  cat >"$TMP_DIR/apigw_plugin_mdx_bundle_io_local_ref.py" <<'PY'
import json
import os
import re
import shutil
import sys
from pathlib import Path

base_plugin_dir = Path(sys.argv[1])
source_dir = Path(sys.argv[2])

GID = "gid-01"
CID = "cid-01"

def check_valid_filename(filename: str) -> bool:
    return re.search(r"\.\.", filename) is None and re.search(r"[^a-zA-Z0-9._\-/]", filename.replace("\\", "/")) is None

def validate_gid_cid(value: str) -> bool:
    return re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9\-._]*", value) is not None

def normalize(path: Path) -> str:
    return os.path.normpath(path.as_posix())

def save_mdx_bundles(gid: str, source: Path) -> Path:
    if not validate_gid_cid(gid):
        raise ValueError("InvalidGid")
    if not check_valid_filename(source.name):
        raise ValueError("InvalidFilename")
    if not source.exists() or not source.is_dir():
        raise FileNotFoundError("SourceNotFound")
    target = base_plugin_dir.joinpath(gid, "mdx_bundles")
    shutil.copytree(source, target, dirs_exist_ok=True)
    return target

def get_bundle(gid: str, cid: str, summary: bool = False):
    if not validate_gid_cid(gid):
        raise ValueError("InvalidGid")
    if not validate_gid_cid(cid):
        raise ValueError("InvalidCid")
    filename = f"{cid}.summary.bundle.json" if summary else f"{cid}.bundle.json"
    if not check_valid_filename(filename):
        raise ValueError("InvalidFilename")
    path = base_plugin_dir.joinpath(gid, "mdx_bundles", filename)
    if not path.exists():
        raise FileNotFoundError("BundleNotFound")
    with open(path, "rb") as fp:
        return json.load(fp)

saved = save_mdx_bundles(GID, source_dir)
print(f"save-ok: path={normalize(saved)}")

widget = get_bundle(GID, CID, summary=False)
print(f"get-widget-ok: code={widget.get('code')} frontmatter={widget.get('frontmatter')}")

summary = get_bundle(GID, CID, summary=True)
print(f"get-summary-ok: code={summary.get('code')} frontmatter={summary.get('frontmatter')}")

try:
    save_mdx_bundles("bad/gid", source_dir)
    print("invalid-gid-save: ok")
except Exception:
    print("invalid-gid-save: error")

try:
    get_bundle(GID, "missing-cid", summary=False)
    print("missing-bundle: ok")
except Exception:
    print("missing-bundle: error")
PY
}

write_apigw_plugin_mdx_bundle_io_local_zig_runner() {
  cat >"$TMP_DIR/apigw_plugin_mdx_bundle_io_local_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"
BASE_PLUGIN_DIR="$2"
SOURCE_DIR="$3"

normalize_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.normpath(sys.argv[1]))
PY
}

emit_bundle_fields() {
  python3 - "$1" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
print(f"code={obj.get('code')} frontmatter={obj.get('frontmatter')}")
PY
}

save_output="$("$ZIG_BIN" apigw save-plugin-mdx-bundles-local "$BASE_PLUGIN_DIR" gid-01 "$SOURCE_DIR")"
save_path="$(printf '%s\n' "$save_output" | sed -n 's/^  path: //p')"
save_path="$(normalize_path "$save_path")"
echo "save-ok: path=$save_path"

widget_output="$("$ZIG_BIN" apigw get-plugin-mdx-bundle-local "$BASE_PLUGIN_DIR" gid-01 cid-01)"
widget_json="${widget_output#APIGW plugin mdx bundle content: }"
echo "get-widget-ok: $(emit_bundle_fields "$widget_json")"

summary_output="$("$ZIG_BIN" apigw get-plugin-mdx-summary-bundle-local "$BASE_PLUGIN_DIR" gid-01 cid-01)"
summary_json="${summary_output#APIGW plugin mdx summary bundle content: }"
echo "get-summary-ok: $(emit_bundle_fields "$summary_json")"

if "$ZIG_BIN" apigw save-plugin-mdx-bundles-local "$BASE_PLUGIN_DIR" bad/gid "$SOURCE_DIR" >/dev/null 2>&1; then
  echo "invalid-gid-save: ok"
else
  echo "invalid-gid-save: error"
fi

if "$ZIG_BIN" apigw get-plugin-mdx-bundle-local "$BASE_PLUGIN_DIR" gid-01 missing-cid >/dev/null 2>&1; then
  echo "missing-bundle: ok"
else
  echo "missing-bundle: error"
fi
SH
  chmod +x "$TMP_DIR/apigw_plugin_mdx_bundle_io_local_zig.sh"
}

write_apigw_plugin_backup_local_reference() {
  cat >"$TMP_DIR/apigw_plugin_backup_local_ref.py" <<'PY'
import os
import re
import shutil
import sys
from pathlib import Path

base_plugin_dir = Path(sys.argv[1])
target_dir = Path(sys.argv[2])

GID = "gid-01"

def check_valid_filename(filename: str) -> bool:
    return re.search(r"\.\.", filename) is None and re.search(r"[^a-zA-Z0-9._\-/]", filename.replace("\\", "/")) is None

def validate_gid_cid(value: str) -> bool:
    return re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9\-._]*", value) is not None

plugin_ignore_patten = shutil.ignore_patterns(
    ".venv",
    "venv",
    "output",
    "node_modules",
    "build",
    "temp",
    "__pycache__",
    ".pytest_cache",
    ".cache",
    "*.pyc",
)

def normalize(path: Path) -> str:
    return os.path.normpath(path.as_posix())

def backup_plugin(gid: str, target: Path) -> Path:
    if not validate_gid_cid(gid):
        raise ValueError("InvalidGid")
    folder = base_plugin_dir.joinpath(gid)
    if not folder.exists() or not folder.is_dir():
        raise FileNotFoundError("PluginSourceNotFound")
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(folder, target, dirs_exist_ok=True, ignore=plugin_ignore_patten)
    return target

saved = backup_plugin(GID, target_dir)
print(f"backup-ok: path={normalize(saved)}")
print(f"copied-main: {'yes' if target_dir.joinpath('config/plugin.json').exists() else 'no'}")
print(f"copied-temp: {'yes' if target_dir.joinpath('temp/ignored.txt').exists() else 'no'}")
print(f"copied-node-modules: {'yes' if target_dir.joinpath('node_modules/mod.js').exists() else 'no'}")
print(f"copied-pyc: {'yes' if target_dir.joinpath('script.pyc').exists() else 'no'}")
print(f"replaced-stale: {'yes' if not target_dir.joinpath('stale.txt').exists() else 'no'}")
try:
    backup_plugin("bad/gid", target_dir)
    print("invalid-gid-backup: ok")
except Exception:
    print("invalid-gid-backup: error")
PY
}

write_apigw_plugin_backup_local_zig_runner() {
  cat >"$TMP_DIR/apigw_plugin_backup_local_zig.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="$1"
BASE_PLUGIN_DIR="$2"
TARGET_DIR="$3"

normalize_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.normpath(sys.argv[1]))
PY
}

backup_output="$("$ZIG_BIN" apigw backup-plugin-local "$BASE_PLUGIN_DIR" gid-01 "$TARGET_DIR")"
backup_path="$(printf '%s\n' "$backup_output" | sed -n 's/^  path: //p')"
backup_path="$(normalize_path "$backup_path")"
echo "backup-ok: path=$backup_path"

if [ -f "$TARGET_DIR/config/plugin.json" ]; then
  echo "copied-main: yes"
else
  echo "copied-main: no"
fi

if [ -f "$TARGET_DIR/temp/ignored.txt" ]; then
  echo "copied-temp: yes"
else
  echo "copied-temp: no"
fi

if [ -f "$TARGET_DIR/node_modules/mod.js" ]; then
  echo "copied-node-modules: yes"
else
  echo "copied-node-modules: no"
fi

if [ -f "$TARGET_DIR/script.pyc" ]; then
  echo "copied-pyc: yes"
else
  echo "copied-pyc: no"
fi

if [ ! -f "$TARGET_DIR/stale.txt" ]; then
  echo "replaced-stale: yes"
else
  echo "replaced-stale: no"
fi

if "$ZIG_BIN" apigw backup-plugin-local "$BASE_PLUGIN_DIR" bad/gid "$TARGET_DIR" >/dev/null 2>&1; then
  echo "invalid-gid-backup: ok"
else
  echo "invalid-gid-backup: error"
fi
SH
  chmod +x "$TMP_DIR/apigw_plugin_backup_local_zig.sh"
}

write_metrics_reference() {
  cat >"$TMP_DIR/metrics_gap_ref.py" <<'PY'
reference = 0.88
candidate = 0.81
delta = candidate - reference
if delta < 0:
    delta = -delta
print(f"Metric parity gap: {delta:.10f}")
PY
}

write_normalize_gid_reference() {
  cat >"$TMP_DIR/normalize_gid_ref.py" <<'PY'
text = "AIVERIFY.Stock   Reports "
output = []
previous_whitespace = False
for ch in text.lower():
    if ch in (" ", "\n", "\t", "\r"):
        if not previous_whitespace:
            output.append(" ")
        previous_whitespace = True
    else:
        output.append(ch)
        previous_whitespace = False
cleaned = "".join(output).strip()
print(f"Normalized plugin gid: {cleaned}")
PY
}

write_worker_once_reclaim_reference() {
  cat >"$TMP_DIR/worker_once_reclaim_ref.py" <<'PY'
task = '{"id":"reclaim-001"}'
lines = [
    "Worker once poll result",
    "  message_id: 1700-0",
    f"  task_size: {len(task)}",
    f"  task_preview: {task}",
    "  preview_truncated: no",
    "  acked: no",
    "  reclaim_mode: yes",
    "  reclaim_next_start: 0-0",
]
print("\n".join(lines))
PY
}

write_worker_once_reclaim_ack_reference() {
  cat >"$TMP_DIR/worker_once_reclaim_ack_ref.py" <<'PY'
task = '{"id":"reclaim-001"}'
lines = [
    "Worker once poll result",
    "  message_id: 1700-0",
    f"  task_size: {len(task)}",
    f"  task_preview: {task}",
    "  preview_truncated: no",
    "  acked: yes",
    "  reclaim_mode: yes",
    "  reclaim_next_start: 0-0",
]
print("\n".join(lines))
PY
}

write_worker_once_reclaim_empty_reference() {
  cat >"$TMP_DIR/worker_once_reclaim_empty_ref.py" <<'PY'
print("Worker once poll: no messages available. reclaim_next_start=0-0")
PY
}

write_worker_once_reclaim_invalid_start_reference() {
  cat >"$TMP_DIR/worker_once_reclaim_invalid_start_ref.py" <<'PY'
import sys

sys.stderr.write("error: InvalidResponseType\n")
raise SystemExit(1)
PY
}

case "$MODE" in
  test-engine-version|test-engine-version-flag|worker-config|apigw-config|apigw-config-hana|apigw-validate-gid-cid|apigw-check-valid-filename|apigw-sanitize-filename|apigw-check-relative-to-base|apigw-file-utils|apigw-plugin-storage-layout|apigw-data-storage-layout|apigw-artifact-io-local|apigw-model-dataset-io-local|apigw-plugin-archive-io-local|apigw-plugin-archive-io-local-hana|apigw-plugin-mdx-bundle-io-local|apigw-plugin-backup-local|worker-once-reclaim|worker-once-reclaim-ack|worker-once-reclaim-empty|worker-once-reclaim-invalid-start|metrics-gap|normalize-plugin-gid) ;;
  *)
    usage
    exit 2
    ;;
esac

if { [ "$MODE" = "worker-once-reclaim" ] || [ "$MODE" = "worker-once-reclaim-ack" ] || [ "$MODE" = "worker-once-reclaim-empty" ] || [ "$MODE" = "worker-once-reclaim-invalid-start" ]; } && [ "$QUEUE_BACKEND" != "valkey" ]; then
  echo "[parity] Mode $MODE is valkey-stream specific; skipping for queue backend '$QUEUE_BACKEND'"
  exit 0
fi

echo "[parity] Building Zig runtime..."
(
  cd "$ROOT_DIR/zig"
  zig build >/dev/null
)

ZIG_BIN="$ROOT_DIR/zig/zig-out/bin/aiverify-zig"
PY_WORKDIR="$ROOT_DIR"

case "$MODE" in
  test-engine-version-flag)
    PY_WORKDIR="$ROOT_DIR/aiverify-test-engine"
    PY_CMD=("$PYTHON_BIN" -m aiverify_test_engine --version)
    ZIG_CMD=("$ZIG_BIN" test-engine --version)
    ;;
  test-engine-version)
    PY_WORKDIR="$ROOT_DIR/aiverify-test-engine"
    PY_CMD=("$PYTHON_BIN" -m aiverify_test_engine)
    ZIG_CMD=("$ZIG_BIN" test-engine-version)
    ;;
  worker-config)
    write_worker_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/worker_config_ref.py")
    ZIG_CMD=("$ZIG_BIN" worker-config)
    ;;
  apigw-config)
    write_apigw_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_config_ref.py")
    ZIG_CMD=("$ZIG_BIN" apigw-config)
    ;;
  apigw-config-hana)
    write_apigw_reference
    MODE_APIGW_DB_URI="${AIVERIFY_HANA_DB_URI:-hana+hdbcli://SYSTEM:Password123@hana.local:39041}"
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_config_ref.py")
    ZIG_CMD=("$ZIG_BIN" apigw-config)
    ;;
  apigw-validate-gid-cid)
    write_apigw_validate_gid_cid_reference
    write_apigw_validate_gid_cid_zig_runner
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_validate_gid_cid_ref.py")
    ZIG_CMD=(bash "$TMP_DIR/apigw_validate_gid_cid_zig.sh" "$ZIG_BIN")
    ;;
  apigw-check-valid-filename)
    write_apigw_check_valid_filename_reference
    write_apigw_check_valid_filename_zig_runner
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_check_valid_filename_ref.py")
    ZIG_CMD=(bash "$TMP_DIR/apigw_check_valid_filename_zig.sh" "$ZIG_BIN")
    ;;
  apigw-sanitize-filename)
    write_apigw_sanitize_filename_reference
    write_apigw_sanitize_filename_zig_runner
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_sanitize_filename_ref.py")
    ZIG_CMD=(bash "$TMP_DIR/apigw_sanitize_filename_zig.sh" "$ZIG_BIN")
    ;;
  apigw-check-relative-to-base)
    write_apigw_check_relative_to_base_reference
    write_apigw_check_relative_to_base_zig_runner
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_check_relative_to_base_ref.py")
    ZIG_CMD=(bash "$TMP_DIR/apigw_check_relative_to_base_zig.sh" "$ZIG_BIN")
    ;;
  apigw-file-utils)
    write_apigw_file_utils_reference
    write_apigw_file_utils_zig_runner
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_file_utils_ref.py")
    ZIG_CMD=(bash "$TMP_DIR/apigw_file_utils_zig.sh" "$ZIG_BIN")
    ;;
  apigw-plugin-storage-layout)
    write_apigw_plugin_storage_layout_reference
    write_apigw_plugin_storage_layout_zig_runner
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_plugin_storage_layout_ref.py")
    ZIG_CMD=(bash "$TMP_DIR/apigw_plugin_storage_layout_zig.sh" "$ZIG_BIN")
    ;;
  apigw-data-storage-layout)
    write_apigw_data_storage_layout_reference
    write_apigw_data_storage_layout_zig_runner
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_data_storage_layout_ref.py")
    ZIG_CMD=(bash "$TMP_DIR/apigw_data_storage_layout_zig.sh" "$ZIG_BIN")
    ;;
  apigw-artifact-io-local)
    write_apigw_artifact_io_local_reference
    write_apigw_artifact_io_local_zig_runner
    ARTIFACT_BASE="$TMP_DIR/apigw_artifacts_io"
    mkdir -p "$ARTIFACT_BASE"
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_artifact_io_local_ref.py" "$ARTIFACT_BASE")
    ZIG_CMD=(bash "$TMP_DIR/apigw_artifact_io_local_zig.sh" "$ZIG_BIN" "$ARTIFACT_BASE")
    ;;
  apigw-model-dataset-io-local)
    write_apigw_model_dataset_io_local_reference
    write_apigw_model_dataset_io_local_zig_runner
    MODEL_DATASET_BASE="$TMP_DIR/apigw_model_dataset_io"
    MODELS_BASE="$MODEL_DATASET_BASE/models"
    DATASETS_BASE="$MODEL_DATASET_BASE/datasets"
    MODEL_SOURCE="$MODEL_DATASET_BASE/model_payload.bin"
    DATASET_SOURCE="$MODEL_DATASET_BASE/dataset_payload.csv"
    MODEL_DIR_SOURCE="$MODEL_DATASET_BASE/model_bundle"
    DATASET_DIR_SOURCE="$MODEL_DATASET_BASE/dataset_bundle"
    mkdir -p "$MODEL_DATASET_BASE"
    printf 'model_payload_01' >"$MODEL_SOURCE"
    printf 'dataset_payload_01' >"$DATASET_SOURCE"
    mkdir -p "$MODEL_DIR_SOURCE/weights" "$DATASET_DIR_SOURCE/records"
    printf 'model_bundle_payload_01' >"$MODEL_DIR_SOURCE/weights/tensor.bin"
    printf 'dataset_bundle_payload_01' >"$DATASET_DIR_SOURCE/records/data.csv"
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_model_dataset_io_local_ref.py" "$MODELS_BASE" "$DATASETS_BASE" "$MODEL_SOURCE" "$DATASET_SOURCE" "$MODEL_DIR_SOURCE" "$DATASET_DIR_SOURCE")
    ZIG_CMD=(bash "$TMP_DIR/apigw_model_dataset_io_local_zig.sh" "$ZIG_BIN" "$MODELS_BASE" "$DATASETS_BASE" "$MODEL_SOURCE" "$DATASET_SOURCE" "$MODEL_DIR_SOURCE" "$DATASET_DIR_SOURCE")
    ;;
  apigw-plugin-archive-io-local)
    write_apigw_plugin_archive_io_local_reference
    write_apigw_plugin_archive_io_local_zig_runner
    PLUGIN_ARCHIVE_BASE="$TMP_DIR/apigw_plugin_archive_io"
    PLUGIN_BASE="$PLUGIN_ARCHIVE_BASE/plugins"
    PLUGIN_SOURCE="$PLUGIN_ARCHIVE_BASE/plugin_src"
    ALGORITHM_SOURCE="$PLUGIN_ARCHIVE_BASE/algorithm_src"
    WIDGETS_SOURCE="$PLUGIN_ARCHIVE_BASE/widgets_src"
    INPUTS_SOURCE="$PLUGIN_ARCHIVE_BASE/inputs_src"
    mkdir -p "$PLUGIN_SOURCE/config" "$ALGORITHM_SOURCE" "$WIDGETS_SOURCE" "$INPUTS_SOURCE"
    printf '{"name":"plugin"}' >"$PLUGIN_SOURCE/config/plugin.json"
    printf 'print("algo")' >"$ALGORITHM_SOURCE/algorithm.py"
    printf 'console.log("widget");' >"$WIDGETS_SOURCE/widget.js"
    printf '{"input":true}' >"$INPUTS_SOURCE/input.json"
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_plugin_archive_io_local_ref.py" "$PLUGIN_BASE" "$PLUGIN_SOURCE" "$ALGORITHM_SOURCE" "$WIDGETS_SOURCE" "$INPUTS_SOURCE")
    ZIG_CMD=(bash "$TMP_DIR/apigw_plugin_archive_io_local_zig.sh" "$ZIG_BIN" "$PLUGIN_BASE" "$PLUGIN_SOURCE" "$ALGORITHM_SOURCE" "$WIDGETS_SOURCE" "$INPUTS_SOURCE")
    ;;
  apigw-plugin-archive-io-local-hana)
    write_apigw_plugin_archive_io_local_reference
    write_apigw_plugin_archive_io_local_zig_runner
    PLUGIN_ARCHIVE_BASE="$TMP_DIR/apigw_plugin_archive_io_hana"
    PLUGIN_BASE="$PLUGIN_ARCHIVE_BASE/plugins"
    PLUGIN_SOURCE="$PLUGIN_ARCHIVE_BASE/plugin_src"
    ALGORITHM_SOURCE="$PLUGIN_ARCHIVE_BASE/algorithm_src"
    WIDGETS_SOURCE="$PLUGIN_ARCHIVE_BASE/widgets_src"
    INPUTS_SOURCE="$PLUGIN_ARCHIVE_BASE/inputs_src"
    mkdir -p "$PLUGIN_SOURCE/config" "$ALGORITHM_SOURCE" "$WIDGETS_SOURCE" "$INPUTS_SOURCE"
    printf '{"name":"plugin"}' >"$PLUGIN_SOURCE/config/plugin.json"
    printf 'print("algo")' >"$ALGORITHM_SOURCE/algorithm.py"
    printf 'console.log("widget");' >"$WIDGETS_SOURCE/widget.js"
    printf '{"input":true}' >"$INPUTS_SOURCE/input.json"
    MODE_APIGW_DB_URI="${AIVERIFY_HANA_DB_URI:-hana+hdbcli://SYSTEM:Password123@hana.local:39041}"
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_plugin_archive_io_local_ref.py" "$PLUGIN_BASE" "$PLUGIN_SOURCE" "$ALGORITHM_SOURCE" "$WIDGETS_SOURCE" "$INPUTS_SOURCE")
    ZIG_CMD=(bash "$TMP_DIR/apigw_plugin_archive_io_local_zig.sh" "$ZIG_BIN" "$PLUGIN_BASE" "$PLUGIN_SOURCE" "$ALGORITHM_SOURCE" "$WIDGETS_SOURCE" "$INPUTS_SOURCE")
    ;;
  apigw-plugin-mdx-bundle-io-local)
    write_apigw_plugin_mdx_bundle_io_local_reference
    write_apigw_plugin_mdx_bundle_io_local_zig_runner
    PLUGIN_MDX_BASE="$TMP_DIR/apigw_plugin_mdx_bundle_io"
    PLUGIN_BASE="$PLUGIN_MDX_BASE/plugins"
    MDX_SOURCE="$PLUGIN_MDX_BASE/mdx_source"
    mkdir -p "$MDX_SOURCE"
    printf '{"code":"widget_code_01","frontmatter":"widget_frontmatter_01"}' >"$MDX_SOURCE/cid-01.bundle.json"
    printf '{"code":"summary_code_01","frontmatter":"summary_frontmatter_01"}' >"$MDX_SOURCE/cid-01.summary.bundle.json"
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_plugin_mdx_bundle_io_local_ref.py" "$PLUGIN_BASE" "$MDX_SOURCE")
    ZIG_CMD=(bash "$TMP_DIR/apigw_plugin_mdx_bundle_io_local_zig.sh" "$ZIG_BIN" "$PLUGIN_BASE" "$MDX_SOURCE")
    ;;
  apigw-plugin-backup-local)
    write_apigw_plugin_backup_local_reference
    write_apigw_plugin_backup_local_zig_runner
    PLUGIN_BACKUP_BASE="$TMP_DIR/apigw_plugin_backup_io"
    PLUGIN_BASE="$PLUGIN_BACKUP_BASE/plugins"
    PLUGIN_SOURCE="$PLUGIN_BASE/gid-01"
    TARGET_DIR="$PLUGIN_BACKUP_BASE/backup_target"
    mkdir -p "$PLUGIN_SOURCE/config" "$PLUGIN_SOURCE/temp" "$PLUGIN_SOURCE/node_modules"
    printf '{"name":"plugin"}' >"$PLUGIN_SOURCE/config/plugin.json"
    printf 'ignored-temp' >"$PLUGIN_SOURCE/temp/ignored.txt"
    printf 'ignored-node-modules' >"$PLUGIN_SOURCE/node_modules/mod.js"
    printf 'ignored-pyc' >"$PLUGIN_SOURCE/script.pyc"
    mkdir -p "$TARGET_DIR"
    printf 'stale' >"$TARGET_DIR/stale.txt"
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/apigw_plugin_backup_local_ref.py" "$PLUGIN_BASE" "$TARGET_DIR")
    ZIG_CMD=(bash "$TMP_DIR/apigw_plugin_backup_local_zig.sh" "$ZIG_BIN" "$PLUGIN_BASE" "$TARGET_DIR")
    ;;
  worker-once-reclaim)
    prepare_worker_reclaim_fixture message
    write_worker_once_reclaim_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/worker_once_reclaim_ref.py")
    ZIG_CMD=("$ZIG_BIN" worker-once --reclaim --min-idle-ms 0 --start 0-0)
    ;;
  worker-once-reclaim-ack)
    prepare_worker_reclaim_fixture message
    write_worker_once_reclaim_ack_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/worker_once_reclaim_ack_ref.py")
    ZIG_CMD=("$ZIG_BIN" worker-once --reclaim --ack --min-idle-ms 0 --start 0-0)
    ;;
  worker-once-reclaim-empty)
    prepare_worker_reclaim_fixture empty
    write_worker_once_reclaim_empty_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/worker_once_reclaim_empty_ref.py")
    ZIG_CMD=("$ZIG_BIN" worker-once --reclaim --min-idle-ms 0 --start 0-0)
    ;;
  worker-once-reclaim-invalid-start)
    prepare_worker_reclaim_fixture message
    write_worker_once_reclaim_invalid_start_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/worker_once_reclaim_invalid_start_ref.py")
    ZIG_CMD=("$ZIG_BIN" worker-once --reclaim --min-idle-ms 0 --start bad-id)
    ;;
  metrics-gap)
    write_metrics_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/metrics_gap_ref.py")
    ZIG_CMD=("$ZIG_BIN" metrics-gap 0.88 0.81)
    ;;
  normalize-plugin-gid)
    write_normalize_gid_reference
    PY_CMD=("$PYTHON_BIN" "$TMP_DIR/normalize_gid_ref.py")
    ZIG_CMD=("$ZIG_BIN" normalize-plugin-gid "AIVERIFY.Stock   Reports ")
    ;;
esac

echo "[parity] Running Python reference: ${PY_CMD[*]}"
if [ -n "$MODE_APIGW_DB_URI" ]; then
  (
    cd "$PY_WORKDIR"
    AIVERIFY_ROOT_DIR="$ROOT_DIR" APIGW_DB_URI="$MODE_APIGW_DB_URI" "${PY_CMD[@]}" >"$TMP_DIR/python.stdout" 2>"$TMP_DIR/python.stderr"
  )
else
  (
    cd "$PY_WORKDIR"
    AIVERIFY_ROOT_DIR="$ROOT_DIR" "${PY_CMD[@]}" >"$TMP_DIR/python.stdout" 2>"$TMP_DIR/python.stderr"
  )
fi
PY_EXIT=$?

echo "[parity] Running Zig bridge: ${ZIG_CMD[*]}"
if [ "$MODE" = "worker-once-reclaim" ] || [ "$MODE" = "worker-once-reclaim-ack" ] || [ "$MODE" = "worker-once-reclaim-empty" ] || [ "$MODE" = "worker-once-reclaim-invalid-start" ]; then
  (
    cd "$ROOT_DIR"
    VALKEY_HOST_ADDRESS=127.0.0.1 VALKEY_PORT="$KV_PORT" "${ZIG_CMD[@]}" >"$TMP_DIR/zig.stdout" 2>"$TMP_DIR/zig.stderr"
  )
elif [ -n "$MODE_APIGW_DB_URI" ]; then
  (
    cd "$ROOT_DIR"
    APIGW_DB_URI="$MODE_APIGW_DB_URI" "${ZIG_CMD[@]}" >"$TMP_DIR/zig.stdout" 2>"$TMP_DIR/zig.stderr"
  )
else
  (
    cd "$ROOT_DIR"
    "${ZIG_CMD[@]}" >"$TMP_DIR/zig.stdout" 2>"$TMP_DIR/zig.stderr"
  )
fi
ZIG_EXIT=$?

echo "[parity] Python exit: $PY_EXIT"
echo "[parity] Zig exit:    $ZIG_EXIT"

if [ "$PY_EXIT" -ne "$ZIG_EXIT" ]; then
  echo "[parity] Exit code mismatch"
  diff -u "$TMP_DIR/python.stderr" "$TMP_DIR/zig.stderr" || true
  exit 1
fi

PY_STDOUT_FILE="$TMP_DIR/python.stdout"
ZIG_STDOUT_FILE="$TMP_DIR/zig.stdout"
if [ "$MODE" = "metrics-gap" ] || [ "$MODE" = "normalize-plugin-gid" ]; then
  sed -E 's/ \(source=[^)]+\)//' "$TMP_DIR/zig.stdout" >"$TMP_DIR/zig.stdout.canonical"
  ZIG_STDOUT_FILE="$TMP_DIR/zig.stdout.canonical"
fi

if ! diff -u "$PY_STDOUT_FILE" "$ZIG_STDOUT_FILE" >/dev/null; then
  echo "[parity] STDOUT mismatch"
  diff -u "$PY_STDOUT_FILE" "$ZIG_STDOUT_FILE" || true
  exit 1
fi

PY_STDERR_FILE="$TMP_DIR/python.stderr"
ZIG_STDERR_FILE="$TMP_DIR/zig.stderr"
if [ "$MODE" = "worker-once-reclaim-invalid-start" ]; then
  sed -n '1p' "$TMP_DIR/python.stderr" >"$TMP_DIR/python.stderr.canonical"
  sed -n '1p' "$TMP_DIR/zig.stderr" >"$TMP_DIR/zig.stderr.canonical"
  PY_STDERR_FILE="$TMP_DIR/python.stderr.canonical"
  ZIG_STDERR_FILE="$TMP_DIR/zig.stderr.canonical"
fi

if ! diff -u "$PY_STDERR_FILE" "$ZIG_STDERR_FILE" >/dev/null; then
  echo "[parity] STDERR mismatch"
  diff -u "$PY_STDERR_FILE" "$ZIG_STDERR_FILE" || true
  exit 1
fi

if [ "$MODE" = "worker-once-reclaim-ack" ]; then
  pending_count="$("$KV_CLI_BIN" -h 127.0.0.1 -p "$KV_PORT" --raw XPENDING "$KV_STREAM" "$KV_GROUP" | head -n 1)"
  if [ "$pending_count" != "0" ]; then
    echo "[parity] Expected pending count to be 0 after reclaim+ack, got: $pending_count"
    exit 1
  fi
fi

if [ "$MODE" = "worker-once-reclaim-invalid-start" ]; then
  pending_count="$("$KV_CLI_BIN" -h 127.0.0.1 -p "$KV_PORT" --raw XPENDING "$KV_STREAM" "$KV_GROUP" | head -n 1)"
  if [ "$pending_count" != "1" ]; then
    echo "[parity] Expected pending count to remain 1 after invalid reclaim start, got: $pending_count"
    exit 1
  fi
fi

echo "[parity] PASS"

from pathlib import Path
import os
import subprocess
import sys


def test_embedding_service_missing_gen_ai_hub_dependency_has_clear_error():
    src_dir = Path(__file__).resolve().parents[1] / "src"
    env = os.environ.copy()
    existing_pythonpath = env.get("PYTHONPATH")
    env["PYTHONPATH"] = str(src_dir) if not existing_pythonpath else os.pathsep.join([str(src_dir), existing_pythonpath])

    result = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "try:\n"
                "    import hana_ai.vectorstore.embedding_service\n"
                "except ImportError as exc:\n"
                "    print(exc)\n"
                "else:\n"
                "    raise SystemExit('embedding_service import unexpectedly succeeded')\n"
            ),
        ],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "Package 'sap-ai-sdk-gen[all]' is required. Install with: pip install 'sap-ai-sdk-gen[all]'"
#!/usr/bin/env python3
"""
ml_lineage.py — ML model card and dataset provenance for QuantumBlack-style lineage.

For each service that uses ML frameworks (torch, transformers, diffusers, etc.):
  1. Detects the ML stack (framework, version, hardware targets).
  2. Discovers referenced HuggingFace model IDs in source code.
  3. Generates a structured model card JSON (Hugging Face / EU AI Act format).
  4. Generates a CycloneDX 1.5 `formulation[]` component for each model.
  5. Emits dataset provenance records for any referenced datasets.
  6. Writes everything to boms/ml/<service>.ml_lineage.json.

Output also includes a combined summary at boms/ml/summary.json.

Usage:
  python3 scripts/sbom-lineage/ml_lineage.py [--repo-root DIR] [--boms-dir DIR] [--json]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml as _yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

REPO_ROOT        = Path(__file__).resolve().parents[2]
MANIFEST_PATH    = REPO_ROOT / "docs" / "sbom-lineage-manifest.yaml"
BOMS_DIR_DEFAULT = Path(__file__).parent / "boms"

# ── ML framework detection signatures ────────────────────────────────────────
_ML_FRAMEWORKS = {
    "torch":          {"name": "PyTorch",       "vendor": "Meta AI",           "license": "BSD-3-Clause"},
    "tensorflow":     {"name": "TensorFlow",    "vendor": "Google",            "license": "Apache-2.0"},
    "jax":            {"name": "JAX",           "vendor": "Google DeepMind",   "license": "Apache-2.0"},
    "transformers":   {"name": "HuggingFace Transformers", "vendor": "Hugging Face", "license": "Apache-2.0"},
    "diffusers":      {"name": "HuggingFace Diffusers",    "vendor": "Hugging Face", "license": "Apache-2.0"},
    "peft":           {"name": "PEFT",          "vendor": "Hugging Face",      "license": "Apache-2.0"},
    "trl":            {"name": "TRL",           "vendor": "Hugging Face",      "license": "Apache-2.0"},
    "accelerate":     {"name": "Accelerate",    "vendor": "Hugging Face",      "license": "Apache-2.0"},
    "datasets":       {"name": "HuggingFace Datasets", "vendor": "Hugging Face", "license": "Apache-2.0"},
    "lm-eval":        {"name": "LM Evaluation Harness", "vendor": "EleutherAI", "license": "MIT"},
    "lm_eval":        {"name": "LM Evaluation Harness", "vendor": "EleutherAI", "license": "MIT"},
    "vllm":           {"name": "vLLM",          "vendor": "vLLM Project",      "license": "Apache-2.0"},
    "langchain":      {"name": "LangChain",     "vendor": "LangChain Inc.",    "license": "MIT"},
    "langchain_core": {"name": "LangChain Core","vendor": "LangChain Inc.",    "license": "MIT"},
    "openai":         {"name": "OpenAI SDK",    "vendor": "OpenAI",            "license": "MIT"},
    "anthropic":      {"name": "Anthropic SDK", "vendor": "Anthropic",         "license": "MIT"},
    "hana_ml":        {"name": "SAP HANA ML",   "vendor": "SAP SE",            "license": "LicenseRef-SAP-Proprietary"},
    "generative_ai_hub_sdk": {"name": "SAP AI Core GenAI Hub", "vendor": "SAP SE", "license": "LicenseRef-SAP-Proprietary"},
    "pandera":        {"name": "Pandera",        "vendor": "Union.ai",          "license": "MIT"},
    "relbench":       {"name": "RelBench",       "vendor": "Stanford SNAP",     "license": "MIT"},
}

# Hardware targets
_HW_TARGETS = {
    "cuda":  "NVIDIA CUDA GPU",
    "rocm":  "AMD ROCm GPU",
    "tpu":   "Google TPU",
    "mps":   "Apple Silicon MPS",
    "cpu":   "CPU (no accelerator)",
    "xpu":   "Intel XPU",
}

# Patterns that indicate model references in source code
_HF_MODEL_RE = re.compile(
    r"""["']([a-zA-Z0-9_\-]+/[a-zA-Z0-9_\-\.]+)["']""",
    re.MULTILINE,
)
_DATASET_RE = re.compile(
    r"""load_dataset\s*\(\s*["']([^"']+)["']""",
    re.MULTILINE,
)
# Well-known HuggingFace model-id prefixes (to reduce false positives)
_HF_ORG_PREFIXES = {
    "meta-llama", "mistralai", "google", "microsoft", "openai", "EleutherAI",
    "tiiuae", "facebook", "salesforce", "bigscience", "Qwen", "deepseek-ai",
    "baichuan-inc", "01-ai", "HuggingFaceH4", "sentence-transformers",
    "cross-encoder", "bert-base", "gpt2", "roberta", "distilbert",
    "SAP-samples", "intfloat", "BAAI", "nomic-ai",
}


def _deps_from_bom(bom_path: Path) -> dict[str, str]:
    """Return {pkg_name: version} from a CycloneDX BOM's components list."""
    if not bom_path.exists():
        return {}
    try:
        bom = json.loads(bom_path.read_text(encoding="utf-8"))
        return {c["name"]: str(c.get("version", "")) for c in bom.get("components", []) if c.get("name")}
    except Exception:
        return {}


def _detect_ml_stack(deps: dict[str, str]) -> dict[str, dict]:
    """Return {pkg_key: {name, vendor, license, version}} for each detected ML framework."""
    found: dict[str, dict] = {}
    deps_lower = {k.lower().replace("-", "_"): (k, v) for k, v in deps.items()}
    for key, meta in _ML_FRAMEWORKS.items():
        norm = key.replace("-", "_")
        if norm in deps_lower:
            orig_k, ver = deps_lower[norm]
            found[key] = {**meta, "version": ver, "purl": f"pkg:pypi/{orig_k}@{ver}"}
    return found


def _detect_hardware(bom_path: Path) -> list[str]:
    """Detect hardware targets from requirements / BOM component names."""
    targets: list[str] = []
    if not bom_path.exists():
        return targets
    try:
        text = bom_path.read_text(encoding="utf-8").lower()
        for hw, label in _HW_TARGETS.items():
            if hw in text:
                targets.append(label)
    except Exception:
        pass
    return targets or ["CPU (no accelerator)"]


def _scan_source_for_models(svc_dir: Path) -> tuple[list[str], list[str]]:
    """Scan Python source files for HuggingFace model-id strings and dataset references."""
    models: set[str] = set()
    datasets: set[str] = set()
    skip = {"node_modules", ".git", "__pycache__", "venv", ".venv", ".sbom-venv", "dist", "build"}

    for py_file in svc_dir.rglob("*.py"):
        if any(part in skip for part in py_file.parts):
            continue
        try:
            text = py_file.read_text(encoding="utf-8", errors="replace")
            for m in _HF_MODEL_RE.finditer(text):
                candidate = m.group(1)
                org = candidate.split("/")[0]
                if org in _HF_ORG_PREFIXES or org.lower() in _HF_ORG_PREFIXES:
                    models.add(candidate)
            for m in _DATASET_RE.finditer(text):
                datasets.add(m.group(1))
        except OSError:
            pass
    return sorted(models), sorted(datasets)


def _model_card(
    service_name: str,
    ml_stack: dict[str, dict],
    hardware: list[str],
    model_refs: list[str],
    dataset_refs: list[str],
    service_meta: dict,
) -> dict:
    """Generate a structured model card (Hugging Face / EU AI Act aligned)."""
    frameworks = [f"{v['name']} {v.get('version', '').strip() or 'unknown'}" for v in ml_stack.values()]
    return {
        "schema_version": "1.0",
        "model_card_format": "HuggingFace-v0.2 / EU-AI-Act-Annex-IV",
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "model_details": {
            "name": service_meta.get("name", service_name),
            "description": f"SAP OSS service: {service_meta.get('name', service_name)}",
            "version": service_meta.get("version", "NOASSERTION"),
            "license": "LicenseRef-SAP-Proprietary",
            "contact": "SAP SE — AI & Open-Source Office",
            "upstream": service_meta.get("upstream", ""),
        },
        "intended_use": {
            "primary_uses": ["Enterprise AI / ML inference", "Data processing"],
            "out_of_scope": ["Safety-critical systems without additional validation"],
        },
        "technical_specifications": {
            "ml_frameworks": frameworks,
            "hardware_requirements": hardware,
            "referenced_base_models": model_refs,
            "referenced_datasets": dataset_refs,
        },
        "provenance": {
            "framework_components": [
                {
                    "name":    v["name"],
                    "vendor":  v["vendor"],
                    "version": v.get("version", ""),
                    "license": v["license"],
                    "purl":    v.get("purl", ""),
                }
                for v in ml_stack.values()
            ],
            "base_model_sources": [
                {
                    "model_id":   mid,
                    "source":     f"https://huggingface.co/{mid}",
                    "provenance": "HuggingFace Model Hub — verify license at source before deployment",
                }
                for mid in model_refs
            ],
            "dataset_sources": [
                {
                    "dataset_id": did,
                    "source":     f"https://huggingface.co/datasets/{did}" if "/" in did else f"dataset:{did}",
                    "provenance": "HuggingFace Datasets / third-party — verify data licence before use",
                }
                for did in dataset_refs
            ],
        },
        "eu_ai_act": {
            "risk_category":   "Limited risk (Article 52) — requires transparency notification",
            "transparency_obligations": [
                "Users must be informed they are interacting with an AI system",
                "Training data must be documented for high-risk use cases",
            ],
            "conformity_assessment": "pending",
        },
        "data_governance": {
            "training_data_documented": bool(dataset_refs),
            "privacy_impact_assessed":  False,
            "data_retention_policy":    "Not specified — consult SAP Data Governance team",
        },
    }


def _cdx_formulation(ml_stack: dict[str, dict], model_refs: list[str]) -> list[dict]:
    """Build CycloneDX 1.5 formulation[] entries for ML components."""
    components: list[dict] = []
    for key, v in ml_stack.items():
        comp: dict = {
            "type":    "library",
            "name":    v["name"],
            "version": v.get("version", ""),
            "supplier": {"name": v["vendor"]},
            "licenses": [{"license": {"id": v["license"]}}],
        }
        if v.get("purl"):
            comp["purl"] = v["purl"]
        components.append(comp)
    for mid in model_refs:
        components.append({
            "type":        "machine-learning-model",
            "name":        mid,
            "description": f"HuggingFace base model — {mid}",
            "externalReferences": [
                {"type": "website", "url": f"https://huggingface.co/{mid}"}
            ],
            "licenses": [{"license": {"id": "NOASSERTION"}}],
        })
    return [{"workflows": [{"name": "inference", "taskTypes": ["inference"], "components": components}]}]


def process_service(svc: dict, repo_root: Path, boms_dir: Path) -> dict | None:
    """Process one service. Returns result dict or None if not ML."""
    path_str = svc.get("path", "")
    svc_dir  = repo_root / path_str
    bom_path = boms_dir / f"{path_str}.cyclonedx.json"

    if not svc_dir.is_dir():
        return None

    deps     = _deps_from_bom(bom_path)
    ml_stack = _detect_ml_stack(deps)
    if not ml_stack:
        return None   # not an ML service — skip

    hardware    = _detect_hardware(bom_path)
    model_refs, dataset_refs = _scan_source_for_models(svc_dir)
    card        = _model_card(path_str, ml_stack, hardware, model_refs, dataset_refs, svc)
    formulation = _cdx_formulation(ml_stack, model_refs)

    return {
        "service":          path_str,
        "ml_frameworks":    list(ml_stack.keys()),
        "hardware_targets": hardware,
        "model_refs":       model_refs,
        "dataset_refs":     dataset_refs,
        "model_card":       card,
        "cdx_formulation":  formulation,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="ML model card and dataset provenance for CycloneDX BOMs"
    )
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--boms-dir",  type=Path, default=BOMS_DIR_DEFAULT)
    parser.add_argument("--json",      action="store_true")
    args = parser.parse_args()

    if not _YAML_AVAILABLE:
        print("PyYAML required: pip install pyyaml", file=sys.stderr)
        sys.exit(1)

    with open(MANIFEST_PATH, encoding="utf-8") as fh:
        services = (_yaml.safe_load(fh) or {}).get("services", [])

    out_dir = args.boms_dir / "ml"
    out_dir.mkdir(parents=True, exist_ok=True)

    results: list[dict] = []
    for svc in services:
        path_str = svc.get("path", "")
        print(f"  Checking {path_str} ...", file=sys.stderr, flush=True)
        result = process_service(svc, args.repo_root, args.boms_dir)
        if result is None:
            continue
        results.append(result)

        out_path = out_dir / f"{path_str}.ml_lineage.json"
        out_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")

        # Optionally inject formulation[] into the BOM
        bom_path = args.boms_dir / f"{path_str}.cyclonedx.json"
        if bom_path.exists():
            try:
                bom = json.loads(bom_path.read_text(encoding="utf-8"))
                bom["formulation"] = result["cdx_formulation"]
                bom_path.write_text(json.dumps(bom, indent=2, ensure_ascii=False), encoding="utf-8")
            except Exception as exc:
                print(f"  [WARN] Could not update BOM for {path_str}: {exc}", file=sys.stderr)

    # Write summary
    summary = {
        "generated":   datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ml_services": len(results),
        "services":    [
            {
                "service":       r["service"],
                "frameworks":    r["ml_frameworks"],
                "model_refs":    len(r["model_refs"]),
                "dataset_refs":  len(r["dataset_refs"]),
                "hw_targets":    r["hardware_targets"],
            }
            for r in results
        ],
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print("\n" + "=" * 72)
        print("  ML LINEAGE REPORT")
        print("=" * 72)
        if not results:
            print("  No ML services detected.")
        for r in results:
            print(f"\n  ✓  {r['service']}")
            print(f"     Frameworks  : {', '.join(r['ml_frameworks'])}")
            print(f"     Hardware    : {', '.join(r['hardware_targets'])}")
            if r["model_refs"]:
                print(f"     Base models : {r['model_refs'][:4]}{' ...' if len(r['model_refs'])>4 else ''}")
            if r["dataset_refs"]:
                print(f"     Datasets    : {r['dataset_refs'][:4]}{' ...' if len(r['dataset_refs'])>4 else ''}")
        print(f"\n  Model cards written to {out_dir}/")
        print("=" * 72)


if __name__ == "__main__":
    main()


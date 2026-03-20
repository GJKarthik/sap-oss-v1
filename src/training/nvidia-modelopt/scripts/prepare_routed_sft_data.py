#!/usr/bin/env python3
"""Bridge routed training data into legacy instruction/input/output SFT format."""

import argparse
import json
from pathlib import Path

ANALYTICS_TABLES = {
    "performance": ["CRD_FACT", "NFRP_ACCOUNT_AM", "NFRP_LOCATION_AM", "NFRP_PRODUCT_AM", "NFRP_SEGMENT_AM", "NFRP_COST_AM"],
    "balance_sheet": ["CRD_FACT", "NFRP_ACCOUNT_AM", "NFRP_LOCATION_AM"],
    "regulatory": ["CRD_FACT", "NFRP_ACCOUNT_AM"],
    "treasury": ["GLB_SECURITIES"],
    "esg": ["ESG_CLIENT", "ESG_NETZERO", "ESG_SUSTAINABLE_FINANCE"],
}


def infer_context(item):
    if item.get("context"):
        return item["context"]
    domain = item.get("domain", "")
    if domain in {"schema", "staging"}:
        return "data_quality"
    return "analytics_ui"


def infer_allowed_tables(item):
    if item.get("allowed_tables"):
        return item["allowed_tables"]
    context = infer_context(item)
    domain = item.get("domain", "")
    if context == "data_quality":
        return ["DATA_LINEAGE_CATALOG", "DATA_VALIDATION_RULES"]
    if context == "pipeline_ops":
        return ["DATA_REGISTER", "DATA_LINEAGE_CATALOG", "DATA_VALIDATION_RULES"]
    return ANALYTICS_TABLES.get(domain, ["CRD_FACT"])


def infer_system_prompt(item):
    if item.get("system_prompt"):
        return item["system_prompt"]
    return item.get("instruction", "Generate SAP HANA SQL for the user's request.")


def build_input(question, item, allowed_tables, history=None):
    parts = [
        f"Context: {infer_context(item)}",
        f"Domain: {item.get('domain', 'unknown')}",
        f"Allowed tables: {', '.join(allowed_tables)}",
    ]
    if item.get("type"):
        parts.append(f"Example type: {item['type']}")
    if history:
        parts.append("Conversation history:")
        parts.append(history)
    parts.append(f"Question: {question}")
    return "\n".join(parts)


def convert_single(item):
    question = item.get("question")
    answer = item.get("sql") or item.get("response") or item.get("output")
    if not question or not answer:
        return []
    allowed = infer_allowed_tables(item)
    return [{
        "instruction": infer_system_prompt(item),
        "input": build_input(question, item, allowed),
        "output": answer,
        "domain": item.get("domain"),
        "type": item.get("type"),
        "context": infer_context(item),
        "allowed_tables": allowed,
        "source_format": "routed_single_turn",
    }]


def render_turn(turn):
    role = turn.get("role", "user").capitalize()
    if turn.get("sql"):
        return f"{role}: {turn.get('content', '').strip()}\nSQL: {turn['sql']}"
    return f"{role}: {turn.get('content', '').strip()}"


def convert_multi_turn(item):
    turns = item.get("turns") or []
    if not turns:
        return []
    allowed = infer_allowed_tables(item)
    out = []
    history = []
    last_user_content = ""
    for turn in turns:
        if turn.get("role") == "user":
            last_user_content = turn.get("content", "")
        if turn.get("role") == "assistant":
            answer = turn.get("sql") or turn.get("content")
            if history and answer and last_user_content:
                out.append({
                    "instruction": infer_system_prompt(item),
                    "input": build_input(last_user_content, item, allowed, "\n".join(history)),
                    "output": answer,
                    "domain": item.get("domain"),
                    "type": item.get("type"),
                    "context": infer_context(item),
                    "allowed_tables": allowed,
                    "source_format": "routed_multi_turn",
                })
        history.append(render_turn(turn))
    return out


def convert_item(item):
    return convert_multi_turn(item) if item.get("turns") else convert_single(item)


def convert_file(input_path, output_path, max_samples=None):
    count_in = count_out = 0
    with open(input_path) as src, open(output_path, "w") as dst:
        for line in src:
            if max_samples and count_in >= max_samples:
                break
            count_in += 1
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            for ex in convert_item(item):
                dst.write(json.dumps(ex) + "\n")
                count_out += 1
    return count_in, count_out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--max-samples", type=int)
    args = ap.parse_args()
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    count_in, count_out = convert_file(args.input, args.output, args.max_samples)
    print(f"Converted {count_in:,} source rows into {count_out:,} SFT rows")
    print(f"Saved to {args.output}")


if __name__ == "__main__":
    main()


#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

EMBEDDING_MODEL = "Qwen/Qwen3-Embedding-0.6B"
TEACHER_MODEL = "Qwen/Qwen3-Embedding-4B"
FALLBACK_MODEL = "current-baseline-embedding-model"
JSONL_FILES = {
    "corpusCount": "corpus.jsonl",
    "trainPairCount": "train_pairs.jsonl",
    "valPairCount": "val_pairs.jsonl",
    "trainTripletCount": "train_triplets.jsonl",
    "valTripletCount": "val_triplets.jsonl",
    "hardNegativeCount": "hard_negatives.jsonl",
    "evalCount": "eval_retrieval.jsonl",
}


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def count_jsonl(path: Path) -> int:
    if not path.exists():
        return 0
    with path.open("r", encoding="utf-8") as handle:
        return sum(1 for line in handle if line.strip())


def build_summary(embedding_dir: Path) -> dict[str, Any]:
    card = read_json(embedding_dir / "dataset_card.json")
    summary: dict[str, Any] = {
        "model": card.get("model") or EMBEDDING_MODEL,
        "fallbackModel": FALLBACK_MODEL,
        "teacherModel": card.get("teacherModel") or TEACHER_MODEL,
        "usedFallback": False,
        "artifactDirectory": str(embedding_dir),
        "metrics": {
            "recallAt1": 0.0,
            "recallAt5": 0.0,
            "mrr": 0.0,
            "ndcgAt5": 0.0,
            "hardNegativeAccuracy": 0.0,
            "toolRetrievalAccuracy": 0.0,
            "sourceMapRetrievalAccuracy": 0.0,
            "runtimeRepairRetrievalAccuracy": 0.0,
        },
    }
    for key, filename in JSONL_FILES.items():
        summary[key] = count_jsonl(embedding_dir / filename)
    summary["pairCount"] = summary["trainPairCount"] + summary["valPairCount"]
    summary["tripletCount"] = summary["trainTripletCount"] + summary["valTripletCount"]
    summary["generated"] = any(summary[key] > 0 for key in JSONL_FILES)
    summary["datasetCard"] = {
        "schemaVersion": card.get("schemaVersion"),
        "task": card.get("task"),
        "promotionMetrics": card.get("promotionMetrics", {}),
        "families": card.get("families", []),
    }
    return summary


def apply_embedding(payload: dict[str, Any], embedding: dict[str, Any]) -> dict[str, Any]:
    payload["embedding"] = embedding
    dataset = payload.get("dataset") if isinstance(payload.get("dataset"), dict) else {}
    dataset["embedding"] = embedding
    payload["dataset"] = dataset
    return payload


def augment(loop_state_path: Path, embedding_dir: Path, visual_summary_path: Path | None = None) -> dict[str, Any]:
    state = read_json(loop_state_path)
    if not state:
        state = {"schemaVersion": "1.1.0", "dataset": {}}
    embedding = build_summary(embedding_dir)
    state = apply_embedding(state, embedding)
    write_json(loop_state_path, state)

    if visual_summary_path is not None:
        visual_summary = read_json(visual_summary_path)
        if visual_summary:
            write_json(visual_summary_path, apply_embedding(visual_summary, embedding))
    return state


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--loop-state", type=Path, default=Path("generated/agent_improvement_loop/loop_state.json"))
    parser.add_argument("--embedding-dir", type=Path, default=Path("generated/agent_manifest/embedding"))
    parser.add_argument("--visual-summary", type=Path, default=Path("generated/visual_improve_loop/visual_improve_loop_summary.json"))
    parser.add_argument("--no-visual-summary", action="store_true")
    parser.add_argument("--print-summary", action="store_true")
    args = parser.parse_args(argv)
    visual_summary = None if args.no_visual_summary else args.visual_summary
    state = augment(args.loop_state, args.embedding_dir, visual_summary)
    if args.print_summary:
        print(json.dumps(state["embedding"], ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

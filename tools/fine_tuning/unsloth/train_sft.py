from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REQUIRED_CONFIG_KEYS = {
    "agent",
    "base_model_name",
    "max_seq_length",
    "load_in_4bit",
    "lora_r",
    "lora_alpha",
    "lora_dropout",
    "learning_rate",
    "batch_size",
    "gradient_accumulation_steps",
    "num_train_epochs",
    "warmup_steps",
    "output_dir",
    "dataset_dir",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train per-agent SFT adapters with Unsloth.")
    parser.add_argument("--config", required=True, help="Path to agent Unsloth JSON config.")
    return parser.parse_args()


def load_config(path: Path) -> dict[str, Any]:
    cfg = json.loads(path.read_text(encoding="utf-8"))
    missing = [key for key in sorted(REQUIRED_CONFIG_KEYS) if key not in cfg]
    if missing:
        raise ValueError(f"Config is missing required keys: {', '.join(missing)}")
    return cfg


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


def render_messages(tokenizer: Any, messages: list[dict[str, str]]) -> str:
    if hasattr(tokenizer, "apply_chat_template"):
        return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
    return "\n".join(f"{m.get('role', 'user')}: {m.get('content', '')}" for m in messages)


def main() -> None:
    args = parse_args()
    cfg_path = Path(args.config).resolve()
    cfg = load_config(cfg_path)

    dataset_dir = Path(cfg["dataset_dir"]).resolve()
    train_path = dataset_dir / "train_sft.jsonl"
    val_path = dataset_dir / "val_sft.jsonl"
    if not train_path.exists() or not val_path.exists():
        raise FileNotFoundError(f"Expected {train_path} and {val_path}")

    try:
        from datasets import Dataset
        from transformers import TrainingArguments
        from trl import SFTTrainer
        from unsloth import FastLanguageModel
    except ImportError as exc:
        raise RuntimeError(
            "Missing dependencies for Unsloth SFT training. Install: unsloth, trl, datasets, transformers, peft, accelerate, bitsandbytes."
        ) from exc

    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=cfg["base_model_name"],
        max_seq_length=int(cfg["max_seq_length"]),
        load_in_4bit=bool(cfg["load_in_4bit"]),
    )
    model = FastLanguageModel.get_peft_model(
        model,
        r=int(cfg["lora_r"]),
        lora_alpha=int(cfg["lora_alpha"]),
        lora_dropout=float(cfg["lora_dropout"]),
        bias="none",
        target_modules=cfg.get(
            "target_modules",
            ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
        ),
        use_gradient_checkpointing="unsloth" if cfg.get("gradient_checkpointing", True) else False,
    )

    train_records = load_jsonl(train_path)
    val_records = load_jsonl(val_path)
    train_rows = [{"text": render_messages(tokenizer, row["messages"])} for row in train_records]
    val_rows = [{"text": render_messages(tokenizer, row["messages"])} for row in val_records]

    train_dataset = Dataset.from_list(train_rows)
    eval_dataset = Dataset.from_list(val_rows) if val_rows else None

    output_dir = Path(cfg["output_dir"]).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    training_args = TrainingArguments(
        output_dir=str(output_dir),
        per_device_train_batch_size=int(cfg["batch_size"]),
        per_device_eval_batch_size=max(1, int(cfg["batch_size"])),
        gradient_accumulation_steps=int(cfg["gradient_accumulation_steps"]),
        learning_rate=float(cfg["learning_rate"]),
        num_train_epochs=float(cfg["num_train_epochs"]),
        warmup_steps=int(cfg["warmup_steps"]),
        logging_steps=int(cfg.get("logging_steps", 10)),
        eval_strategy="steps" if eval_dataset is not None else "no",
        eval_steps=int(cfg.get("eval_steps", 50)),
        save_steps=int(cfg.get("save_steps", 100)),
        save_total_limit=int(cfg.get("save_total_limit", 2)),
        bf16=bool(cfg.get("bf16", False)),
        fp16=bool(cfg.get("fp16", True)),
        report_to=[],
    )

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        dataset_text_field="text",
        max_seq_length=int(cfg["max_seq_length"]),
        packing=bool(cfg.get("packing", False)),
        args=training_args,
    )

    train_result = trainer.train()
    trainer.model.save_pretrained(str(output_dir))
    tokenizer.save_pretrained(str(output_dir))

    report = {
        "agent": cfg["agent"],
        "base_model_name": cfg["base_model_name"],
        "dataset_dir": str(dataset_dir),
        "train_records": len(train_rows),
        "val_records": len(val_rows),
        "max_seq_length": cfg["max_seq_length"],
        "load_in_4bit": cfg["load_in_4bit"],
        "packing": bool(cfg.get("packing", False)),
        "gradient_checkpointing": bool(cfg.get("gradient_checkpointing", True)),
        "output_dir": str(output_dir),
        "metrics": train_result.metrics,
    }
    (output_dir / "training_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate merge inputs and scaffold LoRA merge run metadata")
    parser.add_argument("--config", required=True, help="Path to per-agent Unsloth config JSON")
    args = parser.parse_args()

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    required_keys = ("agent", "base_model_name", "output_dir")
    missing = [key for key in required_keys if not cfg.get(key)]
    if missing:
        raise ValueError(f"Missing required config fields for merge: {', '.join(missing)}")

    output_dir = Path(cfg["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)

    report = {
        "agent": cfg["agent"],
        "base_model_name": cfg["base_model_name"],
        "output_dir": str(output_dir),
        "status": "ready_for_merge",
        "next_step": "Run PEFT merge_and_unload() with adapter checkpoint after training",
    }
    (output_dir / "merge_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"prepared merge scaffolding for {cfg['agent']} -> {output_dir}")


if __name__ == "__main__":
    main()

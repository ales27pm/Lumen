from pathlib import Path
import json
from lumen_manifest_crawler.crawler import generate_manifest
from lumen_manifest_crawler.dataset import generate_all_datasets
from lumen_manifest_crawler.dataset.fine_tuning import compile_agent_fine_tuning_datasets


def test_agent_fine_tuning_structure():
    manifest = generate_manifest(Path('.').resolve())
    datasets = generate_all_datasets(manifest)
    compiled = compile_agent_fine_tuning_datasets(manifest, datasets)
    for agent in ["cortex", "executor", "mouth", "mimicry", "rem", "fleet"]:
        ds = compiled[agent]
        assert isinstance(ds.train_sft, list)
        assert isinstance(ds.val_sft, list)
        assert isinstance(ds.eval, list)
        assert "agent" in ds.unsloth_config
        for rec in ds.train_sft[:3]:
            assert len(rec["messages"]) == 3
            assert rec["messages"][0]["role"] == "system"
        for rec in ds.train_dpo[:3]:
            assert "prompt" in rec and "chosen" in rec and "rejected" in rec
            assert rec["chosen"]["content"] != rec["rejected"]["content"]
        json.dumps(ds.dataset_card)

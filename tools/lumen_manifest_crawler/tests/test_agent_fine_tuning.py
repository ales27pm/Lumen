from __future__ import annotations

import json
from pathlib import Path

import pytest

from lumen_manifest_crawler.crawler import generate_manifest
from lumen_manifest_crawler.dataset import generate_all_datasets
from lumen_manifest_crawler.dataset.fine_tuning import AGENTS, compile_agent_fine_tuning_datasets
from lumen_manifest_crawler.output.writer import write_outputs
from lumen_manifest_crawler.validators import validate_agent_fine_tuning_datasets, validate_manifest


@pytest.fixture(scope="module")
def compiled_fine_tuning() -> tuple:
    repo_root = Path(__file__).resolve().parents[3]
    manifest = generate_manifest(repo_root)
    datasets = generate_all_datasets(manifest)
    fine_tuning = compile_agent_fine_tuning_datasets(manifest, datasets)
    return manifest, datasets, fine_tuning


def test_per_agent_directories_are_produced(tmp_path: Path, compiled_fine_tuning: tuple) -> None:
    manifest, datasets, fine_tuning = compiled_fine_tuning
    report = validate_manifest(manifest, datasets)
    output = tmp_path / "agent_manifest"
    fine_tuning_output = tmp_path / "fine_tuning"

    write_outputs(
        output,
        manifest,
        report,
        datasets,
        pretty=True,
        fine_tuning_datasets=fine_tuning,
        fine_tuning_output_dir=fine_tuning_output,
    )

    for agent in AGENTS:
        agent_dir = fine_tuning_output / agent
        assert agent_dir.exists()
        for filename in (
            "train_sft.jsonl",
            "val_sft.jsonl",
            "eval.jsonl",
            "dataset_card.json",
            "unsloth_config.json",
        ):
            assert (agent_dir / filename).exists(), f"missing {agent}/{filename}"


def test_sft_records_use_chat_format(compiled_fine_tuning: tuple) -> None:
    _, _, fine_tuning = compiled_fine_tuning
    for agent in AGENTS:
        for record in (fine_tuning[agent].train_sft + fine_tuning[agent].val_sft)[:20]:
            messages = record["messages"]
            assert len(messages) == 3
            assert messages[0]["role"] == "system"
            assert messages[1]["role"] == "user"
            assert messages[2]["role"] == "assistant"
            assert isinstance(messages[2]["content"], str)
            assert messages[2]["content"].strip()


def test_dpo_records_have_prompt_chosen_rejected(compiled_fine_tuning: tuple) -> None:
    _, _, fine_tuning = compiled_fine_tuning
    for agent in AGENTS:
        for record in (fine_tuning[agent].train_dpo + fine_tuning[agent].val_dpo)[:20]:
            assert isinstance(record["prompt"], list)
            assert record["prompt"][0]["role"] == "system"
            assert record["prompt"][1]["role"] == "user"
            assert record["chosen"]["role"] == "assistant"
            assert record["rejected"]["role"] == "assistant"
            assert record["chosen"]["content"] != record["rejected"]["content"]


def test_no_unknown_agent_roles_unknown_tools_or_sentinel_leaks(compiled_fine_tuning: tuple) -> None:
    manifest, _, fine_tuning = compiled_fine_tuning
    failures = validate_agent_fine_tuning_datasets(manifest, fine_tuning)
    blocked = {
        "unknown_agent_role",
        "unknown_tool_id",
        "sentinel_leak",
        "dpo_chosen_equals_rejected",
        "eval_missing_expected",
        "missing_required_args_executor_examples",
    }
    failing_codes = {failure.code for failure in failures}
    assert blocked.isdisjoint(failing_codes), failures


def test_executor_has_tool_coverage(compiled_fine_tuning: tuple) -> None:
    manifest, _, fine_tuning = compiled_fine_tuning
    expected_tools = {tool.id for tool in manifest.tools}
    covered_tools: set[str] = set()
    for record in fine_tuning["executor"].train_sft + fine_tuning["executor"].val_sft:
        covered_tools.update(record["metadata"]["toolIDs"])
    assert expected_tools.issubset(covered_tools)


def test_fleet_has_model_slot_coverage(compiled_fine_tuning: tuple) -> None:
    manifest, _, fine_tuning = compiled_fine_tuning
    blob = "\n".join(json.dumps(record, ensure_ascii=False, sort_keys=True) for record in (fine_tuning["fleet"].train_sft + fine_tuning["fleet"].val_sft))
    for slot in manifest.fleet.slots:
        assert slot.id in blob


def test_unsloth_configs_include_required_keys(compiled_fine_tuning: tuple) -> None:
    required = {
        "agent",
        "base_model_name",
        "max_seq_length",
        "load_in_4bit",
        "lora_r",
        "lora_alpha",
        "learning_rate",
        "dataset_dir",
        "output_dir",
    }
    _, _, fine_tuning = compiled_fine_tuning
    for agent in AGENTS:
        config = fine_tuning[agent].unsloth_config
        assert required.issubset(config.keys()), f"{agent} missing keys"

    config_dir = Path("tools/fine_tuning/unsloth/configs")
    for path in config_dir.glob("*.json"):
        cfg = json.loads(path.read_text(encoding="utf-8"))
        assert required.issubset(cfg.keys()), f"{path} missing required keys"


def test_unsloth_output_dirs_include_agent_and_finetune_marker(compiled_fine_tuning: tuple) -> None:
    markers = {"sft", "dpo", "orpo", "lora", "merged", "adapter", "finetune", "finetuned"}
    _, _, fine_tuning = compiled_fine_tuning

    for agent in AGENTS:
        output_dir = str(fine_tuning[agent].unsloth_config["output_dir"])
        tokens = set("".join(ch.lower() if ch.isalnum() else " " for ch in output_dir).split())
        assert agent in tokens, f"{agent} output_dir missing slot token: {output_dir}"
        assert markers.intersection(tokens), f"{agent} output_dir missing finetune marker: {output_dir}"

    config_dir = Path("tools/fine_tuning/unsloth/configs")
    for path in config_dir.glob("*.json"):
        cfg = json.loads(path.read_text(encoding="utf-8"))
        agent = str(cfg["agent"]).lower()
        output_dir = str(cfg["output_dir"])
        tokens = set("".join(ch.lower() if ch.isalnum() else " " for ch in output_dir).split())
        assert agent in tokens, f"{path} output_dir missing slot token: {output_dir}"
        assert markers.intersection(tokens), f"{path} output_dir missing finetune marker: {output_dir}"

from __future__ import annotations

import logging
import subprocess
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console

from lumen_manifest_crawler.crawler import generate_manifest
from lumen_manifest_crawler.dataset import generate_all_datasets
from lumen_manifest_crawler.fleet_artifacts import generate_fleet_artifacts, generate_manifest_markdown
from lumen_manifest_crawler.output.writer import write_outputs
from lumen_manifest_crawler.validators import validate_manifest

logger = logging.getLogger(__name__)

app = typer.Typer(no_args_is_help=True)
generate_app = typer.Typer(help="Generate AgentBehaviorManifest.json and grounded datasets.", invoke_without_command=True)
app.add_typer(generate_app, name="generate")
console = Console()


@generate_app.callback()
def generate(
    root: Path = typer.Option(Path("."), "--root", help="Repository root to scan."),
    output: Path = typer.Option(Path("generated/agent_manifest"), "--output", help="Output directory."),
    pretty: bool = typer.Option(False, "--pretty", help="Also write pretty formatted manifest."),
    runtime_audit: Annotated[list[Path] | None, typer.Option("--runtime-audit", help="RuntimeManifestAuditor JSON report file or directory. Can be passed multiple times.")] = None,
    deterministic: bool = typer.Option(True, "--deterministic/--non-deterministic", help="Use deterministic timestamps and splits for CI-stable generated files."),
    generate_system_prompts: bool = typer.Option(False, "--generate-system-prompts", help="Generate fleet_system_prompts.json, AgentBehaviorManifest.md, and cross-model training artifacts."),
    export_md: bool = typer.Option(False, "--export-md", help="Generate only AgentBehaviorManifest.md, unless full fleet artifact generation is also requested."),
    cross_model_train_dir: Path | None = typer.Option(None, "--cross-model-train-dir", help="Directory for cross_model_training.jsonl. Defaults to <output>/cross_model_training."),
    fail_on_change: bool = typer.Option(False, "--fail-on-change", help="Exit non-zero if generated outputs leave tracked or untracked git changes."),
    fail_on_validation: bool = typer.Option(True, "--fail-on-validation/--no-fail-on-validation", help="Exit non-zero on hard validation failures."),
) -> None:
    """Generate AgentBehaviorManifest.json and state-of-the-art grounded datasets."""
    manifest = generate_manifest(root)
    datasets = generate_all_datasets(manifest, runtime_audit_paths=runtime_audit, deterministic=deterministic)
    report = validate_manifest(manifest, datasets)
    should_generate_full_fleet_artifacts = generate_system_prompts or cross_model_train_dir is not None
    fleet_artifacts = generate_fleet_artifacts(manifest) if should_generate_full_fleet_artifacts else None
    manifest_markdown = None if fleet_artifacts else (generate_manifest_markdown(manifest) if export_md else None)
    write_outputs(
        output,
        manifest,
        report,
        datasets,
        pretty=pretty,
        fleet_artifacts=fleet_artifacts,
        manifest_markdown=manifest_markdown,
        cross_model_train_dir=cross_model_train_dir,
    )

    compiled_count = sum(len(records) for name, records in datasets.items() if name != "dataset_manifest")
    families_count = sum(1 for name in datasets if name != "dataset_manifest")
    console.print(f"[bold]Tools:[/bold] {len(manifest.tools)}")
    console.print(f"[bold]Intents:[/bold] {len(manifest.intents)}")
    console.print(f"[bold]Model slots:[/bold] {len(manifest.fleet.slots)}")
    console.print(f"[bold]Datasets:[/bold] {compiled_count} records across {families_count} families")
    if fleet_artifacts:
        console.print(f"[bold]Fleet self-knowledge:[/bold] {len(fleet_artifacts.system_prompts)} prompts and {len(fleet_artifacts.cross_model_training)} cross-model records")
    elif manifest_markdown:
        console.print("[bold]Fleet markdown:[/bold] wrote AgentBehaviorManifest.md")
    if runtime_audit:
        console.print(f"[bold]Runtime audit inputs:[/bold] {len(runtime_audit)} path(s)")
    if report.failures:
        console.print(f"[red]Validation failed with {len(report.failures)} hard failure(s).[/red]")
        for failure in report.failures:
            console.print(f"  [red]- {failure.code}:[/red] {failure.message}")
        if fail_on_validation:
            raise typer.Exit(code=1)
    if report.warnings:
        console.print(f"[yellow]Warnings:[/yellow] {len(report.warnings)}")
        for warning in report.warnings[:20]:
            console.print(f"  [yellow]- {warning.code}:[/yellow] {warning.message}")
    if fail_on_change and _has_git_changes(root):
        console.print("[red]Generated outputs differ from the git working tree, or git status could not be verified. Commit regenerated artifacts or fix the git status check.[/red]")
        raise typer.Exit(code=1)
    console.print(f"[green]Wrote manifest and dataset outputs to {output}[/green]")


def _has_git_changes(root: Path) -> bool:
    try:
        completed = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return bool(completed.stdout.strip())
    except Exception as e:
        logger.exception("Failed to verify git working tree changes with `git status --porcelain`: %s", e)
        console.print(f"[red]Failed to verify git working tree changes: {e}[/red]")
        return True


if __name__ == "__main__":
    app()

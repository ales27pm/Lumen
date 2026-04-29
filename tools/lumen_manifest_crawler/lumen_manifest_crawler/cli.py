from __future__ import annotations

from pathlib import Path

import typer
from rich.console import Console

from lumen_manifest_crawler.crawler import generate_manifest
from lumen_manifest_crawler.dataset import generate_all_datasets
from lumen_manifest_crawler.output.writer import write_outputs
from lumen_manifest_crawler.validators import validate_manifest

app = typer.Typer(no_args_is_help=True)
generate_app = typer.Typer(help="Generate AgentBehaviorManifest.json and grounded datasets.", invoke_without_command=True)
app.add_typer(generate_app, name="generate")
console = Console()


@generate_app.callback()
def generate(
    root: Path = typer.Option(Path("."), "--root", help="Repository root to scan."),
    output: Path = typer.Option(Path("generated/agent_manifest"), "--output", help="Output directory."),
    pretty: bool = typer.Option(False, "--pretty", help="Also write pretty formatted manifest."),
    fail_on_validation: bool = typer.Option(True, "--fail-on-validation/--no-fail-on-validation", help="Exit non-zero on hard validation failures."),
) -> None:
    """Generate AgentBehaviorManifest.json and grounded datasets."""
    manifest = generate_manifest(root)
    datasets = generate_all_datasets(manifest)
    report = validate_manifest(manifest, datasets)
    write_outputs(output, manifest, report, datasets, pretty=pretty)

    console.print(f"[bold]Tools:[/bold] {len(manifest.tools)}")
    console.print(f"[bold]Intents:[/bold] {len(manifest.intents)}")
    console.print(f"[bold]Model slots:[/bold] {len(manifest.fleet.slots)}")
    console.print(f"[bold]Datasets:[/bold] {sum(len(v) for v in datasets.values())} records")
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
    console.print(f"[green]Wrote manifest outputs to {output}[/green]")


if __name__ == "__main__":
    app()

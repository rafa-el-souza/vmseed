"""The command line: parse, call an operation, map errors to exit codes.

It stays thin (docs/spec/01-architecture.md). For now it only answers
``--version``; the commands of docs/spec/05-lifecycle.md arrive with the
milestones that implement them.
"""

from typing import Annotated

import typer

from vmseed import __version__

app = typer.Typer(
    name="vmseed",
    help="Provision hardened local VMs from verified cloud images, and prove it.",
    add_completion=False,
    no_args_is_help=True,
    # Help text is plain text: nothing reaches rich as markup.
    rich_markup_mode=None,
    # A traceback must never print local variables: they may hold paths and
    # guest output.
    pretty_exceptions_show_locals=False,
)


def _print_version(value: bool) -> None:
    if value:
        typer.echo(f"vmseed {__version__}")
        raise typer.Exit


@app.callback()
def _root(
    version: Annotated[
        bool,
        typer.Option(
            "--version",
            help="Print the version and exit.",
            callback=_print_version,
            is_eager=True,
        ),
    ] = False,
) -> None:
    """Provision hardened local VMs from verified cloud images, and prove it."""


def main() -> None:
    """Run the command line; the console script ``vmseed`` points here."""
    app()

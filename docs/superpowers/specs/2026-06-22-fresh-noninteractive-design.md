# Fresh Noninteractive Execution Design

## Goal

Make every `fresh.sh` run automatically accept supported installer confirmations without requiring a command-line flag.

## Design

At script startup, export `NONINTERACTIVE=1` so the setting is inherited by every subprocess. This uses Homebrew's supported noninteractive interface and also applies automatically to future subprocesses that honor the conventional variable.

Keep command-specific noninteractive flags where they already exist, including Rustup's `-y`. Do not pipe `yes` into the script because doing so could answer password or other unexpected input prompts incorrectly.

The command-line interface remains unchanged: normal runs, maintenance runs, and sourced test fixtures all enable noninteractive mode by default.

## Error Handling

Noninteractive commands retain their existing exit-status handling. A command that cannot proceed without user input must fail and be reported through the existing setup or maintenance failure path rather than hang waiting for input.

## Verification

Add a regression test that clears `NONINTERACTIVE`, sources `fresh.sh`, and verifies the script exports `NONINTERACTIVE=1` to a child shell. Run the full shell test suite and ShellCheck after implementation.

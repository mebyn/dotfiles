#!/usr/bin/env bash
set -euo pipefail

# Generate AGENTS.md from local Homebrew installation (inventory only)

if ! command -v brew >/dev/null 2>&1; then
  echo "Error: Homebrew (brew) is not installed or not in PATH" >&2
  exit 1
fi

BREW_VERSION=$(brew --version | head -n1 | awk '{print $2}')

# Output directory for agents reference
CODEX_DIR="${HOME}/.codex"
mkdir -p "$CODEX_DIR"

# Collect lists (sorted) and counts
FORMULA_LIST=$(brew list --formula | sort || true)
CASK_LIST=$(brew list --cask 2>/dev/null | sort || true)

FORMULA_COUNT=$(printf "%s\n" "$FORMULA_LIST" | sed '/^$/d' | wc -l | tr -d ' ')
CASK_COUNT=$(printf "%s\n" "$CASK_LIST" | sed '/^$/d' | wc -l | tr -d ' ')

# Write directly to ~/.codex/AGENTS.md
OUT_FILE="${CODEX_DIR}/AGENTS.md"

# Header and overview (with variable expansion, no backticks)
cat > "$OUT_FILE" <<EOF
# Agents Capabilities Reference (Homebrew)

This document summarizes the tools available on this machine via Homebrew and highlights what agents can leverage. It is generated from the current Homebrew installation and is intended as a quick capability map and usage reference.

## Overview

- Homebrew: ${BREW_VERSION}
- Installed formulae: ${FORMULA_COUNT}
- Installed casks: ${CASK_COUNT}

## Preferences

- Prefer Rust-powered tools when running commands, when reasonable.
EOF

# Static sections with backticks (no expansion)
cat >> "$OUT_FILE" <<'EOF'

## Full Inventory
EOF

# Inventory headings (with variable expansion)
{
  echo
  echo "### Formulae (${FORMULA_COUNT})"
  echo
  echo '```'
} >> "$OUT_FILE"

# Append formula list and close code block
{
  printf "%s\n" "$FORMULA_LIST"
  echo '```'
} >> "$OUT_FILE"

{
  echo
  echo "### Casks (${CASK_COUNT})"
  echo
  echo '```'
} >> "$OUT_FILE"

# Append cask list and close code block
{
  printf "%s\n" "$CASK_LIST"
  echo '```'
} >> "$OUT_FILE"

cat >> "$OUT_FILE" <<'EOF'

## Maintenance

- Refresh this document after brew changes:
  - Update: `brew update && brew upgrade`
  - List: `brew list --formula | sort` and `brew list --cask | sort`
  - Edit: append new tools and adjust capabilities as needed.

EOF

echo "Wrote ${OUT_FILE} from Homebrew inventory (formulae=${FORMULA_COUNT}, casks=${CASK_COUNT})."

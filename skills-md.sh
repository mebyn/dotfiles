#!/usr/bin/env bash
set -euo pipefail

# Generate Homebrew inventory skill from local Homebrew installation

if ! command -v brew >/dev/null 2>&1; then
  echo "Error: Homebrew (brew) is not installed or not in PATH" >&2
  exit 1
fi

# Output directory for skills reference
CODEX_DIR="${HOME}/.codex"
SKILL_DIR="${CODEX_DIR}/skills/homebrew-inventory"
REF_DIR="${SKILL_DIR}/references"
SKILL_FILE="${SKILL_DIR}/SKILL.md"
REF_FILE="${REF_DIR}/brew-tools.md"

mkdir -p "$REF_DIR"

FORMULA_LIST=$(brew list --formula | sort || true)
CASK_LIST=$(brew list --cask 2>/dev/null | sort || true)

FORMULA_COUNT=$(printf "%s\n" "$FORMULA_LIST" | sed '/^$/d' | wc -l | tr -d ' ')
CASK_COUNT=$(printf "%s\n" "$CASK_LIST" | sed '/^$/d' | wc -l | tr -d ' ')

if ! command -v jq >/dev/null 2>&1; then
  echo "Warning: jq not found; emitting name-only inventory." >&2
  FORMULA_SKILLS=$(printf "%s\n" "$FORMULA_LIST" | sed '/^$/d' | sort)
  CASK_SKILLS=$(printf "%s\n" "$CASK_LIST" | sed '/^$/d' | sort)
else
  FORMULA_JSON=""
  if [[ -n "${FORMULA_LIST:-}" ]]; then
    FORMULA_JSON=$(brew info --json=v2 --formula $FORMULA_LIST 2>/dev/null || true)
  fi

  CASK_JSON=""
  if [[ -n "${CASK_LIST:-}" ]]; then
    CASK_JSON=$(brew info --json=v2 --cask $CASK_LIST 2>/dev/null || true)
  fi

  FORMULA_SKILLS=$(printf "%s" "$FORMULA_JSON" | jq -r '
    .formulae[]? |
    select(any(.installed[]?; .installed_on_request == true)) |
    [.name, (.desc // "")] | @tsv
  ' | LC_ALL=C sort)

  CASK_SKILLS=$(printf "%s" "$CASK_JSON" | jq -r '
    .casks[]? |
    [.token, (.desc // "")] | @tsv
  ' | LC_ALL=C sort)
fi

cat > "$SKILL_FILE" <<'EOF'
---
name: homebrew-inventory
description: Lookup installed Homebrew formulae and casks with descriptions; use to check available CLI tools and apps on this machine.
---

# Homebrew Inventory

See references/brew-tools.md for the current list.
EOF

cat > "$REF_FILE" <<EOF
# Homebrew Tools Inventory

This inventory is auto-generated from Homebrew metadata.
It includes explicitly installed formulae (installed_on_request) and all casks.

## Formulae (${FORMULA_COUNT})
EOF

if [[ -z "${FORMULA_SKILLS:-}" ]]; then
  echo >> "$REF_FILE"
  echo "_None detected._" >> "$REF_FILE"
else
  while IFS=$'\t' read -r name desc; do
    if [[ -n "$desc" ]]; then
      echo "- ${name}: ${desc}" >> "$REF_FILE"
    else
      echo "- ${name}" >> "$REF_FILE"
    fi
  done <<< "$FORMULA_SKILLS"
fi

cat >> "$REF_FILE" <<EOF

## Casks (${CASK_COUNT})
EOF

if [[ -z "${CASK_SKILLS:-}" ]]; then
  echo >> "$REF_FILE"
  echo "_None detected._" >> "$REF_FILE"
else
  while IFS=$'\t' read -r name desc; do
    if [[ -n "$desc" ]]; then
      echo "- ${name}: ${desc}" >> "$REF_FILE"
    else
      echo "- ${name}" >> "$REF_FILE"
    fi
  done <<< "$CASK_SKILLS"
fi

echo "Wrote ${SKILL_FILE} and ${REF_FILE} from Homebrew inventory."

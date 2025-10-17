#!/bin/bash

set -Eeuo pipefail

# Global variables
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCREENSHOT_DIR="$HOME/Documents/Screenshots"
readonly BREWFILE="$DOTFILES_DIR/.Brewfile"
RUSTUP_INSTALLED=""
REMOVED_PACKAGES=""
BREW_SUMMARY_TABLE=""
DOTFILES_LINKED=0
CONFIG_FILES_LINKED=0

# Temp files for Homebrew state snapshots
BEFORE_FORMULAS_FILE=""
BEFORE_CASKS_FILE=""
AFTER_FORMULAS_FILE=""
AFTER_CASKS_FILE=""

# Cleanup function
cleanup() {
    local rc="${1:-0}"
    if [ "$rc" -ne 0 ]; then
        echo "❌ Error occurred during setup"
    fi
    # Remove temp snapshot files if they exist
    [ -n "${BEFORE_FORMULAS_FILE:-}" ] && rm -f "$BEFORE_FORMULAS_FILE" || true
    [ -n "${BEFORE_CASKS_FILE:-}" ] && rm -f "$BEFORE_CASKS_FILE" || true
    [ -n "${AFTER_FORMULAS_FILE:-}" ] && rm -f "$AFTER_FORMULAS_FILE" || true
    [ -n "${AFTER_CASKS_FILE:-}" ] && rm -f "$AFTER_CASKS_FILE" || true
}

# Generate Agents capabilities document and place it under ~/.codex
generate_agents_reference() {
    echo "🧭 Generating agents capabilities reference..."
    local codex_dir="$HOME/.codex"
    mkdir -p "$codex_dir"

    if bash "$DOTFILES_DIR/agents-md.sh"; then
        echo "🤖 Wrote $codex_dir/AGENTS.md"
    else
        echo "⚠️ Failed to generate AGENTS.md via agents-md.sh"
    fi
}

trap 'rc=$?; cleanup "$rc"; exit "$rc"' EXIT


upgrade_brew_packages() {
    echo "🔄 Updating Homebrew..."
    brew update || { echo "❌ Failed to update Homebrew"; return 1; }
    
    echo "⬆️  Upgrading outdated packages..."
    brew upgrade || true
    
    echo "🔍 Upgrading casks..."
    brew upgrade --cask --greedy || true
    
    # Check for outdated casks that need manual intervention
    local outdated_casks
    outdated_casks=$(brew outdated --cask --greedy --verbose)
    if [ -n "$outdated_casks" ]; then
        echo "📝 Some casks need manual upgrade:"
        echo "$outdated_casks"
    fi
}

# Capture current Homebrew state (name + version) for formulas and casks
capture_brew_state() {
    local stage="$1" # before | after

    # If brew is not available yet, skip capture
    if ! command -v brew >/dev/null 2>&1; then
        return 0
    fi

    if [ "$stage" = "before" ]; then
        BEFORE_FORMULAS_FILE=$(mktemp)
        BEFORE_CASKS_FILE=$(mktemp)
        brew list --versions 2>/dev/null | awk '{print $1, $NF}' | LC_ALL=C sort > "$BEFORE_FORMULAS_FILE" || true
        brew list --cask --versions 2>/dev/null | awk '{print $1, $NF}' | LC_ALL=C sort > "$BEFORE_CASKS_FILE" || true
    else
        AFTER_FORMULAS_FILE=$(mktemp)
        AFTER_CASKS_FILE=$(mktemp)
        brew list --versions 2>/dev/null | awk '{print $1, $NF}' | LC_ALL=C sort > "$AFTER_FORMULAS_FILE" || true
        brew list --cask --versions 2>/dev/null | awk '{print $1, $NF}' | LC_ALL=C sort > "$AFTER_CASKS_FILE" || true
    fi
}

# Generate a tabular summary of Homebrew changes between two snapshots
generate_brew_summary_table() {
    local before_formulas="$1"
    local before_casks="$2"
    local after_formulas="$3"
    local after_casks="$4"

    # If any snapshot file is missing, bail out gracefully
    if [ ! -f "$before_formulas" ] || [ ! -f "$before_casks" ] || \
       [ ! -f "$after_formulas" ]  || [ ! -f "$after_casks" ]; then
        return 0
    fi

    local installed_formula_names removed_formula_names installed_cask_names removed_cask_names
    local installed_formulas removed_formulas installed_casks removed_casks updated_formulas updated_casks

    # Compute updates by name (present in both, version changed)
    updated_formulas=$(LC_ALL=C join -j 1 "$before_formulas" "$after_formulas" 2>/dev/null | awk '$2 != $3 {print $1, $2, $3}')
    updated_casks=$(LC_ALL=C join -j 1 "$before_casks" "$after_casks" 2>/dev/null | awk '$2 != $3 {print $1, $2, $3}')

    # Names only lists
    local bf_names af_names bc_names ac_names
    bf_names=$(mktemp); af_names=$(mktemp); bc_names=$(mktemp); ac_names=$(mktemp)
    awk '{print $1}' "$before_formulas" | LC_ALL=C sort > "$bf_names"
    awk '{print $1}' "$after_formulas" | LC_ALL=C sort > "$af_names"
    awk '{print $1}' "$before_casks" | LC_ALL=C sort > "$bc_names"
    awk '{print $1}' "$after_casks" | LC_ALL=C sort > "$ac_names"

    # Installed/Removed by comparing names
    installed_formula_names=$(LC_ALL=C comm -13 "$bf_names" "$af_names" || true)
    removed_formula_names=$(LC_ALL=C comm -23 "$bf_names" "$af_names" || true)
    installed_cask_names=$(LC_ALL=C comm -13 "$bc_names" "$ac_names" || true)
    removed_cask_names=$(LC_ALL=C comm -23 "$bc_names" "$ac_names" || true)

    # Map installed/removed names back to name+version rows
    installed_formulas=$(if [ -n "$installed_formula_names" ]; then echo "$installed_formula_names" | LC_ALL=C join -j 1 - "$after_formulas"; fi)
    removed_formulas=$(if [ -n "$removed_formula_names" ]; then echo "$removed_formula_names" | LC_ALL=C join -j 1 - "$before_formulas"; fi)
    installed_casks=$(if [ -n "$installed_cask_names" ]; then echo "$installed_cask_names" | LC_ALL=C join -j 1 - "$after_casks"; fi)
    removed_casks=$(if [ -n "$removed_cask_names" ]; then echo "$removed_cask_names" | LC_ALL=C join -j 1 - "$before_casks"; fi)

    local have_changes=""
    if [ -n "$installed_formulas$installed_casks$removed_formulas$removed_casks$updated_formulas$updated_casks" ]; then
        have_changes="yes"
    fi

    if [ -z "$have_changes" ]; then
        echo "No Homebrew changes detected."
        return 0
    fi

    printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "Action" "Type" "Name" "From" "To"
    printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "---------" "--------" "--------------------------------" "------------------" "------------------"

    # Installed
    if [ -n "$installed_formulas" ]; then
        while read -r name ver; do
            [ -n "$name" ] || continue
            printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "Installed" "Formula" "$name" "-" "$ver"
        done <<< "$installed_formulas"
    fi
    if [ -n "$installed_casks" ]; then
        while read -r name ver; do
            [ -n "$name" ] || continue
            printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "Installed" "Cask" "$name" "-" "$ver"
        done <<< "$installed_casks"
    fi

    # Updated
    if [ -n "$updated_formulas" ]; then
        while read -r name from to; do
            [ -n "$name" ] || continue
            printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "Updated" "Formula" "$name" "$from" "$to"
        done <<< "$updated_formulas"
    fi
    if [ -n "$updated_casks" ]; then
        while read -r name from to; do
            [ -n "$name" ] || continue
            printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "Updated" "Cask" "$name" "$from" "$to"
        done <<< "$updated_casks"
    fi

    # Removed
    if [ -n "$removed_formulas" ]; then
        while read -r name ver; do
            [ -n "$name" ] || continue
            printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "Removed" "Formula" "$name" "$ver" "-"
        done <<< "$removed_formulas"
    fi
    if [ -n "$removed_casks" ]; then
        while read -r name ver; do
            [ -n "$name" ] || continue
            printf "%-9s  %-8s  %-32s  %-18s  %-18s\n" "Removed" "Cask" "$name" "$ver" "-"
        done <<< "$removed_casks"
    fi
}

setup_homebrew() {
    # 🍺 Check if Homebrew is installed
    if ! command -v brew &> /dev/null; then
        echo "🛠️  Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        echo "✅ Homebrew is already installed"
    fi

    echo "🛠️ Adding Homebrew to PATH"
    # Add both common Homebrew locations idempotently
    grep -qF -- 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
    # Evaluate whichever is available
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || brew shellenv 2>/dev/null)"

    # Capture state before any bundle/upgrade/cleanup operations
    capture_brew_state "before"

    echo "📦 Installing brew bundle..."
    brew bundle install --file="$BREWFILE" --verbose || true

    upgrade_brew_packages

    echo "🧹 Performing thorough Homebrew cleanup..."
    REMOVED_PACKAGES=$(brew bundle --force cleanup --file="$BREWFILE" || true)
    # Combine cleanup commands with error checking
    if ! { brew cleanup --prune=all && \
           brew cleanup -s && \
           brew cleanup --prune-prefix; }; then
        echo "⚠️ Warning: Some cleanup operations failed"
    fi

    # Capture state after all operations
    capture_brew_state "after"

    # Build the Homebrew summary table for later printing
    BREW_SUMMARY_TABLE=$(generate_brew_summary_table "$BEFORE_FORMULAS_FILE" "$BEFORE_CASKS_FILE" "$AFTER_FORMULAS_FILE" "$AFTER_CASKS_FILE")
}

create_symlinks() {
    echo "🔗 Linking dotfiles into $HOME (force overwrite)..."
    while IFS= read -r -d '' src; do
        dest="$HOME/$(basename "$src")"
        ln -sfn "$src" "$dest"
        echo "🔁 $dest -> $src"
        DOTFILES_LINKED=$((DOTFILES_LINKED + 1))
    done < <(find "$DOTFILES_DIR" -maxdepth 1 -type f -name '.*' -not -name '.gitignore' -not -name '.Brewfile' -print0)
}

link_config_contents() {
    local src_dir
    src_dir="$DOTFILES_DIR/.config"

    # If there's no .config directory in the repo, nothing to do
    [ -d "$src_dir" ] || return 0

    echo "🔗 Linking .config contents into $HOME/.config (force overwrite, recursive files)..."
    local dest_dir="$HOME/.config"
    mkdir -p "$dest_dir"

    # Recurse and link files, preserving subdirectory structure
    find "$src_dir" -type f -print0 | while IFS= read -r -d '' item; do
        rel_path="${item#"$src_dir/"}"
        target="$dest_dir/$rel_path"
        mkdir -p "$(dirname "$target")"
        # Remove any existing file/dir/symlink at target, then link
        [ -e "$target" ] || [ -L "$target" ] && rm -rf "$target"
        ln -s "$item" "$target"
        echo "🔁 $target -> $item"
        CONFIG_FILES_LINKED=$((CONFIG_FILES_LINKED + 1))
    done
}

setup_bat_theme() {
    local BATCONFIG_DIR
    BATCONFIG_DIR=$(bat --config-dir)
    local theme_file="$BATCONFIG_DIR/themes/Catppuccin Mocha.tmTheme"
    
    if [ ! -f "$theme_file" ]; then
        echo "🎨 Installing bat Catppuccin Mocha theme..."
        mkdir -p "$BATCONFIG_DIR/themes"
        if curl -fsSL "https://github.com/catppuccin/bat/raw/main/themes/Catppuccin%20Mocha.tmTheme" -o "$theme_file"; then
            bat cache --build
            # Ensure config file exists and set theme without clobbering other options
            local bat_config
            bat_config="$(bat --config-file)"
            mkdir -p "$(dirname "$bat_config")"
            touch "$bat_config"
            if ! grep -q '^--theme="Catppuccin Mocha"$' "$bat_config"; then
                echo "--theme=\"Catppuccin Mocha\"" >> "$bat_config"
            fi
        else
            echo "❌ Failed to download bat theme"
            return 1
        fi
    fi
}

check_requirements() {
    local required_commands=("curl" "unzip")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "❌ Required command not found: $cmd"
            exit 1
        fi
    done
}

# Ensure sudo leverages Touch ID / biometrics for CLI usage
enable_cli_biometrics() {
    if ! command -v sudo >/dev/null 2>&1; then
        echo "⚠️ sudo command not available; skipping Touch ID setup"
        return 0
    fi

    local pam_sudo_file="/etc/pam.d/sudo"
    if [ ! -f "$pam_sudo_file" ]; then
        echo "⚠️ $pam_sudo_file not found; skipping Touch ID setup"
        return 0
    fi

    local pam_local_file="/etc/pam.d/sudo_local"
    if [ -f "$pam_local_file" ] && grep -Eq 'pam_(watchid|tid)\.so' "$pam_local_file"; then
        echo "✅ Touch ID already enabled for sudo"
        return 0
    fi

    echo "🔐 Enabling Touch ID authentication for sudo via pam-watchid..."
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mostpinkest/pam-watchid/HEAD/install.sh)" -- enable; then
        echo "✅ Touch ID enabled for sudo"
    else
        echo "❌ Failed to enable Touch ID via pam-watchid"
        return 1
    fi
}

# Ensure Zimfw is installed and fetch modules defined in ~/.zimrc
setup_zimfw() {
    echo "🔧 Ensuring Zimfw and modules..."
    local ZIM_HOME
    ZIM_HOME="${ZDOTDIR:-$HOME}/.zim"
    mkdir -p "$ZIM_HOME"

    # Download zimfw manager if missing
    if [ ! -e "$ZIM_HOME/zimfw.zsh" ]; then
        echo "⬇️  Installing zimfw manager..."
        if ! curl -fsSL --create-dirs -o "$ZIM_HOME/zimfw.zsh" \
            https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh; then
            echo "❌ Failed to download zimfw"
            return 1
        fi
    fi

    # zimfw 1.18.0: install installs new modules and triggers build/compile; update updates modules
     ZIM_HOME="${ZIM_HOME:-$HOME/.zim}" \
        zsh -c 'source "$ZIM_HOME/zimfw.zsh" install -q'
     ZIM_HOME="${ZIM_HOME:-$HOME/.zim}" \
        zsh -c 'source "$ZIM_HOME/zimfw.zsh" update -q'
}

print_summary() {
    echo ""
    echo "🎉 Fresh script summary:"
    echo "---------------------"
    echo "✅ Dotfiles linked: $DOTFILES_LINKED"
    echo "✅ .config files linked: $CONFIG_FILES_LINKED"
    echo "✅ Bat theme configured"
    echo "✅ Screenshot directory set to $SCREENSHOT_DIR"
    if [ -n "$RUSTUP_INSTALLED" ]; then
        echo "✅ Rustup installed"
    fi

    echo ""
    echo "📦 Homebrew changes (this run):"
    if [ -n "$BREW_SUMMARY_TABLE" ]; then
        echo "$BREW_SUMMARY_TABLE"
    else
        echo "No Homebrew changes detected."
    fi
    echo "---------------------"
}

main() {
    # Check if running on macOS
    if [ "$(uname)" != "Darwin" ]; then
        echo "❌ This script is only for macOS"
        exit 1
    fi

    echo "🚀 Setting up your Mac..."

    # Check requirements before running any network-dependent steps
    check_requirements

    # Enable biometrics for sudo if available
    enable_cli_biometrics

    # Setup steps
    create_symlinks
    link_config_contents
    setup_homebrew
    setup_zimfw

    # Setup bat theme
    setup_bat_theme

    # Generate AGENTS.md to ~/.codex for agents to consume
    generate_agents_reference

    # Setup screenshots directory
    echo "📸 Setting screenshot folder to $SCREENSHOT_DIR"
    mkdir -p "$SCREENSHOT_DIR"
    defaults write com.apple.screencapture location "$SCREENSHOT_DIR"
    killall SystemUIServer || true

    # Install rustup if not present (non-interactive)
    if ! command -v rustup &> /dev/null; then
        echo "🦀 Installing Rustup..."
        curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | sh -s -- -y
        RUSTUP_INSTALLED="true"
    fi

    print_summary

    echo "✨ Setup completed successfully! 🎉 Enjoy your fresh and updated Mac! 🚀 "
    echo "💻 Remember to restart your terminal for changes to take effect."
}

main "$@"

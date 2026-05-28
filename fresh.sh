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
OPERATION_MODE="setup"
VERBOSE=0
SHOW_HELP=0
MAINTENANCE_MODE=0
FAILED_STEPS=()
SKIPPED_STEPS=()
STEP_RESULTS=()
STEP_RESULT_STATUS=""
STEP_RESULT_DETAIL=""
readonly LAUNCH_AGENT_LABEL="com.melvin.fresh"
readonly LAUNCH_AGENT_FILENAME="${LAUNCH_AGENT_LABEL}.plist"
readonly LAUNCH_AGENT_SOURCE="$DOTFILES_DIR/launchd/$LAUNCH_AGENT_FILENAME"
readonly LAUNCH_AGENT_TARGET="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_FILENAME"

# Temp files for Homebrew state snapshots
BEFORE_FORMULAS_FILE=""
BEFORE_CASKS_FILE=""
AFTER_FORMULAS_FILE=""
AFTER_CASKS_FILE=""
TEMP_FILES=()

make_temp_file() {
    local result_var="$1"
    local file
    file=$(mktemp)
    TEMP_FILES+=("$file")
    printf -v "$result_var" '%s' "$file"
}

use_emoji() {
    return 0
}

log_prefix() {
    local level="$1"
    if use_emoji; then
        case "$level" in
            STEP) printf '%s' "▶️ " ;;
            OK) printf '%s' "✅ " ;;
            WARN) printf '%s' "⚠️ " ;;
            ERROR) printf '%s' "❌ " ;;
            INFO) printf '%s' "ℹ️ " ;;
            SKIP) printf '%s' "⏭️ " ;;
            *) printf '%s' "" ;;
        esac
    else
        printf '[%s] ' "$level"
    fi
}

log_line() {
    local level="$1"
    shift
    printf '%s%s\n' "$(log_prefix "$level")" "$*"
}

log_step() { log_line "STEP" "$*"; }
log_ok() { log_line "OK" "$*"; }
log_warn() { log_line "WARN" "$*"; }
log_error() { log_line "ERROR" "$*"; }
log_info() { log_line "INFO" "$*"; }
log_skip() { log_line "SKIP" "$*"; }

verbose_log() {
    if [ "$VERBOSE" -eq 1 ]; then
        log_info "$*"
    fi
}

mark_step_skipped() {
    STEP_RESULT_STATUS="SKIP"
    STEP_RESULT_DETAIL="$1"
    log_skip "$1"
}

# Cleanup function
cleanup() {
    local rc="${1:-0}"
    if [ "$rc" -ne 0 ]; then
        log_error "Error occurred during $OPERATION_MODE"
    fi
    # Remove temp files registered by the script.
    local file
    for file in "${TEMP_FILES[@]}"; do
        [ -n "$file" ] && rm -f "$file" || true
    done
}

print_usage() {
    cat <<EOF
Usage: $0 [--maintenance] [--verbose] [--help]

Options:
  --maintenance  Run scheduled Homebrew maintenance only
  --verbose      Print detailed per-item progress
  --help         Show this help message
EOF
}

parse_args() {
    VERBOSE=0
    SHOW_HELP=0
    MAINTENANCE_MODE=0
    OPERATION_MODE="setup"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --maintenance)
                MAINTENANCE_MODE=1
                OPERATION_MODE="maintenance"
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --help|-h)
                SHOW_HELP=1
                ;;
            *)
                print_usage
                return 2
                ;;
        esac
        shift
    done
}

# Generate Agents capabilities document and place it under ~/.codex
generate_agents_reference() {
    log_step "Generating agents capabilities reference"
    local codex_dir="$HOME/.codex"
    mkdir -p "$codex_dir"

    if bash "$DOTFILES_DIR/agents-md.sh"; then
        log_ok "Wrote $codex_dir/AGENTS.md"
    else
        log_warn "Failed to generate AGENTS.md via agents-md.sh"
    fi
}

# Generate Homebrew inventory skill and place it under ~/.codex/skills
generate_skills_reference() {
    log_step "Generating skills inventory"
    local codex_dir="$HOME/.codex"
    mkdir -p "$codex_dir"

    if bash "$DOTFILES_DIR/skills-md.sh"; then
        log_ok "Wrote $codex_dir/skills/homebrew-inventory/SKILL.md"
    else
        log_warn "Failed to generate Homebrew inventory skill via skills-md.sh"
    fi
}

trap 'rc=$?; cleanup "$rc"; exit "$rc"' EXIT


upgrade_brew_packages() {
    local failed=0

    log_step "Updating Homebrew"
    if ! brew update; then
        log_error "Failed to update Homebrew"
        failed=1
    fi
    
    log_step "Upgrading outdated formulae"
    if ! brew upgrade; then
        log_error "Failed to upgrade Homebrew formulae"
        failed=1
    fi
    
    log_step "Upgrading casks"
    if ! brew upgrade --cask --greedy; then
        log_error "Failed to upgrade Homebrew casks"
        failed=1
    fi
    
    # Check for outdated casks that need manual intervention
    local outdated_casks
    if ! outdated_casks=$(brew outdated --cask --greedy --verbose); then
        log_warn "Failed to inspect outdated casks"
        failed=1
    fi
    if [ -n "$outdated_casks" ]; then
        log_warn "Some casks need manual upgrade; open the app updater or run brew upgrade --cask --greedy <cask>"
        echo "$outdated_casks"
    fi

    return "$failed"
}

configure_homebrew_shellenv() {
    local brew_cmd brew_prefix shellenv_line shellenv

    if command -v brew >/dev/null 2>&1; then
        brew_cmd="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
        brew_cmd="/opt/homebrew/bin/brew"
    elif [ -x /usr/local/bin/brew ]; then
        brew_cmd="/usr/local/bin/brew"
    else
        log_error "Homebrew command is not available after installation"
        return 1
    fi

    if ! brew_prefix=$("$brew_cmd" --prefix); then
        log_error "Failed to detect Homebrew prefix"
        return 1
    fi

    log_step "Adding Homebrew to PATH"
    shellenv_line="eval \"\$($brew_prefix/bin/brew shellenv)\""
    touch "$HOME/.zprofile"
    if ! grep -qF -- "$shellenv_line" "$HOME/.zprofile"; then
        printf '%s\n' "$shellenv_line" >> "$HOME/.zprofile"
    fi

    if ! shellenv=$("$brew_cmd" shellenv); then
        log_error "Failed to evaluate Homebrew shellenv"
        return 1
    fi
    eval "$shellenv"
}

begin_brew_summary() {
    capture_brew_state "before"
}

finish_brew_summary() {
    capture_brew_state "after"
    BREW_SUMMARY_TABLE=$(generate_brew_summary_table "$BEFORE_FORMULAS_FILE" "$BEFORE_CASKS_FILE" "$AFTER_FORMULAS_FILE" "$AFTER_CASKS_FILE")
}

# Capture current Homebrew state (name + version) for formulas and casks
capture_brew_state() {
    local stage="$1" # before | after

    # If brew is not available yet, skip capture
    if ! command -v brew >/dev/null 2>&1; then
        return 0
    fi

    if [ "$stage" = "before" ]; then
        make_temp_file BEFORE_FORMULAS_FILE
        make_temp_file BEFORE_CASKS_FILE
        brew list --versions 2>/dev/null | awk '{print $1, $NF}' | LC_ALL=C sort > "$BEFORE_FORMULAS_FILE" || true
        brew list --cask --versions 2>/dev/null | awk '{print $1, $NF}' | LC_ALL=C sort > "$BEFORE_CASKS_FILE" || true
    else
        make_temp_file AFTER_FORMULAS_FILE
        make_temp_file AFTER_CASKS_FILE
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
    make_temp_file bf_names
    make_temp_file af_names
    make_temp_file bc_names
    make_temp_file ac_names
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
        rm -f "$bf_names" "$af_names" "$bc_names" "$ac_names"
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

    rm -f "$bf_names" "$af_names" "$bc_names" "$ac_names"
}

notify_maintenance() {
    local status="$1"
    if [ ! -x /usr/bin/osascript ]; then
        log_info "osascript unavailable; skipping maintenance notification"
        return 0
    fi

    local message subtitle
    case "$status" in
        started)
            message="fresh.sh maintenance started at $(date '+%Y-%m-%d %H:%M')"
            subtitle="Started"
            ;;
        completed)
            message="fresh.sh maintenance completed at $(date '+%Y-%m-%d %H:%M')"
            subtitle="Completed"
            ;;
        failed)
            message="fresh.sh maintenance failed at $(date '+%Y-%m-%d %H:%M')"
            subtitle="Failed"
            ;;
        *)
            return 0
            ;;
    esac
    message=${message//\"/\\\"}

    if /usr/bin/osascript -e "display notification \"${message}\" with title \"Fresh Scheduler\" subtitle \"${subtitle}\""; then
        log_ok "Posted maintenance notification: $status"
    else
        log_warn "Failed to post maintenance notification: $status"
    fi
}

setup_launch_agent() {
    local label="$LAUNCH_AGENT_LABEL"
    local source="$LAUNCH_AGENT_SOURCE"
    local target="$LAUNCH_AGENT_TARGET"

    if [ ! -f "$source" ]; then
        mark_step_skipped "LaunchAgent template not found at $source; skipping setup"
        return 0
    fi

    mkdir -p "$(dirname "$target")"

    local rendered updated=""
    rendered=$(mktemp "${target}.tmp.XXXXXX")
    cp "$source" "$rendered"
    /usr/bin/plutil -replace ProgramArguments.1 -string "$DOTFILES_DIR/fresh.sh" "$rendered"
    /usr/bin/plutil -replace WorkingDirectory -string "$DOTFILES_DIR" "$rendered"
    /usr/bin/plutil -replace StandardOutPath -string "$HOME/Library/Logs/fresh-launchd.log" "$rendered"
    /usr/bin/plutil -replace StandardErrorPath -string "$HOME/Library/Logs/fresh-launchd.error.log" "$rendered"

    if [ ! -L "$target" ] && [ -f "$target" ] && cmp -s "$rendered" "$target"; then
        rm -f "$rendered"
        log_ok "LaunchAgent already installed at $target"
    else
        mv -f "$rendered" "$target"
        log_ok "Installed LaunchAgent at $target"
        updated="yes"
    fi

    local domain
    domain="gui/$(id -u)"
    local needs_reload=0
    if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
        needs_reload=1
    elif [ -n "$updated" ]; then
        needs_reload=1
    fi

    if [ "$needs_reload" -eq 1 ]; then
        launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
        if launchctl bootstrap "$domain" "$target"; then
            log_ok "Loaded LaunchAgent $label"
        else
            log_error "Failed to load LaunchAgent $label"
            return 1
        fi
    else
        log_ok "LaunchAgent $label already loaded"
    fi
}

setup_homebrew() {
    local failed=0

    # 🍺 Check if Homebrew is installed
    if ! command -v brew &> /dev/null; then
        log_step "Installing Homebrew"
        if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            log_error "Failed to install Homebrew"
            return 1
        fi
    else
        log_ok "Homebrew is already installed"
    fi

    if ! configure_homebrew_shellenv; then
        failed=1
    fi

    # Capture state before any bundle/upgrade/cleanup operations
    begin_brew_summary

    log_step "Applying Brewfile: $BREWFILE"
    if ! brew bundle install --file="$BREWFILE" --verbose; then
        log_error "Failed to install Homebrew bundle"
        failed=1
    fi

    if ! upgrade_brew_packages; then
        failed=1
    fi

    log_warn "Reconciling Homebrew bundle cleanup; packages not listed in $BREWFILE may be removed"
    if ! REMOVED_PACKAGES=$(brew bundle --force cleanup --file="$BREWFILE"); then
        log_error "Failed to reconcile Homebrew bundle cleanup"
        failed=1
    elif [ -n "$REMOVED_PACKAGES" ]; then
        log_info "Homebrew bundle cleanup removed:"
        echo "$REMOVED_PACKAGES"
    fi
    # Combine cleanup commands with error checking
    if ! { brew cleanup --prune=all && \
           brew cleanup -s && \
           brew cleanup --prune-prefix; }; then
        log_warn "Some cleanup operations failed"
        failed=1
    fi

    # Capture state after all operations
    finish_brew_summary

    return "$failed"
}

create_symlinks() {
    log_step "Linking dotfiles into $HOME; existing files and symlinks are replaced, directories are preserved"
    local failed=0
    local src dest
    while IFS= read -r -d '' src; do
        dest="$HOME/$(basename "$src")"
        if link_file_safely "$src" "$dest"; then
            verbose_log "$dest -> $src"
            DOTFILES_LINKED=$((DOTFILES_LINKED + 1))
        else
            failed=1
        fi
    done < <(find "$DOTFILES_DIR" -maxdepth 1 -type f -name '.*' -not -name '.gitignore' -not -name '.Brewfile' -print0)
    log_ok "Linked dotfiles: $DOTFILES_LINKED"
    return "$failed"
}

link_file_safely() {
    local src="$1"
    local target="$2"

    if [ -d "$target" ] && [ ! -L "$target" ]; then
        log_error "Refusing to replace existing directory: $target"
        return 1
    fi

    rm -f "$target"
    ln -s "$src" "$target"
}

link_config_contents() {
    local src_dir
    src_dir="$DOTFILES_DIR/.config"

    # If there's no .config directory in the repo, nothing to do
    [ -d "$src_dir" ] || return 0

    log_step "Linking .config contents into $HOME/.config; existing files and symlinks are replaced, directories are preserved"
    local dest_dir="$HOME/.config"
    mkdir -p "$dest_dir"

    # Recurse and link files, preserving subdirectory structure
    local failed=0
    local item rel_path target
    while IFS= read -r -d '' item; do
        rel_path="${item#"$src_dir/"}"
        target="$dest_dir/$rel_path"
        mkdir -p "$(dirname "$target")"
        if link_file_safely "$item" "$target"; then
            verbose_log "$target -> $item"
            CONFIG_FILES_LINKED=$((CONFIG_FILES_LINKED + 1))
        else
            failed=1
        fi
    done < <(find "$src_dir" -type f -print0)
    log_ok "Linked .config files: $CONFIG_FILES_LINKED"
    return "$failed"
}

setup_bat_theme() {
    if ! command -v bat >/dev/null 2>&1; then
        mark_step_skipped "bat unavailable; skipping bat theme setup"
        return 0
    fi

    local BATCONFIG_DIR
    BATCONFIG_DIR=$(bat --config-dir)
    local theme_file="$BATCONFIG_DIR/themes/Catppuccin Mocha.tmTheme"
    
    if [ ! -f "$theme_file" ]; then
        log_step "Installing bat Catppuccin Mocha theme"
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
            log_error "Failed to download bat theme"
            return 1
        fi
    fi
}

check_requirements() {
    local required_commands=("curl" "unzip")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
}

# Ensure sudo leverages Touch ID / biometrics for CLI usage
enable_cli_biometrics() {
    if ! command -v sudo >/dev/null 2>&1; then
        mark_step_skipped "sudo command not available; skipping Touch ID setup"
        return 0
    fi

    local pam_sudo_file="/etc/pam.d/sudo"
    if [ ! -f "$pam_sudo_file" ]; then
        mark_step_skipped "$pam_sudo_file not found; skipping Touch ID setup"
        return 0
    fi

    local pam_local_file="/etc/pam.d/sudo_local"
    if [ -f "$pam_local_file" ] && grep -Eq 'pam_(watchid|tid)\.so' "$pam_local_file"; then
        log_ok "Touch ID already enabled for sudo"
        return 0
    fi

    log_step "Enabling Touch ID authentication for sudo via pam-watchid"
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/logicer16/pam-watchid/HEAD/install.sh)" -- enable; then
        log_ok "Touch ID enabled for sudo"
    else
        log_error "Failed to enable Touch ID via pam-watchid"
        return 1
    fi
}

# Ensure Zimfw is installed and fetch modules defined in ~/.zimrc
setup_zimfw() {
    log_step "Ensuring Zimfw and modules"
    local ZIM_HOME
    ZIM_HOME="${ZDOTDIR:-$HOME}/.zim"
    mkdir -p "$ZIM_HOME"

    # Download zimfw manager if missing
    if [ ! -e "$ZIM_HOME/zimfw.zsh" ]; then
        log_step "Installing zimfw manager"
        if ! curl -fsSL --create-dirs -o "$ZIM_HOME/zimfw.zsh" \
            https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh; then
            log_error "Failed to download zimfw"
            return 1
        fi
    fi

    # zimfw 1.18.0: install installs new modules and triggers build/compile; update updates modules
     ZIM_HOME="${ZIM_HOME:-$HOME/.zim}" \
        zsh -c 'source "$ZIM_HOME/zimfw.zsh" install -q'
     ZIM_HOME="${ZIM_HOME:-$HOME/.zim}" \
        zsh -c 'source "$ZIM_HOME/zimfw.zsh" update -q'
}

run_setup_step() {
    local description="$1"
    shift

    STEP_RESULT_STATUS=""
    STEP_RESULT_DETAIL=""
    log_step "$description"

    if "$@"; then
        local status="${STEP_RESULT_STATUS:-OK}"
        local detail="${STEP_RESULT_DETAIL:-}"
        STEP_RESULTS+=("$status|$description|$detail")
        if [ "$status" = "SKIP" ]; then
            SKIPPED_STEPS+=("$description")
        else
            log_ok "$description completed"
        fi
        return 0
    fi

    FAILED_STEPS+=("$description")
    STEP_RESULTS+=("FAIL|$description|")
    log_error "$description failed"
    return 1
}

setup_screenshot_directory() {
    log_step "Setting screenshot folder to $SCREENSHOT_DIR"
    mkdir -p "$SCREENSHOT_DIR"
    defaults write com.apple.screencapture location "$SCREENSHOT_DIR"
    killall SystemUIServer || true
}

setup_rustup() {
    if command -v rustup &> /dev/null; then
        return 0
    fi

    log_step "Installing Rustup"
    if curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | sh -s -- -y; then
        RUSTUP_INSTALLED="true"
        return 0
    fi

    log_error "Failed to install Rustup"
    return 1
}

print_step_results() {
    local entry status name detail

    if [ "${#STEP_RESULTS[@]}" -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "Setup steps:"
    for entry in "${STEP_RESULTS[@]}"; do
        IFS='|' read -r status name detail <<< "$entry"
        if [ -n "$detail" ]; then
            printf "  %-4s %s (%s)\n" "$status" "$name" "$detail"
        else
            printf "  %-4s %s\n" "$status" "$name"
        fi
    done
}

has_failed_step() {
    local expected="$1"
    local step
    for step in "${FAILED_STEPS[@]}"; do
        if [ "$step" = "$expected" ]; then
            return 0
        fi
    done
    return 1
}

print_failed_steps() {
    local step

    if [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "Failed steps:"
    for step in "${FAILED_STEPS[@]}"; do
        echo "- $step"
    done
}

print_failure_triage() {
    local mode="${1:-setup}"
    local domain

    if [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
        return 0
    fi

    print_failed_steps
    echo ""
    echo "Triage:"

    if [ "$mode" = "maintenance" ]; then
        echo "- This was scheduled maintenance; rerun manually with: $0 --maintenance --verbose"
        echo "- Start with the first Homebrew error above, then retry the maintenance run."
        echo "- If a cask mentions an existing App, reconcile /Applications or /opt/homebrew/Caskroom before retrying."
        return 0
    fi

    if has_failed_step "Homebrew setup"; then
        echo "- Start with Homebrew setup. Later tooling often depends on Brew-installed commands."
        echo "- Retry the Brewfile directly with: brew bundle install --file=\"$BREWFILE\""
        echo "- If a cask error mentions an existing App, reconcile /Applications or stale /opt/homebrew/Caskroom copies before rerunning."
    fi

    if has_failed_step "Dotfile linking" || has_failed_step ".config linking"; then
        echo "- For linking failures, existing directories were not overwritten. Move, rename, or merge those directories, then rerun $0 --verbose."
    fi

    if has_failed_step "LaunchAgent setup"; then
        domain="gui/$(id -u)"
        echo "- Inspect the LaunchAgent with: launchctl print $domain/$LAUNCH_AGENT_LABEL"
        echo "- Check logs at: $HOME/Library/Logs/fresh-launchd.log and $HOME/Library/Logs/fresh-launchd.error.log"
    fi

    if has_failed_step "Zimfw setup" || has_failed_step "Rustup setup" || \
       has_failed_step "bat theme setup" || has_failed_step "Screenshot directory setup" || \
       has_failed_step "Touch ID setup"; then
        echo "- Non-Homebrew setup failures are usually follow-up tooling or macOS permission issues; fix the named step and rerun $0 --verbose."
    fi
}

print_summary() {
    echo ""
    echo "Fresh script summary:"
    echo "---------------------"
    echo "Dotfiles linked: $DOTFILES_LINKED"
    echo ".config files linked: $CONFIG_FILES_LINKED"
    print_step_results
    if [ -n "$RUSTUP_INSTALLED" ]; then
        echo "Rustup installed: yes"
    fi

    echo ""
    echo "Homebrew changes (this run):"
    if [ -n "$BREW_SUMMARY_TABLE" ]; then
        echo "$BREW_SUMMARY_TABLE"
    else
        echo "No Homebrew changes detected."
    fi
    echo "---------------------"
}

print_maintenance_summary() {
    echo ""
    echo "Homebrew changes (maintenance run):"
    if [ -n "$BREW_SUMMARY_TABLE" ]; then
        echo "$BREW_SUMMARY_TABLE"
    else
        echo "No Homebrew changes detected."
    fi
    echo "---------------------"
}

run_maintenance() {
    OPERATION_MODE="maintenance"
    local failed=0

    log_step "Running scheduled Homebrew maintenance"
    notify_maintenance "started"

    if ! command -v brew >/dev/null 2>&1; then
        log_error "Homebrew is not installed; run fresh.sh manually first"
        FAILED_STEPS+=("Homebrew maintenance")
        notify_maintenance "failed"
        print_failure_triage "maintenance"
        return 1
    fi

    begin_brew_summary
    if ! upgrade_brew_packages; then
        failed=1
        FAILED_STEPS+=("Homebrew maintenance")
    fi
    finish_brew_summary
    print_maintenance_summary

    if [ "$failed" -ne 0 ]; then
        log_error "Maintenance completed with errors"
        print_failure_triage "maintenance"
        notify_maintenance "failed"
        return 1
    fi

    log_ok "Maintenance completed successfully"
    notify_maintenance "completed"
}

main() {
    # Check if running on macOS
    if [ "$(uname)" != "Darwin" ]; then
        log_error "This script is only for macOS"
        exit 1
    fi

    if ! parse_args "$@"; then
        return 2
    fi

    if [ "$SHOW_HELP" -eq 1 ]; then
        print_usage
        return 0
    fi

    if [ "$MAINTENANCE_MODE" -eq 1 ]; then
            run_maintenance
            return
    fi

    log_step "Setting up your Mac"

    # Check requirements before running any network-dependent steps
    check_requirements

    local setup_failed=0

    # Setup steps
    if ! run_setup_step "Touch ID setup" enable_cli_biometrics; then setup_failed=1; fi
    if ! run_setup_step "Dotfile linking" create_symlinks; then setup_failed=1; fi
    if ! run_setup_step ".config linking" link_config_contents; then setup_failed=1; fi
    if ! run_setup_step "Homebrew setup" setup_homebrew; then setup_failed=1; fi
    if ! run_setup_step "Zimfw setup" setup_zimfw; then setup_failed=1; fi
    if ! run_setup_step "LaunchAgent setup" setup_launch_agent; then setup_failed=1; fi

    # Setup bat theme
    if ! run_setup_step "bat theme setup" setup_bat_theme; then setup_failed=1; fi

    # Generate AGENTS.md to ~/.codex for agents to consume
    generate_agents_reference
    # Generate SKILLS.md to ~/.codex for agents to consume
    generate_skills_reference

    if ! run_setup_step "Screenshot directory setup" setup_screenshot_directory; then setup_failed=1; fi

    # Install rustup if not present (non-interactive)
    if ! run_setup_step "Rustup setup" setup_rustup; then setup_failed=1; fi

    print_summary

    if [ "$setup_failed" -ne 0 ]; then
        log_error "Setup completed with errors"
        print_failure_triage "setup"
        return 1
    fi

    log_ok "Setup completed successfully"
    log_info "Restart your terminal for changes to take effect."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

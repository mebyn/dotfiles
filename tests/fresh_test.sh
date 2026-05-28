#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2329

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/fresh.sh"
PLIST="$ROOT_DIR/launchd/com.melvin.fresh.plist"
PASSED=0
FAILED=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

assert_contains() {
    local file="$1"
    local text="$2"
    grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_not_contains() {
    local file="$1"
    local text="$2"
    if grep -Fq -- "$text" "$file"; then
        fail "$file unexpectedly contains: $text"
    fi
}

assert_text_not_contains() {
    local value="$1"
    local text="$2"
    case "$value" in
        *"$text"*)
            fail "output unexpectedly contains: $text"
            ;;
    esac
}

assert_text_contains() {
    local value="$1"
    local text="$2"
    case "$value" in
        *"$text"*)
            return 0
            ;;
    esac
    fail "output does not contain: $text"
}

create_fixture() {
    local dir="$1"
    mkdir -p "$dir/repo/launchd" "$dir/repo/.config/atuin" "$dir/home" "$dir/bin"
    sed '$d' "$SCRIPT" > "$dir/repo/fresh.sh"
    cp "$PLIST" "$dir/repo/launchd/com.melvin.fresh.plist"
    printf 'fixture = true\n' > "$dir/repo/.config/atuin/config.toml"
}

stub_launchctl() {
    local dir="$1"
    cat > "$dir/bin/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [ "${1:-}" = "print" ] || [ "${1:-}" = "list" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$dir/bin/launchctl"
}

stub_successful_brew() {
    local dir="$1"
    cat > "$dir/bin/brew" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$BREW_LOG"
case "$*" in
    "list --versions")
        printf 'ripgrep 14.0\n'
        ;;
    "list --cask --versions")
        printf 'ghostty 1.0\n'
        ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/brew"
}

test_launch_agent_replaces_dangling_link_with_rendered_plist() (
    local dir
    dir="$(mktemp -d)"
    create_fixture "$dir"
    stub_launchctl "$dir"
    export HOME="$dir/home"
    export PATH="$dir/bin:$PATH"
    export LAUNCHCTL_LOG="$dir/launchctl.log"
    mkdir -p "$HOME/Library/LaunchAgents"
    ln -s "$dir/old-checkout/com.melvin.fresh.plist" "$HOME/Library/LaunchAgents/com.melvin.fresh.plist"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    setup_launch_agent >/dev/null

    local installed="$HOME/Library/LaunchAgents/com.melvin.fresh.plist"
    [ ! -L "$installed" ] || { fail "LaunchAgent target remains a symlink"; return 1; }
    assert_contains "$installed" "$dir/repo/fresh.sh" || return 1
    assert_contains "$installed" "--maintenance" || return 1
    assert_not_contains "$installed" "ThrottleInterval" || return 1
    assert_contains "$LAUNCHCTL_LOG" "bootstrap gui/" || return 1
)

test_maintenance_mode_only_runs_non_destructive_brew_updates() (
    local dir output
    dir="$(mktemp -d)"
    create_fixture "$dir"
    stub_successful_brew "$dir"
    export HOME="$dir/home"
    export PATH="$dir/bin:$PATH"
    export BREW_LOG="$dir/brew.log"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    notify_maintenance() { :; }
    type -t run_maintenance >/dev/null || { fail "run_maintenance is not implemented"; return 1; }
    output="$(run_maintenance 2>&1)"

    assert_contains "$BREW_LOG" "update" || return 1
    assert_contains "$BREW_LOG" "upgrade" || return 1
    assert_not_contains "$BREW_LOG" "bundle" || return 1
    assert_text_not_contains "$output" "Setting up your Mac" || return 1
)

test_maintenance_failure_returns_nonzero_without_success_message() (
    local dir output rc
    dir="$(mktemp -d)"
    create_fixture "$dir"
    stub_successful_brew "$dir"
    cat > "$dir/bin/brew" <<'EOF'
#!/bin/bash
case "$*" in
    "list --versions"|"list --cask --versions")
        exit 0
        ;;
    "update")
        exit 1
        ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/brew"
    export HOME="$dir/home"
    export PATH="$dir/bin:$PATH"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    notify_maintenance() { :; }
    type -t run_maintenance >/dev/null || { fail "run_maintenance is not implemented"; return 1; }
    set +e
    output="$(run_maintenance 2>&1)"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || { fail "maintenance failure returned success"; return 1; }
    printf '%s\n' "$output" | grep -Fq "completed with errors" || { fail "maintenance failure is not reported"; return 1; }
    if printf '%s\n' "$output" | grep -Fq "completed successfully"; then
        fail "maintenance failure printed a success message"
        return 1
    fi
)

test_bootstrap_homebrew_failure_returns_nonzero() (
    local dir rc
    dir="$(mktemp -d)"
    create_fixture "$dir"
    cat > "$dir/bin/brew" <<'EOF'
#!/bin/bash
case "$*" in
    "shellenv")
        printf ':\n'
        ;;
    "bundle install"*)
        exit 1
        ;;
    "list --versions"|"list --cask --versions")
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/brew"
    export HOME="$dir/home"
    export PATH="$dir/bin:$PATH"
    touch "$HOME/.zprofile"
    sed -e 's#/opt/homebrew/bin/brew#brew#g' -e 's#/usr/local/bin/brew#brew#g' \
        "$dir/repo/fresh.sh" > "$dir/repo/fresh.sh.stubbed"
    mv "$dir/repo/fresh.sh.stubbed" "$dir/repo/fresh.sh"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    set +e
    setup_homebrew >/dev/null 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || { fail "bootstrap swallowed a brew bundle failure"; return 1; }
)

test_config_link_count_persists_after_linking() (
    local dir
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    link_config_contents >/dev/null

    [ "$CONFIG_FILES_LINKED" -eq 1 ] || { fail "expected one linked config file, got $CONFIG_FILES_LINKED"; return 1; }
)

test_summary_removes_internal_temp_files() (
    local dir count
    dir="$(mktemp -d)"
    create_fixture "$dir"
    mkdir -p "$dir/tmp" "$dir/data"
    : > "$dir/data/before-formulas"
    : > "$dir/data/before-casks"
    : > "$dir/data/after-formulas"
    : > "$dir/data/after-casks"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    mktemp() {
        /usr/bin/mktemp "$dir/tmp/fresh.XXXXXX"
    }
    generate_brew_summary_table \
        "$dir/data/before-formulas" "$dir/data/before-casks" \
        "$dir/data/after-formulas" "$dir/data/after-casks" >/dev/null

    count="$(find "$dir/tmp" -type f | wc -l | tr -d ' ')"
    [ "$count" -eq 0 ] || { fail "brew summary leaked $count temporary files"; return 1; }
)

test_script_is_safe_to_source() {
    grep -Fq '[ "${BASH_SOURCE[0]}" = "$0" ]' "$SCRIPT" ||
        fail "fresh.sh does not guard main execution when sourced"
}

test_brewfile_installs_shellcheck() {
    assert_contains "$ROOT_DIR/.Brewfile" 'brew "shellcheck"'
}

test_homebrew_shellenv_uses_detected_prefix() (
    local dir
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"
    export PATH="$dir/bin:$PATH"
    export BREW_PREFIX_VALUE="$dir/homebrew"
    export BREW_LOG="$dir/brew.log"
    touch "$HOME/.zprofile"

    cat > "$dir/bin/brew" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$BREW_LOG"
case "$*" in
    "--prefix")
        printf '%s\n' "$BREW_PREFIX_VALUE"
        ;;
    "shellenv")
        printf 'export PATH="%s/bin:$PATH"\n' "$BREW_PREFIX_VALUE"
        ;;
    "list --versions"|"list --cask --versions")
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/brew"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    setup_homebrew >/dev/null 2>&1

    assert_contains "$HOME/.zprofile" "eval \"\$($BREW_PREFIX_VALUE/bin/brew shellenv)\"" || return 1
    assert_not_contains "$HOME/.zprofile" 'eval "$(/opt/homebrew/bin/brew shellenv)"' || return 1
)

test_config_link_refuses_to_replace_directory() (
    local dir target rc
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"
    target="$HOME/.config/atuin/config.toml"
    mkdir -p "$target"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    set +e
    link_config_contents >/dev/null 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || { fail "config linking replaced an existing directory"; return 1; }
    [ -d "$target" ] || { fail "existing config directory was removed"; return 1; }
    [ ! -L "$target" ] || { fail "existing config directory became a symlink"; return 1; }
)

test_dotfile_link_refuses_to_replace_directory() (
    local dir target rc
    dir="$(mktemp -d)"
    create_fixture "$dir"
    printf 'set number\n' > "$dir/repo/.vimrc"
    export HOME="$dir/home"
    target="$HOME/.vimrc"
    mkdir -p "$target"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    set +e
    create_symlinks >/dev/null 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || { fail "dotfile linking replaced an existing directory"; return 1; }
    [ -d "$target" ] || { fail "existing dotfile directory was removed"; return 1; }
    [ ! -L "$target" ] || { fail "existing dotfile directory became a symlink"; return 1; }
)

test_bat_theme_skips_when_bat_is_unavailable() (
    local dir
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"
    export PATH="$dir/bin:/usr/bin:/bin"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    setup_bat_theme >/dev/null
)

test_help_prints_available_options() (
    local dir output
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    output="$(main --help 2>&1)"

    assert_text_contains "$output" "Usage:" || return 1
    assert_text_contains "$output" "--maintenance" || return 1
    assert_text_contains "$output" "--verbose" || return 1
    assert_text_contains "$output" "--help" || return 1
)

test_log_output_uses_emoji_by_default() (
    local dir output
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    output="$(log_ok "plain output" 2>&1)"

    assert_text_contains "$output" "✅ plain output" || return 1
    assert_text_not_contains "$output" "[OK]" || return 1
)

test_default_linking_output_omits_per_file_lines() (
    local dir output
    dir="$(mktemp -d)"
    create_fixture "$dir"
    printf 'set number\n' > "$dir/repo/.vimrc"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    output="$(create_symlinks 2>&1)"

    assert_text_contains "$output" "Linked dotfiles:" || return 1
    assert_text_not_contains "$output" " -> " || return 1
)

test_verbose_linking_output_prints_per_file_lines() (
    local dir output
    dir="$(mktemp -d)"
    create_fixture "$dir"
    printf 'set number\n' > "$dir/repo/.vimrc"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    parse_args --verbose
    output="$(create_symlinks 2>&1)"

    assert_text_contains "$output" " -> " || return 1
)

test_setup_failure_prints_homebrew_triage() (
    local dir output rc
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    check_requirements() { :; }
    enable_cli_biometrics() { :; }
    create_symlinks() { :; }
    link_config_contents() { :; }
    setup_homebrew() { return 1; }
    setup_zimfw() { :; }
    setup_launch_agent() { :; }
    setup_bat_theme() { :; }
    generate_agents_reference() { :; }
    generate_skills_reference() { :; }
    setup_screenshot_directory() { :; }
    setup_rustup() { :; }

    set +e
    output="$(main 2>&1)"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || { fail "setup failure returned success"; return 1; }
    assert_text_contains "$output" "Failed steps:" || return 1
    assert_text_contains "$output" "- Homebrew setup" || return 1
    assert_text_contains "$output" "Triage:" || return 1
    assert_text_contains "$output" "brew bundle install --file=" || return 1
    assert_text_contains "$output" "existing App" || return 1
)

test_setup_failure_prints_symlink_triage() (
    local dir output rc
    dir="$(mktemp -d)"
    create_fixture "$dir"
    export HOME="$dir/home"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    check_requirements() { :; }
    enable_cli_biometrics() { :; }
    create_symlinks() { return 1; }
    link_config_contents() { return 1; }
    setup_homebrew() { :; }
    setup_zimfw() { :; }
    setup_launch_agent() { :; }
    setup_bat_theme() { :; }
    generate_agents_reference() { :; }
    generate_skills_reference() { :; }
    setup_screenshot_directory() { :; }
    setup_rustup() { :; }

    set +e
    output="$(main 2>&1)"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || { fail "setup failure returned success"; return 1; }
    assert_text_contains "$output" "existing directories were not overwritten" || return 1
)

test_maintenance_failure_prints_maintenance_triage() (
    local dir output rc
    dir="$(mktemp -d)"
    create_fixture "$dir"
    stub_successful_brew "$dir"
    export HOME="$dir/home"
    export PATH="$dir/bin:$PATH"
    export BREW_LOG="$dir/brew.log"

    source "$dir/repo/fresh.sh"
    trap - EXIT
    notify_maintenance() { :; }
    upgrade_brew_packages() { return 1; }

    set +e
    output="$(main --maintenance 2>&1)"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || { fail "maintenance failure returned success"; return 1; }
    assert_text_contains "$output" "Triage:" || return 1
    assert_text_contains "$output" "scheduled maintenance" || return 1
    assert_text_not_contains "$output" "existing directories were not overwritten" || return 1
)

run_test() {
    local name="$1"
    if "$name"; then
        printf 'PASS: %s\n' "$name"
        PASSED=$((PASSED + 1))
    else
        printf 'FAIL: %s\n' "$name"
        FAILED=$((FAILED + 1))
    fi
}

run_test test_launch_agent_replaces_dangling_link_with_rendered_plist
run_test test_maintenance_mode_only_runs_non_destructive_brew_updates
run_test test_maintenance_failure_returns_nonzero_without_success_message
run_test test_bootstrap_homebrew_failure_returns_nonzero
run_test test_config_link_count_persists_after_linking
run_test test_summary_removes_internal_temp_files
run_test test_script_is_safe_to_source
run_test test_brewfile_installs_shellcheck
run_test test_homebrew_shellenv_uses_detected_prefix
run_test test_config_link_refuses_to_replace_directory
run_test test_dotfile_link_refuses_to_replace_directory
run_test test_bat_theme_skips_when_bat_is_unavailable
run_test test_help_prints_available_options
run_test test_log_output_uses_emoji_by_default
run_test test_default_linking_output_omits_per_file_lines
run_test test_verbose_linking_output_prints_per_file_lines
run_test test_setup_failure_prints_homebrew_triage
run_test test_setup_failure_prints_symlink_triage
run_test test_maintenance_failure_prints_maintenance_triage

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]

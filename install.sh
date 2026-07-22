#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STAMP="$(date +%Y%m%d-%H%M%S)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CODEX_ROOT="${CODEX_HOME:-$HOME/.codex}"
BIN_DIR="$HOME/.local/bin"
LIB_ROOT="$HOME/.local/lib/project-terminal"
WAIT_ONLINE="/usr/lib/systemd/systemd-networkd-wait-online"
PREFLIGHT=1

usage() {
    printf 'Usage: %s [bash|zsh|fish]\n' "$0"
}

fail() {
    printf 'install: %s\n' "$*" >&2
    if (( PREFLIGHT )); then
        printf 'install: preflight failed; no changes made\n' >&2
    fi
    exit 1
}

link_conflict() {
    local source="$1"
    local target="$2"

    printf 'install: conflicting target: %s\n' "$target" >&2
    printf 'install: preflight failed; no changes made\n' >&2
    printf 'Manual integration:\n  source: %s\n  target: %s\n' "$source" "$target" >&2
    printf '  after moving the conflicting target: ln -s -- %q %q\n' "$source" "$target" >&2
    exit 1
}

config_conflict() {
    local message="$1"
    local source="$2"
    local target="$3"

    printf 'install: %s\n' "$message" >&2
    printf 'install: preflight failed; no changes made\n' >&2
    printf 'Manual integration:\n  source: %s\n  target: %s\n' "$source" "$target" >&2
    printf '  merge required setting from source into target, then rerun install\n' >&2
    exit 1
}

check_link() {
    local source="$1"
    local target="$2"
    local legacy="${3:-}"
    local current=''
    local resolved=''

    if [[ -L "$target" ]]; then
        current="$(readlink -- "$target")"
        resolved="$(readlink -f -- "$target" 2>/dev/null || true)"
        [[ "$resolved" == "$source" || "$current" == "$source" || -n "$legacy" && "$current" == "$legacy" ]] && return 0
        link_conflict "$source" "$target"
    fi
    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] && cmp -s -- "$source" "$target" && return 0
        link_conflict "$source" "$target"
    fi
}

link_file() {
    local source="$1"
    local target="$2"

    mkdir -p -- "$(dirname -- "$target")"
    if [[ -L "$target" || -e "$target" ]]; then
        rm -f -- "$target"
    fi
    ln -s -- "$source" "$target"
}

backup() {
    local target="$1"
    cp -- "$target" "$target.bak.$STAMP"
}

check_parent() {
    local target="$1"
    local parent
    local previous=''

    parent="$(dirname -- "$target")"
    while [[ ! -e "$parent" && ! -L "$parent" && "$parent" != "$previous" ]]; do
        previous="$parent"
        parent="$(dirname -- "$parent")"
    done
    [[ -d "$parent" && -w "$parent" && -x "$parent" ]] || \
        fail "Install parent is not writable: $parent (for $target)"
}

[[ $# -le 1 ]] || { usage >&2; exit 1; }
if [[ ${1:-} == '-h' || ${1:-} == '--help' ]]; then
    usage
    exit 0
fi

for variable in HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR CODEX_HOME; do
    value="${!variable:-}"
    [[ -z "$value" || "$value" == /* ]] || fail "$variable must be an absolute path"
done
[[ -d "$HOME" ]] || fail "Home directory not found: $HOME"
[[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" && -w "$XDG_RUNTIME_DIR" ]] || \
    fail 'XDG_RUNTIME_DIR is missing or not writable'

if [[ $# -eq 1 ]]; then
    shell_name="$1"
else
    passwd_entry="$(getent passwd "$(id -u)" 2>/dev/null || true)"
    login_shell="${passwd_entry##*:}"
    shell_name="$(basename -- "${login_shell:-${SHELL:-/bin/bash}}")"
fi
case "$shell_name" in
    bash|zsh|fish) ;;
    *) fail "Unsupported shell: $shell_name" ;;
esac

shell_path="$(type -P -- "$shell_name" 2>/dev/null || true)"
shell_path="$(realpath -e -- "$shell_path" 2>/dev/null || true)"
[[ "$shell_path" == /* && -f "$shell_path" && -x "$shell_path" ]] || \
    fail "Missing shell: $shell_name (Arch package: $shell_name)"

case "$shell_name" in
    bash)
        shell_rc_target="$HOME/.bashrc"
        shell_source="$ROOT/shell/sh"
        shell_target="$LIB_ROOT/shell/sh"
        shell_source_line=". \"\$HOME/.local/lib/project-terminal/shell/sh\""
        ;;
    zsh)
        zsh_config_dir="$(env -u PROJECT_TERMINAL_MANAGED "$shell_path" -c \
            "printf '%s\\n' \"\${ZDOTDIR:-\$HOME}\"")" || fail 'Could not resolve ZDOTDIR'
        [[ "$zsh_config_dir" == /* && "$zsh_config_dir" != *$'\n'* ]] || \
            fail "ZDOTDIR must resolve to one absolute path: $zsh_config_dir"
        shell_rc_target="$zsh_config_dir/.zshrc"
        shell_source="$ROOT/shell/sh"
        shell_target="$LIB_ROOT/shell/sh"
        shell_source_line=". \"\$HOME/.local/lib/project-terminal/shell/sh\""
        ;;
    fish)
        shell_rc_target="$CONFIG_HOME/fish/config.fish"
        shell_source="$ROOT/shell/fish"
        shell_target="$LIB_ROOT/shell/fish"
        shell_source_line="source \"\$HOME/.local/lib/project-terminal/shell/fish\""
        ;;
esac

[[ -e "$shell_rc_target" || -L "$shell_rc_target" ]] || \
    config_conflict "Shell config not found: $shell_rc_target" "$shell_source" "$shell_rc_target"
shell_rc="$(realpath -e -- "$shell_rc_target" 2>/dev/null || true)"
[[ -f "$shell_rc" && -w "$shell_rc" ]] || \
    config_conflict "Shell config is not a writable file: $shell_rc_target" "$shell_source" "$shell_rc_target"

required_sources=(
    "$ROOT/scripts/project-terminal"
    "$ROOT/codex/wrapper"
    "$ROOT/codex/hooks.json"
    "$ROOT/assets/icon.png"
    "$ROOT/hyprland/bindings.conf"
    "$ROOT/shell/sh"
    "$ROOT/shell/fish"
    "$ROOT/systemd/project-terminal@.service"
    "$ROOT/tmux/tmux.conf"
    "$ROOT/omarchy/post-boot"
)
for source in "${required_sources[@]}"; do
    [[ -f "$source" ]] || fail "Missing repository file: $source"
done
for source in "$ROOT/scripts/project-terminal" "$ROOT/codex/wrapper" "$ROOT/omarchy/post-boot"; do
    [[ -x "$source" ]] || fail "Repository script is not executable: $source"
done

required_commands=(
    bash cmp find flock getent Hyprland hyprctl jq omarchy realpath rg sed sha256sum
    sort systemctl systemd-id128 systemd-run tmux foot footclient omarchy-launch-walker
    uwsm-app walker
)
missing_commands=()
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if [[ ${#missing_commands[@]} -gt 0 ]]; then
    fail "Missing commands: ${missing_commands[*]}. Omarchy supplies platform tools; install Arch package foot for Foot"
fi
[[ -x "$WAIT_ONLINE" ]] || fail "Missing network readiness check: $WAIT_ONLINE"
systemctl --user cat foot-server.socket >/dev/null 2>&1 || fail 'Missing foot-server.socket (Arch package: foot)'
socket_state="$(systemctl --user is-enabled foot-server.socket 2>/dev/null || true)"
[[ "$socket_state" != masked* ]] || fail 'foot-server.socket is masked; unmask it before install'
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) fail "$BIN_DIR must be on PATH for Hyprland integration" ;;
esac

hypr_config_target="$CONFIG_HOME/hypr/bindings.conf"
hypr_main="$CONFIG_HOME/hypr/hyprland.conf"
[[ -e "$hypr_config_target" || -L "$hypr_config_target" ]] || \
    config_conflict "Hyprland bindings not found: $hypr_config_target" "$ROOT/hyprland/bindings.conf" "$hypr_config_target"
hypr_config="$(realpath -e -- "$hypr_config_target" 2>/dev/null || true)"
[[ -f "$hypr_config" && -w "$hypr_config" ]] || \
    config_conflict "Hyprland bindings are not a writable file: $hypr_config_target" "$ROOT/hyprland/bindings.conf" "$hypr_config_target"
[[ -f "$hypr_main" ]] || fail "Hyprland config not found: $hypr_main"
Hyprland --verify-config --config "$hypr_main" >/dev/null 2>&1 || fail "Existing Hyprland config is invalid: $hypr_main"

mapfile -t hypr_lines < <(rg -v '^$' "$ROOT/hyprland/bindings.conf")
[[ ${#hypr_lines[@]} -eq 2 ]] || fail 'Hyprland snippet must contain exactly two lines'
legacy_tmux_binding="bindd = SUPER ALT, RETURN, Tmux, exec, uwsm-app -- xdg-terminal-exec --dir=\"\$(omarchy-cmd-terminal-cwd)\" tmux new"
legacy_unbind='unbind = SUPER ALT, RETURN  # was: Tmux'
legacy_binding_absolute="bindd = SUPER ALT, RETURN, Project terminals, exec, uwsm-app -- $HOME/.local/bin/project-terminal menu"
legacy_binding_command='bindd = SUPER ALT, RETURN, Project terminals, exec, uwsm-app -- project-terminal menu'
binding_count=0
desired_unbind_count=0
desired_binding_count=0
while IFS= read -r binding; do
    [[ -n "$binding" ]] || continue
    binding_count=$((binding_count + 1))
    case "$binding" in
        "${hypr_lines[0]}") desired_unbind_count=$((desired_unbind_count + 1)) ;;
        "${hypr_lines[1]}") desired_binding_count=$((desired_binding_count + 1)) ;;
        "$legacy_tmux_binding"|"$legacy_unbind"|"$legacy_binding_absolute"|"$legacy_binding_command") ;;
        *)
            config_conflict 'Super+Alt+Return already has a different binding' \
                "$ROOT/hyprland/bindings.conf" "$hypr_config_target"
            ;;
    esac
done < <(rg '^[[:space:]]*(unbind|bindd?)[[:space:]]*=[[:space:]]*SUPER ALT,[[:space:]]*RETURN([,[:space:]]|$)' "$hypr_config" || true)
hypr_needs_update=0
if (( binding_count != 2 || desired_unbind_count != 1 || desired_binding_count != 1 )); then
    hypr_needs_update=1
fi

manager_target="$BIN_DIR/project-terminals"
wrapper_target="$LIB_ROOT/bin/codex"
tmux_target="$CONFIG_HOME/project-terminals/tmux.conf"
unit_target="$CONFIG_HOME/systemd/user/project-terminal@.service"
post_boot_target="$HOME/.config/omarchy/hooks/post-boot.d/20-project-terminals"
hooks_target="$CODEX_ROOT/hooks.json"
shell_file_target="$CONFIG_HOME/project-terminals/shell"
auto_restore_file="$CONFIG_HOME/project-terminals/auto-restore"
notification_icon_target="$DATA_HOME/project-terminals/icon.png"

check_link "$ROOT/scripts/project-terminal" "$manager_target" "$ROOT/project-terminal"
check_link "$ROOT/codex/wrapper" "$wrapper_target" "$ROOT/codex-wrapper"
check_link "$ROOT/tmux/tmux.conf" "$tmux_target" "$ROOT/tmux.conf"
check_link "$ROOT/systemd/project-terminal@.service" "$unit_target" "$ROOT/project-terminal@.service"
check_link "$ROOT/omarchy/post-boot" "$post_boot_target" "$ROOT/post-boot"
check_link "$ROOT/assets/icon.png" "$notification_icon_target"
check_link "$shell_source" "$shell_target"

link_hooks=1
hook_command="\"\$HOME/.local/bin/project-terminals\" codex-session-start"
hook_matcher='startup|resume|clear|compact'
if [[ -e "$hooks_target" || -L "$hooks_target" ]]; then
    hooks_resolved="$(readlink -f -- "$hooks_target" 2>/dev/null || true)"
    if [[ -L "$hooks_target" && "$(readlink -- "$hooks_target")" == "$ROOT/hooks.json" ]]; then
        :
    elif [[ "$hooks_resolved" == "$ROOT/codex/hooks.json" ]]; then
        :
    elif [[ -f "$hooks_target" ]] && cmp -s -- "$ROOT/codex/hooks.json" "$hooks_target"; then
        :
    elif jq -e --arg command "$hook_command" --arg matcher "$hook_matcher" \
        '.hooks.SessionStart[]? | select(.matcher == $matcher) | .hooks[]? | select(.type == "command" and .command == $command)' \
        "$hooks_target" >/dev/null 2>&1; then
        link_hooks=0
    else
        config_conflict 'Codex hooks already exist; merge the SessionStart hook and rerun' "$ROOT/codex/hooks.json" "$hooks_target"
    fi
fi
if (( link_hooks )); then
    check_link "$ROOT/codex/hooks.json" "$hooks_target" "$ROOT/hooks.json"
fi

shell_file="$shell_file_target"
[[ ! -L "$shell_file_target" ]] || fail "Shell state must not be a symlink: $shell_file_target"
if [[ -e "$shell_file_target" ]]; then
    [[ -f "$shell_file_target" && -w "$shell_file_target" ]] || \
        fail "Invalid shell state file: $shell_file_target"
    previous_shell="$(<"$shell_file_target")"
    [[ "$previous_shell" != *$'\n'* && -f "$previous_shell" && -x "$previous_shell" ]] || \
        fail "Unrecognised shell state in: $shell_file_target"
    case "$previous_shell" in
        /*/bash|/*/zsh|/*/fish) ;;
        *) fail "Unrecognised shell state in: $shell_file_target" ;;
    esac
fi

if [[ -e "$auto_restore_file" || -L "$auto_restore_file" ]]; then
    [[ -f "$auto_restore_file" && ! -L "$auto_restore_file" && -w "$auto_restore_file" ]] || \
        fail "Invalid automatic restore setting: $auto_restore_file"
    auto_restore_value="$(<"$auto_restore_file")"
    case "$auto_restore_value" in
        on|off) ;;
        *) fail "Automatic restore must be on or off in: $auto_restore_file" ;;
    esac
fi

legacy_shell_marker='# Keep managed Codex wrapper ahead after normal shell setup.'
legacy_shell_block="# Keep managed Codex wrapper ahead after normal shell setup.
if [[ \${PROJECT_TERMINAL_MANAGED:-} == 1 ]]; then
  export PATH=\"\$HOME/.local/lib/project-terminal/bin:\$PATH\"
fi"
legacy_marker_count="$(rg -F -x -c "$legacy_shell_marker" "$shell_rc" || true)"
legacy_block_count="$(rg -U -F -c "$legacy_shell_block" "$shell_rc" || true)"
legacy_marker_count="${legacy_marker_count:-0}"
legacy_block_count="${legacy_block_count:-0}"
[[ "$legacy_marker_count" == "$legacy_block_count" ]] || \
    config_conflict 'Old project terminals shell block was edited; remove it manually and rerun' \
        "$shell_source" "$shell_rc_target"

shell_remove_legacy=0
(( legacy_block_count == 0 )) || shell_remove_legacy=1
source_line_count="$(rg -F -x -c "$shell_source_line" "$shell_rc" || true)"
source_line_count="${source_line_count:-0}"
last_shell_line="$(sed -n "/[^[:space:]]/h; \${x;p;}" "$shell_rc")"
shell_needs_update=0
if (( source_line_count != 1 || shell_remove_legacy )) || [[ "$last_shell_line" != "$shell_source_line" ]]; then
    shell_needs_update=1
fi

install_targets=(
    "$manager_target" "$wrapper_target" "$tmux_target" "$unit_target"
    "$post_boot_target" "$shell_target" "$shell_file"
    "$auto_restore_file" "$notification_icon_target"
)
(( link_hooks == 0 )) || install_targets+=("$hooks_target")
for target in "${install_targets[@]}"; do
    check_parent "$target"
done
(( hypr_needs_update == 0 )) || check_parent "$hypr_config"
(( shell_needs_update == 0 )) || check_parent "$shell_rc"

PREFLIGHT=0

link_file "$ROOT/scripts/project-terminal" "$manager_target"
link_file "$ROOT/codex/wrapper" "$wrapper_target"
link_file "$ROOT/tmux/tmux.conf" "$tmux_target"
link_file "$ROOT/systemd/project-terminal@.service" "$unit_target"
link_file "$ROOT/omarchy/post-boot" "$post_boot_target"
link_file "$ROOT/assets/icon.png" "$notification_icon_target"
link_file "$shell_source" "$shell_target"
if (( link_hooks )); then
    link_file "$ROOT/codex/hooks.json" "$hooks_target"
fi

mkdir -p -- "$(dirname -- "$shell_file")"
temporary="$(mktemp "$(dirname -- "$shell_file")/.shell.XXXXXX")"
printf '%s\n' "$shell_path" >"$temporary"
chmod 600 "$temporary"
mv -f -- "$temporary" "$shell_file"

if [[ ! -e "$auto_restore_file" ]]; then
    mkdir -p -- "$(dirname -- "$auto_restore_file")"
    temporary="$(mktemp "$(dirname -- "$auto_restore_file")/.auto-restore.XXXXXX")"
    printf '%s\n' on >"$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$auto_restore_file"
fi

if (( hypr_needs_update )); then
    backup "$hypr_config"
    sed -i -E '/^[[:space:]]*(unbind|bindd?)[[:space:]]*=[[:space:]]*SUPER ALT,[[:space:]]*RETURN([,[:space:]]|$)/d' "$hypr_config"
    printf '\n%s\n%s\n' "${hypr_lines[0]}" "${hypr_lines[1]}" >>"$hypr_config"
fi

if (( shell_needs_update )); then
    backup "$shell_rc"
    if (( shell_remove_legacy )); then
        sed -i '/^# Keep managed Codex wrapper ahead after normal shell setup\.$/,+3d' "$shell_rc"
    fi
    case "$shell_name" in
        bash|zsh) sed -i "\\|^\\. \"\\\$HOME/\\.local/lib/project-terminal/shell/sh\"\$|d" "$shell_rc" ;;
        fish) sed -i "\\|^source \"\\\$HOME/\\.local/lib/project-terminal/shell/fish\"\$|d" "$shell_rc" ;;
    esac
    if rg -q -F -x '# Project terminals' "$shell_rc"; then
        printf '\n%s\n' "$shell_source_line" >>"$shell_rc"
    else
        printf '\n# Project terminals\n%s\n' "$shell_source_line" >>"$shell_rc"
    fi
fi

systemctl --user daemon-reload
systemctl --user enable --now foot-server.socket
if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    hyprctl reload >/dev/null
    config_errors="$(hyprctl configerrors)"
    [[ -z "$config_errors" ]] || fail "Hyprland config error: $config_errors"
fi

printf 'Installed project terminals from %s\n' "$ROOT"
printf 'Managed shell: %s\n' "$shell_path"
printf 'Set projects directory: project-terminals projects-dir PATH\n'
printf 'Set automatic restore: project-terminals auto-restore on|off\n'

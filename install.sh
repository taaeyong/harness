#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_platform() {
    local src_dir="$1"
    local target_dir="$2"
    local label="$3"

    if [ ! -d "$src_dir" ]; then
        echo "  (no $label skills found, skipping)"
        return
    fi

    mkdir -p "$target_dir"
    echo "[$label] -> $target_dir"

    for skill_path in "$src_dir"/*/; do
        local name
        name="$(basename "$skill_path")"
        local target="$target_dir/$name"

        if [ -e "$target" ] && [ ! -L "$target" ]; then
            echo "  ! skip: $name (already exists, not a symlink)"
        elif [ -L "$target" ]; then
            ln -sfn "$skill_path" "$target"
            echo "  ~ relinked: $name"
        else
            ln -s "$skill_path" "$target"
            echo "  + linked: $name"
        fi
    done
}

install_platform "$REPO_ROOT/claude/skills" "$HOME/.claude/skills" "Claude"
install_platform "$REPO_ROOT/codex/skills"  "$HOME/.codex/skills"  "Codex"

echo ""
echo "Done. Restart your CLI to pick up new skills."

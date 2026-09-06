#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
app_bundle="$repo_dir/../Codex Models.app"
destination="/Applications/Codex Models.app"

if [[ ! -d "$app_bundle" ]]; then
    print -u2 "Build the app first: bash build.sh"
    exit 1
fi

ditto --rsrc --extattr "$app_bundle" "$destination"
open "$destination"
print "Installed and launched $destination"

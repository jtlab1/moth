#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

subcommand="${1:-build}"
shift || true

flags=()
developer_dir="$(xcode-select -p 2>/dev/null || true)"

if [[ "$subcommand" == "test" && "$developer_dir" == *CommandLineTools* ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    if [[ -d "$frameworks/Testing.framework" ]]; then
        flags+=(
            -Xswiftc -F -Xswiftc "$frameworks"
            -Xlinker -F -Xlinker "$frameworks"
            -Xlinker -rpath -Xlinker "$frameworks"
            -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
        )
    else
        echo "warning: no Testing.framework under $frameworks; running unpatched" >&2
    fi
fi

# ${flags[@]+...} guards the expansion: macOS ships bash 3.2, where an empty
# array under `set -u` counts as unbound and would abort the build path.
exec swift "$subcommand" ${flags[@]+"${flags[@]}"} "$@"

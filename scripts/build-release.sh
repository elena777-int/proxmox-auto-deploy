#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-dist/proxmox-auto-deploy}

core_version=$(sed -nE 's/^SPETSNAZ_VERSION="([0-9]+\.[0-9]+\.[0-9]+)([ "]).*/\1/p' "$source_dir/core.sh")
menu_version=$(sed -nE 's/^MENU_VERSION="([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$source_dir/menu.sh")
if [[ ! "$core_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$core_version" != "$menu_version" ]]; then
    printf 'Версии core.sh и menu.sh должны совпадать: %s / %s\n' "$core_version" "$menu_version" >&2
    exit 1
fi

bash -n "$source_dir/core.sh"
bash -n "$source_dir/menu.sh"
mkdir -p -- "$(dirname -- "$output")"
tmp=$(mktemp -- "$output.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

{
    printf '#!/usr/bin/env bash\n'
    sed 's/^/# /; s/^# $/#/' "$source_dir/LICENSE"
    printf '\nif [[ ${1-} == --version ]]; then\n    echo "%s"\n    exit 0\nfi\n\n' "$core_version"
    cat <<'CORE_ENTRY'
if [[ ${1-} == --core ]]; then
    shift
CORE_ENTRY
    tail -n +2 "$source_dir/core.sh"
    cat <<'MENU_ENTRY'

    exit $?
fi

run_bundled_core() {
    bash "$0" --core "$@"
}

MENU_ENTRY
    tail -n +2 "$source_dir/menu.sh"
} > "$tmp"

bash -n "$tmp"
chmod 0755 "$tmp"
mv -f -- "$tmp" "$output"
printf '%s\n' "$output"

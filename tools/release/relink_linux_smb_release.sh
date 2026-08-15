#!/usr/bin/env bash
set -euo pipefail

kit_root="$(cd "$(dirname "$0")/.." && pwd)"
replacement_archive="${1:-$kit_root/lib/libstellar_libsmb2_private.a}"
output_binary="${2:-$kit_root/bin/stellar-media.relinked}"

if [[ ! -f "$replacement_archive" ]]; then
  echo "replacement private libsmb2 archive is unavailable: $replacement_archive" >&2
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required to relink the application object code" >&2
  exit 1
fi
mkdir -p "$(dirname "$output_binary")"
relink_temporary="$(mktemp -d "${TMPDIR:-/tmp}/stellar-smb-relink.XXXXXX")"
trap 'rm -rf -- "$relink_temporary"' EXIT

: >"$relink_temporary/objects.rsp"
while IFS= read -r object_path; do
  if [[ -z "$object_path" || ! -f "$kit_root/$object_path" ]]; then
    echo "relink object is unavailable: $object_path" >&2
    exit 1
  fi
  temporary_object="$relink_temporary/$(basename "$object_path")"
  ln -s "$kit_root/$object_path" "$temporary_object"
  printf '%s\n' "$temporary_object" >>"$relink_temporary/objects.rsp"
done <"$kit_root/metadata/objects.rsp"

cd "$kit_root"
swiftc \
  @"$relink_temporary/objects.rsp" \
  "$replacement_archive" \
  -Xlinker --gc-sections \
  -Xlinker --defsym \
  -Xlinker main=StellarMediaCLI_main \
  -Xlinker '-rpath=$ORIGIN' \
  -Xlinker "--exclude-libs=$(basename "$replacement_archive")" \
  -o "$output_binary"
echo "relinked executable: $output_binary"

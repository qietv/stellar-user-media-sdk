#!/usr/bin/env bash
set -euo pipefail

lock_path=""
install_prefix=""
source_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock)
      lock_path="$2"
      shift 2
      ;;
    --prefix)
      install_prefix="$2"
      shift 2
      ;;
    --source)
      source_path="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$lock_path" || -z "$install_prefix" ]]; then
  echo "usage: build_libsmb2_static_linux.sh --lock <path> --prefix <path> [--source <git-tree>]" >&2
  exit 2
fi

for command_name in cmake find git gzip nm objcopy pkg-config ranlib sha256sum tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "required build command is unavailable: $command_name" >&2
    exit 1
  fi
done

if [[ -e "$install_prefix" && ! -d "$install_prefix" ]]; then
  echo "private install prefix exists but is not a directory: $install_prefix" >&2
  exit 1
fi
if [[ -d "$install_prefix" ]] &&
  [[ -n "$(find "$install_prefix" -mindepth 1 -print -quit)" ]]; then
  echo "private install prefix must be empty: $install_prefix" >&2
  exit 1
fi

readarray -t lock_values < <(
  python3 - "$lock_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
print(payload["repository"])
print(payload["revision"])
print(payload["upstream_version"])
print(payload["archive"])
print(payload["pkg_config"])
print(payload["symbol_prefix"])
PY
)

repository="${lock_values[0]}"
revision="${lock_values[1]}"
upstream_version="${lock_values[2]}"
archive_name="${lock_values[3]}"
pkg_config_name="${lock_values[4]}"
symbol_prefix="${lock_values[5]}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/stellar-libsmb2-static.XXXXXX")"
trap 'rm -rf -- "$temporary_root"' EXIT
checkout_root="$temporary_root/checkout"

if [[ -n "$source_path" ]]; then
  checkout_root="$(cd "$source_path" && pwd)"
  if [[ ! -d "$checkout_root/.git" ]]; then
    echo "local libsmb2 source must be a Git working tree: $checkout_root" >&2
    exit 1
  fi
else
  mkdir -p "$checkout_root"
  git -C "$checkout_root" init --quiet
  git -C "$checkout_root" remote add origin "$repository"
  git -C "$checkout_root" fetch --quiet --depth 1 origin "$revision"
  git -C "$checkout_root" checkout --quiet --detach FETCH_HEAD
fi

actual_revision="$(git -C "$checkout_root" rev-parse HEAD)"
if [[ "$actual_revision" != "$revision" ]]; then
  echo "libsmb2 revision mismatch: expected $revision, received $actual_revision" >&2
  exit 1
fi

corresponding_source_tar="$temporary_root/libsmb2-$revision.tar"
git -C "$checkout_root" archive \
  --format=tar \
  --prefix="libsmb2-$revision/" \
  "$revision" >"$corresponding_source_tar"
mkdir -p "$temporary_root/source"
tar -xf "$corresponding_source_tar" -C "$temporary_root/source"
source_root="$temporary_root/source/libsmb2-$revision"

cmake \
  -S "$source_root" \
  -B "$source_root/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_LIBKRB5=OFF \
  -DENABLE_GSSAPI=OFF
cmake --build "$source_root/build" --parallel 2

raw_archive="$source_root/build/lib/libsmb2.a"
private_archive="$install_prefix/lib/$archive_name"
symbol_map="$source_root/symbol-map.txt"
defined_symbols="$source_root/defined-symbols.txt"

if [[ ! -f "$raw_archive" ]]; then
  echo "expected static archive was not built: $raw_archive" >&2
  exit 1
fi

mkdir -p "$install_prefix/lib/pkgconfig" "$install_prefix/include"
cmake -E copy_directory "$source_root/include/smb2" "$install_prefix/include/smb2"

nm -g --defined-only -P "$raw_archive" >"$defined_symbols"
python3 - "$symbol_prefix" "$symbol_map" "$defined_symbols" <<'PY'
import sys

prefix = sys.argv[1]
output_path = sys.argv[2]
input_path = sys.argv[3]
symbols = set()
with open(input_path, encoding="utf-8") as input_stream:
    for line in input_stream:
        parts = line.split()
        if len(parts) < 2 or len(parts[1]) != 1:
            continue
        if parts[1].upper() not in set("ABCDGIRSTVW"):
            continue
        symbol = parts[0]
        if symbol and not symbol.endswith(":"):
            symbols.add(symbol)
if "smb2_init_context" not in symbols or "smb2_pread" not in symbols:
    raise SystemExit("libsmb2 symbol map is missing required ABI symbols")
with open(output_path, "w", encoding="utf-8") as stream:
    for symbol in sorted(symbols):
        stream.write(f"{symbol} {prefix}{symbol}\n")
PY

objcopy --redefine-syms="$symbol_map" "$raw_archive" "$private_archive"
ranlib "$private_archive"

compliance_root="$install_prefix/share/stellar-libsmb2-private"
source_archive="$compliance_root/source/libsmb2-$revision.tar.gz"
mkdir -p "$compliance_root/licenses" "$compliance_root/source" "$compliance_root/build"
gzip -n -c "$corresponding_source_tar" >"$source_archive"
install -m 0644 "$source_root/COPYING" "$compliance_root/licenses/COPYING"
install -m 0644 \
  "$source_root/LICENCE-LGPL-2.1.txt" \
  "$compliance_root/licenses/LICENCE-LGPL-2.1.txt"
install -m 0644 "$symbol_map" "$compliance_root/build/symbol-map.txt"

python3 - \
  "$compliance_root/metadata.json" \
  "$repository" \
  "$revision" \
  "$upstream_version" \
  "$source_archive" \
  "$archive_name" \
  "$symbol_prefix" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
source_archive = Path(sys.argv[5])
payload = {
    "schema_version": 1,
    "component": "libsmb2",
    "repository": sys.argv[2],
    "revision": sys.argv[3],
    "upstream_version": sys.argv[4],
    "license": "LGPL-2.1-or-later",
    "source_archive": f"source/{source_archive.name}",
    "source_sha256": hashlib.sha256(source_archive.read_bytes()).hexdigest(),
    "private_archive": sys.argv[6],
    "symbol_prefix": sys.argv[7],
}
output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

private_pc="$install_prefix/lib/pkgconfig/$pkg_config_name.pc"
python3 - "$private_pc" "$install_prefix" "$upstream_version" "$archive_name" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
prefix = sys.argv[2]
version = sys.argv[3]
archive = sys.argv[4]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(
    f"""prefix={prefix}
libdir=${{prefix}}/lib
includedir=${{prefix}}/include

Name: stellar-libsmb2-private
Description: Project-private, symbol-prefixed static libsmb2
Version: {version}
Libs: -L${{libdir}} -lstellar_libsmb2_private
Cflags: -I${{includedir}}
""",
    encoding="utf-8",
)
PY

echo "built isolated static libsmb2 $revision into $private_archive"

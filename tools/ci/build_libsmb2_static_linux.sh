#!/usr/bin/env bash
set -euo pipefail

lock_path=""
install_prefix=""

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
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$lock_path" || -z "$install_prefix" ]]; then
  echo "usage: build_libsmb2_static_linux.sh --lock <path> --prefix <path>" >&2
  exit 2
fi

for command_name in cmake find git nm objcopy pkg-config ranlib; do
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
source_root="$(mktemp -d "${TMPDIR:-/tmp}/stellar-libsmb2-static.XXXXXX")"
trap 'rm -rf -- "$source_root"' EXIT

git -C "$source_root" init --quiet
git -C "$source_root" remote add origin "$repository"
git -C "$source_root" fetch --quiet --depth 1 origin "$revision"
git -C "$source_root" checkout --quiet --detach FETCH_HEAD

actual_revision="$(git -C "$source_root" rev-parse HEAD)"
if [[ "$actual_revision" != "$revision" ]]; then
  echo "libsmb2 revision mismatch: expected $revision, received $actual_revision" >&2
  exit 1
fi

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
Libs: -Wl,--exclude-libs,{archive} ${{libdir}}/{archive}
Cflags: -I${{includedir}}
""",
    encoding="utf-8",
)
PY

echo "built isolated static libsmb2 $revision into $private_archive"

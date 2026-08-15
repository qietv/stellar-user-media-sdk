#!/usr/bin/env bash
set -euo pipefail

lock_path=""
source_path=""
output_archive=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock)
      lock_path="$2"
      shift 2
      ;;
    --source)
      source_path="$2"
      shift 2
      ;;
    --output)
      output_archive="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$lock_path" || -z "$source_path" || -z "$output_archive" ]]; then
  echo "usage: rebuild_private_libsmb2.sh --lock <path> --source <path> --output <archive>" >&2
  exit 2
fi
if [[ ! -f "$lock_path" || ! -f "$source_path/CMakeLists.txt" ]]; then
  echo "lock or libsmb2 source tree is unavailable" >&2
  exit 1
fi
if [[ ! -d "$(dirname "$output_archive")" ]]; then
  echo "output archive parent directory must exist" >&2
  exit 1
fi

for command_name in cmake nm objcopy python3 ranlib; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "required build command is unavailable: $command_name" >&2
    exit 1
  fi
done

symbol_prefix="$(python3 - "$lock_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["symbol_prefix"])
PY
)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/stellar-libsmb2-relink.XXXXXX")"
trap 'rm -rf -- "$build_root"' EXIT

cmake \
  -S "$source_path" \
  -B "$build_root/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_LIBKRB5=OFF \
  -DENABLE_GSSAPI=OFF
cmake --build "$build_root/build" --parallel 2

raw_archive="$build_root/build/lib/libsmb2.a"
defined_symbols="$build_root/defined-symbols.txt"
symbol_map="$build_root/symbol-map.txt"
if [[ ! -f "$raw_archive" ]]; then
  echo "modified libsmb2 static archive was not built" >&2
  exit 1
fi

nm -g --defined-only -P "$raw_archive" >"$defined_symbols"
python3 - "$symbol_prefix" "$symbol_map" "$defined_symbols" <<'PY'
import sys

prefix, output_path, input_path = sys.argv[1:]
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
    raise SystemExit("modified libsmb2 is missing required ABI symbols")
with open(output_path, "w", encoding="utf-8") as stream:
    for symbol in sorted(symbols):
        stream.write(f"{symbol} {prefix}{symbol}\n")
PY

objcopy --redefine-syms="$symbol_map" "$raw_archive" "$output_archive"
ranlib "$output_archive"
install -m 0644 "$symbol_map" "${output_archive}.symbol-map.txt"
echo "rebuilt project-private libsmb2 archive: $output_archive"

#!/usr/bin/env bash
set -euo pipefail

lock_path=""
output_xcframework=""
source_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock)
      lock_path="$2"
      shift 2
      ;;
    --output)
      output_xcframework="$2"
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

if [[ -z "$lock_path" || -z "$output_xcframework" ]]; then
  echo "usage: build_libsmb2_xcframework_apple.sh --lock <path> --output <new.xcframework> [--source <git-tree>]" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Apple libsmb2 XCFramework builds require macOS and Xcode" >&2
  exit 1
fi
if [[ ! -f "$lock_path" ]]; then
  echo "libsmb2 lock is unavailable: $lock_path" >&2
  exit 1
fi
if [[ "$output_xcframework" != *.xcframework ]]; then
  echo "Apple libsmb2 output must end in .xcframework" >&2
  exit 1
fi

for command_name in cmake file git gzip install lipo nm python3 xcodebuild xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "required Apple build command is unavailable: $command_name" >&2
    exit 1
  fi
done

output_parent="$(dirname "$output_xcframework")"
output_name="$(basename "$output_xcframework")"
compliance_name="${output_name%.xcframework}.compliance"
output_compliance="$output_parent/$compliance_name"
if [[ -e "$output_xcframework" || -e "$output_compliance" ]]; then
  echo "Apple libsmb2 output and compliance paths must not already exist" >&2
  exit 1
fi
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd)"
output_xcframework="$output_parent/$output_name"
output_compliance="$output_parent/$compliance_name"
lock_path="$(cd "$(dirname "$lock_path")" && pwd)/$(basename "$lock_path")"

IFS=$'\t' read -r repository revision upstream_version symbol_prefix < <(
  python3 - "$lock_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
print(
    payload["repository"],
    payload["revision"],
    payload["upstream_version"],
    payload["symbol_prefix"],
    sep="\t",
)
PY
)

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/stellar-libsmb2-apple.XXXXXX")"
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
if [[ -n "$(git -C "$checkout_root" status --porcelain --untracked-files=no)" ]]; then
  echo "locked Apple libsmb2 source must not contain tracked modifications" >&2
  exit 1
fi

build_logged() {
  local log_path="$1"
  shift
  if ! "$@" >"$log_path" 2>&1; then
    tail -200 "$log_path" >&2
    return 1
  fi
}

built_archive=""
build_libsmb2() {
  local name="$1"
  local sdk="$2"
  local deployment_target="$3"
  local architectures="$4"
  local prefix_header="${5:-}"
  local build_root="$temporary_root/build-$name"
  local configure_log="$temporary_root/configure-$name.log"
  local build_log="$temporary_root/build-$name.log"
  local -a configure=(
    cmake
    -S "$checkout_root"
    -B "$build_root"
    -G Xcode
    -DCMAKE_BUILD_TYPE=Release
    "-DCMAKE_OSX_SYSROOT=$sdk"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target"
    "-DCMAKE_OSX_ARCHITECTURES=$architectures"
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DBUILD_SHARED_LIBS=OFF
    -DENABLE_EXAMPLES=OFF
    -DENABLE_LIBKRB5=OFF
    -DENABLE_GSSAPI=OFF
  )
  if [[ "$sdk" == iphoneos || "$sdk" == iphonesimulator ]]; then
    configure+=("-DCMAKE_SYSTEM_NAME=iOS")
  fi
  if [[ -n "$prefix_header" ]]; then
    configure+=("-DCMAKE_C_FLAGS=-include $prefix_header -fvisibility=hidden")
  fi

  echo "configuring libsmb2 $name" >&2
  build_logged "$configure_log" "${configure[@]}"
  echo "building libsmb2 $name" >&2
  build_logged "$build_log" cmake --build "$build_root" --config Release --parallel 2
  built_archive="$(find "$build_root/lib" -type f -name libsmb2.a -print -quit)"
  if [[ -z "$built_archive" || ! -f "$built_archive" ]]; then
    echo "libsmb2 $name archive was not produced" >&2
    exit 1
  fi
}

# Darwin does not ship GNU objcopy. Build one native archive to enumerate every
# global identifier, then force-include a generated rename header for all final
# Apple slices. This prefixes definitions and all internal references at compile
# time instead of post-processing Mach-O object files.
build_libsmb2 "macos-symbol-probe" macosx 14.0 "arm64;x86_64"
raw_macos_archive="$built_archive"
raw_symbols="$temporary_root/raw-symbols.txt"
xcrun nm -arch arm64 -gjU "$raw_macos_archive" >"$temporary_root/raw-nm.txt" 2>/dev/null
python3 - "$temporary_root/raw-nm.txt" "$raw_symbols" <<'PY'
from pathlib import Path
import re
import sys

symbols = {
    line.removeprefix("_")
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
}
symbols = sorted(symbol for symbol in symbols if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", symbol))
required = {"smb2_init_context", "smb2_pread"}
if not required.issubset(symbols):
    raise SystemExit("Apple symbol probe is missing required libsmb2 ABI symbols")
Path(sys.argv[2]).write_text("\n".join(symbols) + "\n", encoding="utf-8")
PY

prefix_header="$temporary_root/stellar-libsmb2-prefix-all.h"
symbol_map="$temporary_root/symbol-map.txt"
python3 - "$raw_symbols" "$prefix_header" "$symbol_map" "$symbol_prefix" <<'PY'
from pathlib import Path
import sys

symbols = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
prefix = sys.argv[4]
header = [
    "#ifndef STELLAR_LIBSMB2_PREFIX_ALL_H",
    "#define STELLAR_LIBSMB2_PREFIX_ALL_H",
]
mapping = []
for symbol in symbols:
    header.append(f"#define {symbol} {prefix}{symbol}")
    mapping.append(f"{symbol} {prefix}{symbol}")
header.append("#endif")
Path(sys.argv[2]).write_text("\n".join(header) + "\n", encoding="utf-8")
Path(sys.argv[3]).write_text("\n".join(mapping) + "\n", encoding="utf-8")
PY

build_libsmb2 "macos" macosx 14.0 "arm64;x86_64" "$prefix_header"
macos_libsmb2="$built_archive"
build_libsmb2 "iphoneos" iphoneos 17.0 arm64 "$prefix_header"
iphoneos_libsmb2="$built_archive"
build_libsmb2 "iphonesimulator" iphonesimulator 17.0 "arm64;x86_64" "$prefix_header"
iphonesimulator_libsmb2="$built_archive"

verify_prefixed_archive() {
  local archive="$1"
  shift
  local architecture
  for architecture in "$@"; do
    local nm_output="$temporary_root/nm-$(basename "$(dirname "$archive")")-$architecture.txt"
    xcrun nm -arch "$architecture" -gjU "$archive" >"$nm_output" 2>/dev/null
    python3 - "$nm_output" "$symbol_prefix" <<'PY'
from pathlib import Path
import re
import sys

prefix = sys.argv[2]
symbols = {
    line.removeprefix("_")
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
}
symbols = sorted(symbol for symbol in symbols if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", symbol))
unprefixed = [symbol for symbol in symbols if not symbol.startswith(prefix)]
if unprefixed:
    raise SystemExit("Apple libsmb2 archive exports unprefixed symbols: " + ", ".join(unprefixed[:10]))
required = {prefix + "smb2_init_context", prefix + "smb2_pread"}
if not required.issubset(symbols):
    raise SystemExit("Apple libsmb2 archive is missing required prefixed symbols")
PY
  done
}

verify_prefixed_archive "$macos_libsmb2" arm64 x86_64
verify_prefixed_archive "$iphoneos_libsmb2" arm64
verify_prefixed_archive "$iphonesimulator_libsmb2" arm64 x86_64

repository_root="$(cd "$(dirname "$lock_path")/.." && pwd)"
wrapper_source="$repository_root/platforms/swift/Sources/CStellarSMB2Wrapper/stellar_smb2_wrapper.c"
wrapper_include="$repository_root/platforms/swift/Sources/CStellarSMB2Wrapper/include"
private_shim_include="$repository_root/platforms/swift/Sources/CStellarLibsmb2Private"
if [[ ! -f "$wrapper_source" || ! -f "$wrapper_include/stellar_smb2_wrapper.h" ]]; then
  echo "project-owned SMB2 wrapper sources are unavailable" >&2
  exit 1
fi

combined_archive=""
combine_wrapper() {
  local name="$1"
  local sdk="$2"
  local deployment_flag="$3"
  local architectures="$4"
  local libsmb2_archive="$5"
  local slice_root="$temporary_root/slice-$name"
  local wrapper_object="$slice_root/stellar_smb2_wrapper.o"
  mkdir -p "$slice_root"
  local -a compile=(
    xcrun --sdk "$sdk" clang
    -std=c11
    -O2
    -fPIC
    -fvisibility=hidden
    -fno-common
    "$deployment_flag"
    -I "$wrapper_include"
    -I "$private_shim_include"
    -I "$checkout_root/include"
    -c "$wrapper_source"
    -o "$wrapper_object"
  )
  local architecture
  IFS=';' read -r -a architecture_values <<<"$architectures"
  for architecture in "${architecture_values[@]}"; do
    compile+=( -arch "$architecture" )
  done
  "${compile[@]}"
  combined_archive="$slice_root/libCStellarSMB2Wrapper.a"
  xcrun libtool -static -D -o "$combined_archive" "$wrapper_object" "$libsmb2_archive"
}

combine_wrapper macos macosx -mmacosx-version-min=14.0 "arm64;x86_64" "$macos_libsmb2"
macos_combined="$combined_archive"
combine_wrapper iphoneos iphoneos -miphoneos-version-min=17.0 arm64 "$iphoneos_libsmb2"
iphoneos_combined="$combined_archive"
combine_wrapper iphonesimulator iphonesimulator -mios-simulator-version-min=17.0 \
  "arm64;x86_64" "$iphonesimulator_libsmb2"
iphonesimulator_combined="$combined_archive"

headers_root="$temporary_root/Headers"
mkdir -p "$headers_root"
install -m 0644 "$wrapper_include/stellar_smb2_wrapper.h" "$headers_root/"
python3 - "$headers_root/module.modulemap" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    "module CStellarSMB2Wrapper {\n"
    "  umbrella header \"stellar_smb2_wrapper.h\"\n"
    "  export *\n"
    "}\n",
    encoding="utf-8",
)
PY

staged_xcframework="$temporary_root/$output_name"
xcodebuild -create-xcframework \
  -library "$macos_combined" -headers "$headers_root" \
  -library "$iphoneos_combined" -headers "$headers_root" \
  -library "$iphonesimulator_combined" -headers "$headers_root" \
  -output "$staged_xcframework" >/dev/null

staged_compliance="$temporary_root/$compliance_name"
mkdir -p \
  "$staged_compliance/source" \
  "$staged_compliance/licenses" \
  "$staged_compliance/build" \
  "$staged_compliance/integration"
corresponding_source_tar="$temporary_root/libsmb2-$revision.tar"
git -C "$checkout_root" archive \
  --format=tar \
  --prefix="libsmb2-$revision/" \
  "$revision" >"$corresponding_source_tar"
gzip -n -c "$corresponding_source_tar" \
  >"$staged_compliance/source/libsmb2-$revision.tar.gz"
install -m 0644 "$checkout_root/COPYING" "$staged_compliance/licenses/COPYING"
install -m 0644 \
  "$checkout_root/LICENCE-LGPL-2.1.txt" \
  "$staged_compliance/licenses/LICENCE-LGPL-2.1.txt"
install -m 0644 "$prefix_header" "$staged_compliance/build/stellar-libsmb2-prefix-all.h"
install -m 0644 "$symbol_map" "$staged_compliance/build/symbol-map.txt"
install -m 0644 "$lock_path" "$staged_compliance/build/libsmb2.lock.json"
install -m 0644 "$wrapper_source" "$staged_compliance/integration/stellar_smb2_wrapper.c"
install -m 0644 \
  "$wrapper_include/stellar_smb2_wrapper.h" \
  "$staged_compliance/integration/stellar_smb2_wrapper.h"
install -m 0644 \
  "$private_shim_include/shim.h" \
  "$staged_compliance/integration/stellar_libsmb2_private_shim.h"
install -m 0755 "$0" "$staged_compliance/build/build_libsmb2_xcframework_apple.sh"

python3 - \
  "$staged_compliance/metadata.json" \
  "$repository" \
  "$revision" \
  "$upstream_version" \
  "$symbol_prefix" \
  "$staged_compliance/source/libsmb2-$revision.tar.gz" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

source = Path(sys.argv[6])
payload = {
    "schema_version": 1,
    "component": "libsmb2",
    "repository": sys.argv[2],
    "revision": sys.argv[3],
    "upstream_version": sys.argv[4],
    "license": "LGPL-2.1-or-later",
    "symbol_prefix": sys.argv[5],
    "source_archive": f"source/{source.name}",
    "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "platforms": {
        "macos": {"minimum_version": "14.0", "architectures": ["arm64", "x86_64"]},
        "ios": {"minimum_version": "17.0", "architectures": ["arm64"]},
        "ios-simulator": {
            "minimum_version": "17.0",
            "architectures": ["arm64", "x86_64"],
        },
    },
}
Path(sys.argv[1]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 - "$staged_compliance" <<'PY'
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1])
manifest = root / "SHA256SUMS"
lines = []
for path in sorted(root.rglob("*")):
    if path.is_file() and path != manifest:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {path.relative_to(root).as_posix()}")
manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

mv "$staged_xcframework" "$output_xcframework"
mv "$staged_compliance" "$output_compliance"
echo "built Apple libsmb2 XCFramework: $output_xcframework"
echo "wrote LGPL source/build materials: $output_compliance"

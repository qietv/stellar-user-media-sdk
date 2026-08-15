#!/usr/bin/env bash
set -euo pipefail

repository_root=""
package_root=""
libsmb2_prefix=""
output_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      repository_root="$2"
      shift 2
      ;;
    --package-root)
      package_root="$2"
      shift 2
      ;;
    --libsmb2-prefix)
      libsmb2_prefix="$2"
      shift 2
      ;;
    --output)
      output_root="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$repository_root" || -z "$package_root" || -z "$libsmb2_prefix" ||
  -z "$output_root" ]]; then
  echo "usage: create_linux_smb_lgpl_kit.sh --root <repo> --package-root <swift-package> --libsmb2-prefix <prefix> --output <new-directory>" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "the Linux SMB relink kit must be created on Linux" >&2
  exit 1
fi
if [[ -e "$output_root" ]]; then
  echo "LGPL kit output must not already exist: $output_root" >&2
  exit 1
fi

repository_root="$(cd "$repository_root" && pwd)"
package_root="$(cd "$package_root" && pwd)"
libsmb2_prefix="$(cd "$libsmb2_prefix" && pwd)"
compliance_root="$libsmb2_prefix/share/stellar-libsmb2-private"
private_archive="$libsmb2_prefix/lib/libstellar_libsmb2_private.a"
for required_file in \
  "$compliance_root/metadata.json" \
  "$compliance_root/licenses/COPYING" \
  "$compliance_root/licenses/LICENCE-LGPL-2.1.txt" \
  "$private_archive"; do
  if [[ ! -f "$required_file" ]]; then
    echo "required LGPL input is unavailable: $required_file" >&2
    exit 1
  fi
done

source_relative="$(python3 - "$compliance_root/metadata.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["source_archive"])
PY
)"
source_archive="$compliance_root/$source_relative"
if [[ ! -f "$source_archive" ]]; then
  echo "complete corresponding libsmb2 source is unavailable: $source_archive" >&2
  exit 1
fi

bin_path="$(cd "$package_root" && swift build -c release --show-bin-path)"
binary="$bin_path/stellar-media"
link_file_list="$bin_path/stellar-media.product/Objects.LinkFileList"
if [[ ! -x "$binary" || ! -f "$link_file_list" ]]; then
  echo "release binary or SwiftPM object list is unavailable; run swift build -c release first" >&2
  exit 1
fi

mkdir -p \
  "$output_root/bin" \
  "$output_root/lib" \
  "$output_root/licenses" \
  "$output_root/metadata" \
  "$output_root/objects" \
  "$output_root/project" \
  "$output_root/scripts" \
  "$output_root/source"

install -m 0755 "$binary" "$output_root/bin/stellar-media.original"
install -m 0644 "$private_archive" "$output_root/lib/libstellar_libsmb2_private.a"
install -m 0644 "$compliance_root/licenses/COPYING" "$output_root/licenses/libsmb2-COPYING"
install -m 0644 \
  "$compliance_root/licenses/LICENCE-LGPL-2.1.txt" \
  "$output_root/licenses/LGPL-2.1.txt"
install -m 0644 "$compliance_root/metadata.json" "$output_root/metadata/libsmb2.json"
install -m 0644 "$repository_root/third_party/libsmb2.lock.json" \
  "$output_root/metadata/libsmb2.lock.json"
install -m 0644 "$source_archive" "$output_root/source/$(basename "$source_archive")"
install -m 0755 "$repository_root/tools/release/rebuild_private_libsmb2.sh" \
  "$output_root/scripts/rebuild-private-libsmb2.sh"
install -m 0755 "$repository_root/tools/release/relink_linux_smb_release.sh" \
  "$output_root/scripts/relink.sh"

tar -C "$repository_root" -czf "$output_root/project/smb-integration-source.tar.gz" \
  third_party/libsmb2.lock.json \
  tools/ci/build_libsmb2_static_linux.sh \
  tools/release/rebuild_private_libsmb2.sh \
  platforms/swift/Package.swift \
  platforms/swift/Sources/CStellarLibsmb2Private/module.modulemap \
  platforms/swift/Sources/CStellarLibsmb2Private/shim.h \
  platforms/swift/Sources/CStellarSMB2Wrapper/include/stellar_smb2_wrapper.h \
  platforms/swift/Sources/CStellarSMB2Wrapper/stellar_smb2_wrapper.c

object_index=0
: >"$output_root/metadata/objects.rsp"
while IFS= read -r object_path; do
  object_path="${object_path#\"}"
  object_path="${object_path%\"}"
  if [[ -z "$object_path" ]]; then
    continue
  fi
  if [[ "$object_path" != /* ]]; then
    object_path="$package_root/$object_path"
  fi
  if [[ ! -f "$object_path" ]]; then
    echo "SwiftPM object is unavailable: $object_path" >&2
    exit 1
  fi
  object_index=$((object_index + 1))
  object_name="$(printf '%04d-%s' "$object_index" "$(basename "$object_path")")"
  install -m 0644 "$object_path" "$output_root/objects/$object_name"
  printf 'objects/%s\n' "$object_name" >>"$output_root/metadata/objects.rsp"
done <"$link_file_list"
if [[ "$object_index" -eq 0 ]]; then
  echo "SwiftPM release object list is empty" >&2
  exit 1
fi

python3 - \
  "$output_root/metadata/kit.json" \
  "$output_root/metadata/libsmb2.json" \
  "$object_index" <<'PY'
import json
from pathlib import Path
import platform
import subprocess
import sys

output = Path(sys.argv[1])
component = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
swift_version = subprocess.run(
    ["swiftc", "--version"], check=True, capture_output=True, text=True
).stdout.splitlines()[0]
payload = {
    "schema_version": 1,
    "artifact": "stellar-linux-smb-lgpl-relink-kit",
    "architecture": platform.machine(),
    "object_count": int(sys.argv[3]),
    "swift_toolchain": swift_version,
    "libsmb2_revision": component["revision"],
    "libsmb2_license": component["license"],
}
output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 - "$output_root/README.md" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    """# Stellar Linux SMB LGPL relink kit

This kit accompanies a Linux `stellar-media` executable that statically links
the LGPL-2.1-or-later libsmb2 client library. It is not a replacement for the
product's license notice or legal review.

Contents:

- `licenses/`: upstream copyright notice and LGPL 2.1 text.
- `source/`: complete corresponding source for the pinned libsmb2 revision.
- `project/`: project integration, wrapper, build and symbol-prefix sources.
- `objects/`: application object code used for the combined executable.
- `lib/`: the originally linked, project-prefixed libsmb2 static archive.
- `scripts/`: reproducible private-library rebuild and executable relink tools.
- `manifest.json`: SHA-256 integrity inventory for every delivered file.

To relink with an unmodified archive:

```sh
./scripts/relink.sh ./lib/libstellar_libsmb2_private.a ./bin/stellar-media.relinked
```

To relink with a modified compatible libsmb2:

```sh
mkdir modified-libsmb2
tar -xzf source/libsmb2-*.tar.gz -C modified-libsmb2 --strip-components=1
# Edit modified-libsmb2 as desired.
./scripts/rebuild-private-libsmb2.sh \\
  --lock metadata/libsmb2.lock.json \\
  --source modified-libsmb2 \\
  --output lib/libstellar_libsmb2_modified.a
./scripts/relink.sh lib/libstellar_libsmb2_modified.a bin/stellar-media.modified
```

Use the Swift toolchain family recorded in `metadata/kit.json`. The rebuilt
library must preserve the public libsmb2 ABI used by the wrapper. Installation,
code-signing and product terms must not prevent modification or debugging rights
granted by LGPL 2.1.
""",
    encoding="utf-8",
)
PY

"$output_root/scripts/relink.sh" \
  "$output_root/lib/libstellar_libsmb2_private.a" \
  "$output_root/bin/stellar-media.relinked"

python3 - "$output_root" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = {}
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name != "manifest.json":
        files[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
payload = {"schema_version": 1, "algorithm": "SHA-256", "files": files}
(root / "manifest.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

python3 "$repository_root/tools/release/check_linux_smb_lgpl_kit.py" \
  --kit "$output_root" \
  --verify-rebuild
echo "created verified Linux SMB LGPL relink kit: $output_root"

#!/usr/bin/env python3
"""Exercise Apple's native SMB paging against an isolated loopback Impacket fixture.

Optional test dependency: impacket==0.13.1, installed in a disposable virtualenv.
No NAS, system sharing configuration, real credentials, or SDK dependency is required.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import threading


def main() -> int:
    from impacket import ntlm, smb3structs, smbserver

    package = Path(__file__).resolve().parents[2] / "platforms/swift"
    with tempfile.TemporaryDirectory(prefix="stellar-smb-paging-") as temporary:
        root = Path(temporary)
        for index in reversed(range(1200)):
            (root / f"Video-{index:04}.mkv").write_bytes(b"0123456789")
        (root / "Nested").mkdir()
        (root / "Nested/Unicode-中文.mkv").write_bytes(b"abcdefghij")
        server = smbserver.SimpleSMBServer(listenAddress="127.0.0.1", listenPort=0)
        server.addShare("fixture", str(root), readOnly="yes")
        server.addCredential("fixture", 0, ntlm.compute_lmhash("fixture"), ntlm.compute_nthash("fixture"))
        server.setSMB2Support(True)
        raw = server.getServer()
        query_count = 0
        maximum_bytes = 0

        def query(connection, instance, packet):
            nonlocal query_count, maximum_bytes
            request = smb3structs.SMB2QueryDirectory(packet["Data"])
            query_count += 1
            maximum_bytes = max(maximum_bytes, request["OutputBufferLength"])
            return original(connection, instance, packet)

        original = raw.hookSmb2Command(smb3structs.SMB2_QUERY_DIRECTORY, query)
        thread = threading.Thread(target=raw.serve_forever, daemon=True)
        thread.start()
        environment = dict(os.environ, STELLAR_SMB_PAGING_TEST_PORT=str(raw.server_address[1]))
        try:
            result = subprocess.run(
                ["swift", "test", "--build-system", "native", "--filter", "AppleSMB2TransportTests"],
                cwd=package, env=environment, check=False,
            )
        finally:
            raw.shutdown()
            raw.server_close()
            thread.join(timeout=5)
        if result.returncode:
            return result.returncode
        if query_count < 4 or not 0 < maximum_bytes <= 65_536:
            raise RuntimeError("SMB fixture did not exercise bounded native directory queries")
        print(f"SMB fixture passed: {query_count} QUERY_DIRECTORY requests; maximum buffer {maximum_bytes} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

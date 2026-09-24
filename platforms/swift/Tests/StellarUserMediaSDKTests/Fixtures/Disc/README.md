# Self-made optical-disc fixtures

`minimal-bdmv.iso` contains only synthetic control bytes and zero-value test stream data. It has no
commercial media content. It exercises UDF block access, multiple MPLS files, duplicate-playlist
elimination, and largest-playlist selection. PLAYLIST also contains a 17,024-byte numeric text
file and an AppleDouble-style sidecar; neither may be interpreted as an MPLS playlist.

Regenerate it on macOS with:

```sh
swift generate-fixtures.swift
```

The committed image is checked by the SDK test before it is parsed. Its SHA-256 is recorded in
`minimal-bdmv.iso.sha256` so accidental fixture changes fail loudly. `hdiutil` writes generation
metadata into the image, so a deliberate regeneration also refreshes that sidecar hash.

The two real-NAS metrics tests are opt-in and skip unless their environment is configured:

```sh
STELLAR_TEST_SMB_SERVER=nas.example.test \
STELLAR_TEST_SMB_SHARE=Media \
STELLAR_TEST_SMB_USERNAME=test-user \
STELLAR_TEST_SMB_PASSWORD='provided-out-of-band' \
STELLAR_TEST_SMB_IMAGE_PATH='Discs/example.iso' \
STELLAR_TEST_SMB_DIRECTORY_PATH='Discs/example-bdmv' \
swift test --filter 'realSMB.*ProbeMetrics'
```

Run those tests serially (the suite enforces this) so the request and RSS measurements are not
contaminated by a second SMB probe.

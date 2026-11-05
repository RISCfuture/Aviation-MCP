# Linux library verification

The first six library targets built successfully in release mode on 2026-10-28 using
Swift 6.4.1 in a Linux aarch64 container. These results establish library-target
compilation, not runtime correctness, full test-suite compatibility or server
compatibility.

Image: `swift:6.4.1-noble`

Digest: `sha256:6304481cf2717966b7ba175162e397ea2f2cc3161909f2b2a5cf40036079a0f7`

| Library | Revision | Result |
| --- | --- | --- |
| SwiftNASR | `a4d56cc686e148460a200eeff5751c2beed36847` | Pass |
| SwiftCIFP | `d57301f98db1b850b9c57d823c7f7dcf996fc730` | Pass |
| SwiftDOF | `5afe24c34e7ee72c9f31ae8ac23e754bc6ba1217` | Pass |
| SwiftACD | `2d01856fb7b78b11fe614e01b5c4c4483add09f6` | Pass |
| SwiftMETAR | `649e70912e0c1cc21c275545bd26af126bd79326` | Pass |
| SwiftGeographic | `5b166c0730dc3dd7ba85242ab2696556202d73a9` | Pass |

Command: `scripts/verify-linux-libraries.sh`, with a worker-specific
`VERIFICATION_OUTPUT` directory under `.build/`.

SF50-Performance and MeasurementKit were verified separately on 2026-11-04 at
their `Package.resolved` revisions, with the same release-mode target build in
a Linux aarch64 container using Swift 6.4.2 (image `swift:6.4-noble`, digest
`sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0`).
Both builds completed with exit code zero.

| Library | Revision | Result |
| --- | --- | --- |
| SF50-Performance 1.0.0 | `49cdd9111fbc7dffbec6bbf8f9411b8c82aee679` | Pass |
| MeasurementKit 1.2.1 | `20c908d2ccefc152dfdc646f9b71b10e8f635822` | Pass |

The server image built from these pins passes `scripts/smoke-test-image.sh` and
contains `SF50Performance_SF50Performance.resources` beside the binary. The
smoke test starts the server with the `performance` group but does not call its
tools.

The script lists each library as owner, repository and target, and takes a
repository name to build only that library, such as
`scripts/verify-linux-libraries.sh SF50-Performance`. It also builds
`SF50-TOLD/SF50-Performance` (target `SF50Performance`) and
`RISCfuture/MeasurementKit`.

Upstream warnings included unsupported processing of string catalogs on Linux,
unnecessary `unsafe` markers, ZIPFoundation deployment-target deprecations and an
unused SwiftMETAR package dependency. Builds completed with exit code zero;
warning-free compatibility is not claimed.

The server also passed all 36 Swift Testing cases against PostGIS in Linux
release mode and on macOS with these revisions. Full-distribution CIFP staging
encounters one rejected record in cycle 2610 and three in 2611. The server
retains usable records and reports those gaps; build success does not establish
complete navigation coverage.

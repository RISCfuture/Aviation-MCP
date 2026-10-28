# Linux library verification

All six library targets built successfully in release mode on 2026-10-28 using
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

Upstream warnings included unsupported processing of string catalogs on Linux,
unnecessary `unsafe` markers, ZIPFoundation deployment-target deprecations and an
unused SwiftMETAR package dependency. Builds completed with exit code zero;
warning-free compatibility is not claimed.

The server also passed all 36 Swift Testing cases against PostGIS in Linux
release mode and on macOS with these revisions. Full-distribution CIFP staging
still rejects one record in cycle 2610 and three in 2611; build success does
not establish complete navigation coverage.

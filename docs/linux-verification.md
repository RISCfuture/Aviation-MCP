# Linux library verification

All six library targets built successfully in release mode on 2026-10-28 using
Swift 6.4.1 in a Linux aarch64 container. These results establish library-target
compilation, not runtime correctness, full test-suite compatibility or server
compatibility.

Image: `swift:6.4.1-noble`

Digest: `sha256:6304481cf2717966b7ba175162e397ea2f2cc3161909f2b2a5cf40036079a0f7`

| Library | Revision | Result |
| --- | --- | --- |
| SwiftNASR | `43793427d3ff4cac842981405a38aad62bb15e57` | Pass |
| SwiftCIFP | `e80a87c3b8edba9cd60ad00bf69b1aa4e164af46` | Pass |
| SwiftDOF | `5630d134e371347c5302f0d0b17440103dbacbf8` | Pass |
| SwiftACD | `9c70df543447d3c886211aa3669fead87ce41258` | Pass |
| SwiftMETAR | `0e7d39936dd0d4c8b3c4f78d09e1a908648fc647` | Pass |
| SwiftGeographic | `49fad28c575a8efd6e8a154fdf579982d2eeebf9` | Pass |

Command: `scripts/verify-linux-libraries.sh`, with a worker-specific
`VERIFICATION_OUTPUT` directory under `.build/`.

Upstream warnings included unsupported processing of string catalogs on Linux,
unnecessary `unsafe` markers, ZIPFoundation deployment-target deprecations and an
unused SwiftMETAR package dependency. Builds completed with exit code zero;
warning-free compatibility is not claimed.

# Third-party notices

Complete notices are retained in `LICENSES/` and copied into every app package by `scripts/build-app.sh`. `LICENSES/sources.json` records their pinned upstream locations. This includes dependencies compiled into the semantic helper.

| Project / component | License file |
| --- | --- |
| Oil Find public core — Copyright (c) 2026 Lin Zhihuang | [MIT](LICENSES/Oil-Find-MIT.txt) |
| DigUp — Copyright (c) 2026 Abdur Rahim | [MIT](LICENSES/DigUp-MIT.txt) |
| llama.cpp — Copyright (c) 2023–2026 The ggml authors | [MIT](LICENSES/llama.cpp-MIT.txt) |
| nlohmann/json bundled with llama.cpp | [MIT](LICENSES/llama.cpp-json-MIT.txt) |
| rotate-bits bundled with llama.cpp | [MIT](LICENSES/llama.cpp-hash-rotate.txt) |
| SHA-256 bundled with llama.cpp | [Public-domain notice](LICENSES/llama.cpp-hash-sha256.txt) |
| xxHash bundled with llama.cpp | [BSD 2-Clause](LICENSES/llama.cpp-hash-xxhash.txt) |

DigUp-derived material includes `Sources/LlamaRuntime/`, the CLlama module map, `Sources/FoxFindSemanticCore/ModelFiles.swift`, the llama build script and patch, and image fixtures in `Tests/LocalFindContentTests/Fixtures/`. Integration changes and surrounding Fox Find code are not attributed to DigUp.

## Optional model download

Weights are **not included** in source or application archives. Download starts only when the user selects Download Local Models in Settings.

- Original: [Google EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2), published as Apache-2.0.
- Distribution: [ggml-org/embeddinggemma-2-GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/tree/bfcd298762cc34d0357ece5ebdd31791a3a374d8).
- Revision: `bfcd298762cc34d0357ece5ebdd31791a3a374d8`.
- File names, sizes and SHA-256 checks: `Sources/FoxFindSemanticCore/ModelFiles.swift`.
- Text + media download: 864,676,480 bytes (about 865 MB).

Their license is separate from Fox Find's MIT license. If you redistribute weights yourself, retain their applicable license and notices too.

AppKit, SwiftUI, Vision, PDFKit, SQLite and other OS frameworks are supplied by macOS. This build does not bundle copies of macOS system frameworks.

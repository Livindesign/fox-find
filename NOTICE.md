# Fox Find — provenance and attribution

Fox Find is an independently maintained derivative of the **MIT-licensed public Oil Find core**, not an official Oil Find product.

| Component | Origin and pinned revision | License / changes |
| --- | --- | --- |
| Filename index, C matching engine, pinyin, filesystem events, much of the native app foundation | [Oil Find](https://github.com/oil-oil/oil-find/tree/36559e11812d65df01ffd0de132ba1a9a278701d) — Lin Zhihuang | MIT; retained and modified for Fox Find |
| Local AI conversation source adapters, compressed search index and incremental scheduling | [Oil Find](https://github.com/oil-oil/oil-find/tree/e63c7150ccbd401a1375c08215d1386b56dd9471) — Lin Zhihuang | MIT; adapted with separate storage, opt-in controls, content extraction and native Fox Find UI |
| Selected embedding runtime sources, model descriptors, build script/patch, two image test fixtures | [DigUp](https://github.com/ARahim3/DigUp/tree/ec28973268b81f836be72187ff23b3a16ef4fd97) — Abdur Rahim | MIT; adapted into the Fox Find app and helper |
| Local inference library, built separately | [llama.cpp](https://github.com/ggml-org/llama.cpp/tree/4d756bc72bf00a4aacf410ae15a2d315f3db400d) — ggml authors and contributors | MIT, plus bundled dependency notices; pinned build with included patch |
| Fox Find integration, content indexing, interface changes, branding and documentation | Livindesign and contributors | MIT, subject to the notices above |

Original copyright and permission notices are preserved in `LICENSE` and `LICENSES/`, and included in application packages. See `THIRD-PARTY-NOTICES.md`. Internal `OilFind*` module names retain their upstream origin.

The proprietary Oil Find Pro module and vendor application binaries are **not** part of this repository or its builds. Fox Find's content-search features are a separate implementation. Similar features do not imply identical behavior, compatibility or endorsement. Fox Find does not change Oil Find's activation or license state. Each app has its own data and application identity.

Oil Find, DigUp and their authors do not endorse or operate this fork. Their names identify provenance; this notice makes no claim to their trademarks.

Optional model weights are a separate download, not covered by this project's MIT license. The selected EmbeddingGemma 2 model is published by Google under Apache-2.0; see the model card and pinned GGUF repository in THIRD-PARTY-NOTICES.md.

Any future sponsorship supports **this fork's maintainer** unless an entry explicitly says otherwise. It is not a payment to, license from, or support contract with upstream projects. Please consider supporting them directly too.

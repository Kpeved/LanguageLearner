# CoreML Multilingual Sentence Embeddings for Paragraph Alignment

Status: proposed (planning). Supersedes the `NLContextualEmbedding`-backed embedding path in `Alignment`.

## Problem

Tapping a target (e.g. Spanish) paragraph highlights the wrong native (English) paragraph when the two books split text at different granularities (1 paragraph here = 5 paragraphs there). The fix is a real per-paragraph alignment table, which requires good cross-lingual paragraph embeddings.

The current provider (`NLContextualEmbeddingProvider`) fails for two reasons:

1. **Wrong tool.** `NLContextualEmbedding` is a contextual *token feature extractor*, not a sentence-similarity model. Mean-pooling its token vectors is a weak cross-lingual signal, so Needleman-Wunsch drifts back toward proportional behavior.
2. **Fragile delivery.** Its model is downloaded over-the-air and compiled on-device. On the simulator `load()` fails with "Embedding model requires compilation".

## Goal

Replace the embedding source with a bundled CoreML **multilingual sentence encoder** that:

- Is purpose-built for cross-lingual sentence similarity (translations land near each other).
- Runs on simulator and device, fully offline.
- Drops in behind the existing `EmbeddingProvider` protocol so `NeedlemanWunsch`, `ParagraphAlignmentTable`, the diagnostics layer, and `LibraryStore` are unchanged.

Non-goals: changing the alignment algorithm, the storage format of the table, or the diagnostics UI (all already built).

## Model

`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`.

| Property | Value (verify against the model card at impl time) |
|---|---|
| Architecture | MiniLM (BERT-family), 12 layers, hidden 384 |
| Tokenizer | XLM-RoBERTa SentencePiece (Unigram), vocab ~250k, fairseq id offset |
| Output dim | 384 |
| Pooling | mean pooling over token embeddings, attention-mask weighted |
| Max sequence | 128 tokens |
| Languages | 50+, cross-lingually aligned |

Size note: the 250k-row embedding table dominates parameter count (~117M params total). fp32 ~470 MB, fp16 ~235 MB, int8 ~120 MB. **Quantization to int8 (or palettization) is required** to keep the footprint reasonable. This size drives the storage decision below.

Single model for both languages: unlike `NLContextualEmbedding` (one model per language), one multilingual encoder embeds both source and target. `buildTable` constructs **one** provider and uses it for both sides; the BCP-47 language tags become irrelevant to embedding.

## Storage strategy (decision required)

A ~120 MB binary cannot go into git as-is (no git-lfs on this machine).

- **A. Bundle as a package resource, tracked with Git LFS.** True offline-on-install; simplest runtime. Requires `brew install git-lfs && git lfs install` and tracking `*.mlpackage`/`*.mlmodelc`. Repo and app bundle both grow ~120 MB.
- **B. Download-on-first-launch.** Ship no model in git/bundle; on first import, download the converted model from a URL (our host or a release asset), store under `<AppSupport>/Models/`, compile with `MLModel.compileModel(at:)`, reuse thereafter. Keeps repo/bundle small; needs one network round-trip once (offline after). This mirrors `NLContextualEmbedding`'s OTA model but under our control and without the simulator compile bug.
- **C. Bundle, kept out of git.** A `make model` script downloads+converts into a gitignored resources path; CI and collaborators must run it. Fragile.

Recommendation: **B (download-on-first-launch)** given the size and the absence of git-lfs, with a `ModelStore` that exposes a compiled-model URL and reports progress through the existing `AlignmentDiagnostics` ("downloading model"). Fall back to **A** only if a strict offline-on-install guarantee is required, in which case we add a git-lfs setup step. This is the one decision to confirm before coding.

## Tokenizer

XLM-R uses SentencePiece **Unigram** with a fairseq id offset and special tokens `<s>`=0, `<pad>`=1, `</s>`=2, `<unk>`=3. Reimplementing Unigram (Viterbi over vocab log-probs) plus the offset by hand is error-prone.

Plan: depend on **`huggingface/swift-transformers`** (`Tokenizers` module), load the model's exported `tokenizer.json`, and let it produce `input_ids`. This handles Unigram, the offset, and special tokens. Manual SentencePiece is the fallback only if the dependency proves unworkable.

Tokenization output per paragraph: `input_ids` (prefix `<s>`, suffix `</s>`, truncate to 128) and `attention_mask`. Long paragraphs are already capped upstream.

## CoreML inference

Bake pooling and normalization into the exported model so Swift only feeds ids/mask and gets a unit vector:

- Inputs: `input_ids` `[1,128] Int32`, `attention_mask` `[1,128] Int32` (fixed length 128, padded).
- Graph: transformer -> masked mean pool -> L2 normalize.
- Output: `embedding` `[1,384] Float32`.

`MiniLMEmbeddingProvider.embed(_:)` then: tokenize -> pad to 128 -> `MLMultiArray` inputs -> `prediction` -> copy 384 floats out. `dimension = 384`. Cosine in `NeedlemanWunsch.cosine` is unchanged (already cheap; vectors are pre-normalized so cosine == dot, a minor future optimization).

## File plan

New, in `Packages/Alignment`:

- `Sources/Alignment/Internal/MiniLMEmbeddingProvider.swift` - `EmbeddingProvider` backed by CoreML + tokenizer. Async init that resolves the compiled model URL (from `ModelStore`), loads `MLModel`, builds the tokenizer.
- `Sources/Alignment/Internal/EmbeddingTokenizer.swift` - thin wrapper over `swift-transformers` returning padded `input_ids`/`attention_mask`.
- `Sources/Alignment/Internal/ModelStore.swift` - resolves the compiled model URL: returns the bundled/compiled path (strategy A) or downloads+compiles+caches (strategy B), reporting progress.
- (Strategy A only) `Sources/Alignment/Resources/MiniLM.mlpackage` and `tokenizer.json` as package resources via `Bundle.module`.

Modified:

- `Packages/Alignment/Package.swift` - add `swift-transformers` dependency; add `resources:` (strategy A) and `Bundle.module` support.
- `Packages/Alignment/Sources/Alignment/Public/ParagraphAligner.swift` - production `buildTable` constructs one `MiniLMEmbeddingProvider` and embeds both sides with it; `NLContextualEmbeddingProvider` retained only as an explicit fallback or removed. Signature stays the same (language args become advisory).
- `Packages/Alignment/Sources/Alignment/Internal/EmbeddingProvider.swift` - keep the protocol; the NL conformer stays for now behind a flag or is deleted once MiniLM is proven.
- `Packages/LibraryStore/.../LibraryStoreImpl.swift` - `describeAlignmentError` gains model-download/compile cases; (strategy B) the "running" diagnostics message reflects a download phase.

Tooling, repo root:

- `tools/convert_minilm_to_coreml.py` - exports the model (transformer + masked mean pool + L2 norm) to a quantized `.mlpackage` and dumps `tokenizer.json`; prints reference embeddings for parity tests.
- `tools/README.md` - how to run the conversion (Python env, `coremltools`, where outputs go).

## Dependencies

- `swift-transformers` (SPM, remote). Added to `Packages/Alignment/Package.swift` directly (editing a local package manifest is just a file change). The app target depends on Alignment transitively, so Xcode must **re-resolve packages** after this lands - per CLAUDE.md, adding the remote dependency to the app's own Package Dependencies sheet, if needed, must be done in the Xcode UI, not by editing `project.pbxproj`.
- `coremltools` + `torch` + `transformers` + `sentence-transformers` in a Python venv for the offline conversion step (build-time only, not shipped).

## Tests

- **Tokenizer parity** (`AlignmentTests`): for a handful of strings across languages, assert Swift `input_ids` match fixtures exported by the Python script. Catches the fairseq offset / Unigram bugs.
- **Embedding parity** (gated on model presence): assert Swift embeddings match Python reference within tolerance (cosine > 0.999) for a few sentences.
- **Cross-lingual sanity** (gated): cosine(es sentence, its en translation) > cosine(es sentence, unrelated en sentence).
- **Existing NW tests** keep using the injected mock `EmbeddingProvider` - unchanged.
- `ParagraphAlignerTests` continues to drive `buildTable(provider:)` with the mock.

Gated tests skip cleanly when the model asset isn't present (CI without the model still passes the deterministic tests).

## Risks / open questions

- **Bundle/repo size** - the storage decision above. Confirm A vs B before coding.
- **Tokenizer fidelity** - mitigated by `swift-transformers` + parity fixtures.
- **Conversion fidelity** - masked mean pool must match sentence-transformers exactly; verified by the parity test.
- **`swift-transformers` API churn** - pin a version.
- **`.mlpackage` in SPM resources** (strategy A) - confirm it compiles for both simulator and device slices; strategy B sidesteps this by compiling at runtime.
- **Perf** - first `MLModel` load is the slow part; embedding ~hundreds of paragraphs per book on `.utility` is acceptable (already backgrounded). Consider batching token sequences if needed.

## Implementation order

1. Write + run `convert_minilm_to_coreml.py`; verify int8 `.mlpackage` and `tokenizer.json` in Python; emit parity fixtures.
2. Confirm storage strategy (A bundle+LFS, or B download-on-first-launch).
3. `Package.swift`: add `swift-transformers` (+ resources if A).
4. `EmbeddingTokenizer` + parity tests against fixtures.
5. `ModelStore` (resolve/compile/cache the model URL).
6. `MiniLMEmbeddingProvider` + embedding-parity and cross-lingual tests.
7. Wire single-provider path into `buildTable`; keep mock-based tests green.
8. Diagnostics messaging for download/compile phases.
9. Build app, Recompute on simulator, verify the 1:5 case highlights the full range.
10. Tune `NeedlemanWunsch` (`gapPenalty`, `mergeBonus`, `maxMerge`) against real embeddings if needed.
```

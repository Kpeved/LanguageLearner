# Model conversion tooling

One-time, build-time conversion of the multilingual sentence encoder used for
cross-lingual paragraph alignment. Outputs are **not** committed; they are hosted as a
GitHub release asset and downloaded by the app on first use (see
`Packages/Alignment/Sources/Alignment/Internal/ModelStore.swift`).

## What it produces

`convert_minilm_to_coreml.py` converts
`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` into:

- `out/MiniLM.mlpackage` - int8 CoreML model. Inputs `input_ids`/`attention_mask`
  (`[1,128]` int32); output `embedding` (`[1,384]` float32). Masked mean pooling and L2
  normalization are baked into the graph.
- `out/tokenizer/` - `tokenizer.json` + config for swift-transformers. `tokenizer_class`
  is forced to `XLMRobertaTokenizer` so swift-transformers selects the Unigram model
  (otherwise it falls back to BPE and crashes with "requires merges").
- `out/fixtures.json` - parity fixtures (token ids + reference embeddings), copied into
  `Packages/Alignment/Tests/AlignmentTests/Resources/` for the gated provider tests.
- `out/MiniLM-coreml.zip` - `MiniLM.mlpackage` + `tokenizer/`, the file the app downloads.

## Run

Requires Python 3.11 (coremltools does not support 3.13). The venv is created under
`tools/.venv` (gitignored).

```bash
/opt/homebrew/bin/python3.11 -m venv tools/.venv
tools/.venv/bin/python -m pip install --upgrade pip
# coremltools converts cleanly with the older transformers BERT path:
tools/.venv/bin/python -m pip install \
  "coremltools>=8.0" "torch" "transformers==4.44.2" "sentence-transformers==3.0.1" \
  "tokenizers<0.20" "huggingface_hub<0.25" "numpy<2"

PYTORCH_ENABLE_MPS_FALLBACK=1 TOKENIZERS_PARALLELISM=false \
  tools/.venv/bin/python tools/convert_minilm_to_coreml.py
```

The script asserts parity (wrapper vs sentence-transformers cosine ~1.0; CoreML vs torch
> 0.99) and prints a cross-lingual sanity check.

## Host (update the model)

```bash
gh release create models-v1 tools/out/MiniLM-coreml.zip --title "..." --notes "..."
# or, to replace an existing asset:
gh release upload models-v1 tools/out/MiniLM-coreml.zip --clobber
```

Bumping the model means bumping both the release tag/URL and the cache dir version in
`ModelStore` (`assetURL` and the `MiniLM-vN` path) so existing installs re-download.

## Validate the Swift side

```bash
cd Packages/Alignment
RUN_MODEL_TESTS=1 swift test --filter MiniLMProviderTests
```

Downloads (~108 MB once), compiles, and checks Swift embeddings against `fixtures.json`.

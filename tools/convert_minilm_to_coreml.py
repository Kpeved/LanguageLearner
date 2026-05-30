#!/usr/bin/env python3
"""
One-time build-time conversion of a multilingual sentence encoder to CoreML.

Produces, under tools/out/:
  - MiniLM.mlpackage       int8-quantized CoreML model: (input_ids, attention_mask) -> 384-d unit vector
  - tokenizer/             tokenizer.json + config for swift-transformers
  - fixtures.json          parity fixtures (token ids + reference embeddings) for Swift tests
  - MiniLM-coreml.zip      MiniLM.mlpackage + tokenizer/, ready to host as a release asset

Run:
  tools/.venv/bin/python tools/convert_minilm_to_coreml.py

Model: sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
  XLM-R SentencePiece tokenizer, 384-d, mean pooling, max 128 tokens.
"""

import json
import os
import shutil
import sys

import numpy as np
import torch
import coremltools as ct
from sentence_transformers import SentenceTransformer

MODEL_NAME = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
SEQ_LEN = 128
EMB_DIM = 384
OUT_DIR = os.path.join(os.path.dirname(__file__), "out")


class MeanPooledEncoder(torch.nn.Module):
    """Transformer + attention-masked mean pooling + L2 normalize, so the CoreML
    graph emits one unit vector per input and Swift only feeds ids/mask."""

    def __init__(self, hf_model):
        super().__init__()
        self.model = hf_model

    def forward(self, input_ids, attention_mask):
        out = self.model(input_ids=input_ids, attention_mask=attention_mask, return_dict=False)
        token_emb = out[0]  # last_hidden_state [B, S, H]
        mask = attention_mask.unsqueeze(-1).to(token_emb.dtype)
        summed = (token_emb * mask).sum(dim=1)
        counts = mask.sum(dim=1).clamp(min=1e-9)
        mean = summed / counts
        norm = mean.norm(p=2, dim=1, keepdim=True).clamp(min=1e-9)
        return mean / norm


def cosine(a, b):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def main():
    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)
    os.makedirs(OUT_DIR, exist_ok=True)

    print(f"Loading {MODEL_NAME} ...")
    st = SentenceTransformer(MODEL_NAME, device="cpu")
    st.eval()
    hf_model = st[0].auto_model
    tokenizer = st.tokenizer
    print(f"  hidden dim = {hf_model.config.hidden_size}, max len = {SEQ_LEN}")
    assert hf_model.config.hidden_size == EMB_DIM, "unexpected hidden size"

    encoder = MeanPooledEncoder(hf_model).eval()

    # --- Parity sentences (translation pairs + an unrelated control) ---
    sentences = [
        "The cat sat on the mat.",
        "El gato se sento en la alfombra.",
        "Good morning, how are you?",
        "Buenos dias, como estas?",
        "Quantum mechanics is hard.",
    ]
    enc = tokenizer(
        sentences,
        padding="max_length",
        truncation=True,
        max_length=SEQ_LEN,
        return_tensors="pt",
    )
    input_ids = enc["input_ids"].long()
    attention_mask = enc["attention_mask"].long()

    with torch.no_grad():
        ref = encoder(input_ids, attention_mask).numpy()
    # Sanity: our wrapper must match sentence-transformers' own encode().
    st_emb = st.encode(sentences, normalize_embeddings=True, device="cpu")
    wrapper_vs_st = min(cosine(ref[i], st_emb[i]) for i in range(len(sentences)))
    print(f"  wrapper vs sentence-transformers min cosine = {wrapper_vs_st:.5f}")
    assert wrapper_vs_st > 0.999, "wrapper does not match sentence-transformers"
    # Cross-lingual sanity.
    print(f"  cos(en cat, es cat)   = {cosine(ref[0], ref[1]):.4f}")
    print(f"  cos(en cat, unrelated)= {cosine(ref[0], ref[4]):.4f}")

    # --- Trace + convert ---
    print("Tracing ...")
    example = (input_ids[0:1], attention_mask[0:1])
    traced = torch.jit.trace(encoder, example, strict=False)

    print("Converting to CoreML (mlprogram, iOS17) ...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
    )

    print("Quantizing weights to int8 ...")
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )
    cfg = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
    )
    mlmodel = linear_quantize_weights(mlmodel, cfg)

    mlmodel.short_description = "Multilingual sentence encoder (paraphrase-multilingual-MiniLM-L12-v2), mean-pooled L2-normalized 384-d."
    mlpackage_path = os.path.join(OUT_DIR, "MiniLM.mlpackage")
    mlmodel.save(mlpackage_path)
    print(f"  saved {mlpackage_path}")

    # --- Verify CoreML output matches the torch reference ---
    print("Verifying CoreML parity ...")
    worst = 1.0
    for i in range(len(sentences)):
        pred = mlmodel.predict(
            {
                "input_ids": input_ids[i : i + 1].int().numpy(),
                "attention_mask": attention_mask[i : i + 1].int().numpy(),
            }
        )["embedding"][0]
        c = cosine(pred, ref[i])
        worst = min(worst, c)
    print(f"  CoreML vs torch min cosine = {worst:.5f}")
    assert worst > 0.99, "CoreML output diverges from torch reference"

    # --- Tokenizer for swift-transformers ---
    tok_dir = os.path.join(OUT_DIR, "tokenizer")
    tokenizer.save_pretrained(tok_dir)
    if not os.path.exists(os.path.join(tok_dir, "tokenizer.json")):
        sys.exit("ERROR: tokenizer.json not produced; swift-transformers needs the fast tokenizer.")
    # swift-transformers dispatches the tokenizer model class off tokenizer_class. The HF
    # fast tokenizer saves it as "PreTrainedTokenizerFast", which swift-transformers maps to
    # BPE (-> "requires merges" crash). Force the XLM-R class so it picks the Unigram model.
    cfg_path = os.path.join(tok_dir, "tokenizer_config.json")
    with open(cfg_path) as f:
        tcfg = json.load(f)
    tcfg["tokenizer_class"] = "XLMRobertaTokenizer"
    with open(cfg_path, "w") as f:
        json.dump(tcfg, f)
    print(f"  saved tokenizer to {tok_dir} (tokenizer_class=XLMRobertaTokenizer)")

    # --- Fixtures for Swift parity tests ---
    fixtures = {
        "model": MODEL_NAME,
        "seqLen": SEQ_LEN,
        "dim": EMB_DIM,
        "sentences": sentences,
        "inputIds": input_ids.tolist(),
        "attentionMask": attention_mask.tolist(),
        "embeddings": ref.tolist(),
    }
    with open(os.path.join(OUT_DIR, "fixtures.json"), "w") as f:
        json.dump(fixtures, f)
    print("  saved fixtures.json")

    # --- Zip for hosting ---
    archive = os.path.join(OUT_DIR, "MiniLM-coreml")
    # Stage only what the app downloads: the mlpackage + tokenizer.json/config.
    stage = os.path.join(OUT_DIR, "_stage")
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    shutil.copytree(mlpackage_path, os.path.join(stage, "MiniLM.mlpackage"))
    os.makedirs(os.path.join(stage, "tokenizer"))
    for name in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        src = os.path.join(tok_dir, name)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(stage, "tokenizer", name))
    shutil.make_archive(archive, "zip", stage)
    shutil.rmtree(stage)
    size_mb = os.path.getsize(archive + ".zip") / (1024 * 1024)
    print(f"  saved {archive}.zip ({size_mb:.1f} MB)")

    print("\nDone.")


if __name__ == "__main__":
    main()

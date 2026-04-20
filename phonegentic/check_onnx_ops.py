#!/usr/bin/env python3
"""
Check ONNX model graph for IsNaN/Where ops and attempt to extract BOS embedding.
Usage: python3 check_onnx_ops.py
"""
import os, sys
import numpy as np

MODELS_DIR = "/d/p/phonegentic/phonegentic/build/linux/x64/debug/bundle/data/flutter_assets/models/pocket-tts-onnx"

try:
    import onnx
except ImportError:
    print("ERROR: onnx not installed. Run: pip install onnx")
    sys.exit(1)

try:
    import onnxruntime as ort
except ImportError:
    print("ERROR: onnxruntime not installed.")
    sys.exit(1)

model_path = f"{MODELS_DIR}/onnx/flow_lm_main_int8.onnx"
print(f"\n=== Checking {model_path} ===")
m = onnx.load(model_path)

ops = [n.op_type for n in m.graph.node]
op_counts = {}
for op in ops:
    op_counts[op] = op_counts.get(op, 0) + 1

print(f"Total ops: {len(ops)}")
print(f"IsNaN present: {'IsNaN' in ops}")
print(f"Where present: {'Where' in ops}")
print(f"If present: {'If' in ops}")
print(f"Loop present: {'Loop' in ops}")
print(f"\nOp type counts:")
for op, count in sorted(op_counts.items()):
    print(f"  {op}: {count}")

# Look for BOS embedding as an initializer/constant
print(f"\n=== Searching for BOS embedding (constant [1,1,32] or [32]) ===")
for init in m.graph.initializer:
    shape = list(init.dims)
    if shape in [[1, 1, 32], [32], [1, 32]]:
        arr = np.array(init.float_data or list(onnx.numpy_helper.to_array(init)))
        flat = arr.flatten()
        print(f"  Initializer '{init.name}': shape={shape}  first4={flat[:4].tolist()}")

# Check inputs to see if sequence has any special handling
print(f"\n=== flow_lm_main inputs ===")
for inp in m.graph.input:
    print(f"  {inp.name}: {[d.dim_value or d.dim_param for d in inp.type.tensor_type.shape.dim]}")

# Try running with NaN vs zeros to see what happens to conditioning output
print(f"\n=== Runtime test: NaN vs zeros for sequence input ===")
import sentencepiece as spm
sp = spm.SentencePieceProcessor()
sp.Load(f"{MODELS_DIR}/tokenizer.model")
token_ids = np.array([sp.EncodeAsIds("Testing.")], dtype=np.int64)

text_cond_sess = ort.InferenceSession(f"{MODELS_DIR}/onnx/text_conditioner.onnx")
flow_main = ort.InferenceSession(f"{MODELS_DIR}/onnx/flow_lm_main_int8.onnx")

text_emb = text_cond_sess.run(None, {"token_ids": token_ids})[0]

def init_state(sess):
    state = {}
    type_map = {"tensor(float)": np.float32, "tensor(int64)": np.int64, "tensor(bool)": np.bool_}
    for inp in sess.get_inputs():
        if inp.name.startswith("state_"):
            shape = [s if isinstance(s, int) else 0 for s in inp.shape]
            state[inp.name] = np.zeros(shape, dtype=type_map.get(inp.type, np.float32))
    return state

def update_state(state, result, sess):
    for i, out in enumerate(sess.get_outputs()):
        if out.name.startswith("out_state_"):
            idx = int(out.name.replace("out_state_", ""))
            state[f"state_{idx}"] = result[i]

# Text conditioning pass with fresh state
state_nan = init_state(flow_main)
empty_seq = np.zeros((1, 0, 32), dtype=np.float32)
res = flow_main.run(None, {"sequence": empty_seq, "text_embeddings": text_emb, **state_nan})
update_state(state_nan, res, flow_main)

# Copy state for zeros test
import copy
state_zeros = copy.deepcopy(state_nan)

# Test 1: NaN input
seq_nan = np.full((1, 1, 32), np.nan, dtype=np.float32)
res_nan = flow_main.run(None, {"sequence": seq_nan, "text_embeddings": np.zeros((1, 0, 1024), np.float32), **state_nan})
cond_nan = res_nan[0].flatten()
eos_nan = float(res_nan[1].flat[0])
print(f"\n  NaN input → eos={eos_nan:.4f}  cond[:4]={cond_nan[:4].tolist()}")
print(f"  NaN in cond: {np.any(np.isnan(cond_nan))}")

# Test 2: zeros input
seq_zeros = np.zeros((1, 1, 32), dtype=np.float32)
res_zeros = flow_main.run(None, {"sequence": seq_zeros, "text_embeddings": np.zeros((1, 0, 1024), np.float32), **state_zeros})
cond_zeros = res_zeros[0].flatten()
eos_zeros = float(res_zeros[1].flat[0])
print(f"\n  zeros input → eos={eos_zeros:.4f}  cond[:4]={cond_zeros[:4].tolist()}")

# Test 3: try to find what input would produce a good EOS (< -4.0)
# If the model has BOS handling, we need to find the right BOS value
print(f"\n=== Summary ===")
print(f"EOS threshold: -4.0")
print(f"NaN fires EOS immediately: {eos_nan > -4.0}")
print(f"Zeros fires EOS: {eos_zeros > -4.0}")
print(f"NaN produces NaN conditioning: {np.any(np.isnan(cond_nan))}")

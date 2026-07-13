"""Smoke test: load exported TFLite model, run random input, report tensor shapes.
Also dump class names from yolov8n-oiv7.pt and compare to the iOS app's list.
"""
import sys
import numpy as np

TFLITE_PATH = sys.argv[1]

# --- class names ---
from ultralytics import YOLO
model = YOLO("/Users/matthewmacosko/Documents/realtime-ai-cam-android/tools/yolov8n-oiv7.pt")
names = model.names  # dict {idx: name}
assert sorted(names.keys()) == list(range(len(names))), "non-contiguous class indices"
out_names = "/Users/matthewmacosko/Documents/realtime-ai-cam-android/models/class_names.txt"
with open(out_names, "w") as f:
    for i in range(len(names)):
        f.write(names[i] + "\n")
print(f"classes: {len(names)} written to {out_names}")

ios_path = "/Users/matthewmacosko/Documents/project 601/class_names.txt"
ios = [l.rstrip("\n") for l in open(ios_path) if l.strip() != ""]
ours = [names[i] for i in range(len(names))]
if ios == ours:
    print("class names MATCH iOS list exactly (order + spelling)")
else:
    print(f"class names DIFFER: ios={len(ios)} ours={len(ours)}")
    for i, (a, b) in enumerate(zip(ios, ours)):
        if a != b:
            print(f"  first diff at index {i}: ios={a!r} ours={b!r}")
            break

# --- tflite smoke ---
try:
    from ai_edge_litert.interpreter import Interpreter
except ImportError:
    from tensorflow.lite import Interpreter  # type: ignore

interp = Interpreter(model_path=TFLITE_PATH)
interp.allocate_tensors()
inp = interp.get_input_details()
out = interp.get_output_details()
for d in inp:
    print(f"INPUT  name={d['name']} shape={d['shape'].tolist()} dtype={d['dtype'].__name__}")
rng = np.random.default_rng(0)
x = rng.random(inp[0]["shape"], dtype=np.float32)
if inp[0]["dtype"] != np.float32:
    x = x.astype(inp[0]["dtype"])
interp.set_tensor(inp[0]["index"], x)
interp.invoke()
for d in out:
    y = interp.get_tensor(d["index"])
    print(f"OUTPUT name={d['name']} shape={list(y.shape)} dtype={y.dtype} "
          f"min={y.min():.4f} max={y.max():.4f}")
print("smoke test OK")

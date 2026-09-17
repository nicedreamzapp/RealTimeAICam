import sys, glob, os, mlx_whisper
for f in sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "*.caf"))):
    r = mlx_whisper.transcribe(f, path_or_hf_repo="mlx-community/whisper-large-v3-turbo", language="en", initial_prompt="Everything is spelled out in words, never digits: three hundred ninety-three Westgate doctor, eight hundred five million, eight zero five, zero one four two, twelve oh five.")
    print(f"{os.path.basename(f):28s} {r['text'].strip()}")

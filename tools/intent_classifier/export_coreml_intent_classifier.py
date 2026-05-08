#!/usr/bin/env python3
"""Export sklearn model to CoreML.
Dependencies: coremltools, scikit-learn
"""
import argparse, pickle
try:
    import coremltools as ct
except Exception as exc:
    raise SystemExit(f"Missing dependency coremltools: {exc}")

p=argparse.ArgumentParser();p.add_argument('--model',required=True);p.add_argument('--out',required=True);a=p.parse_args()
with open(a.model,'rb') as f: model=pickle.load(f)
mlmodel=ct.converters.sklearn.convert(model,input_features=['text'],output_feature_names=['classLabel'])
mlmodel.save(a.out)
print(f"saved {a.out}")

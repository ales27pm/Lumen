#!/usr/bin/env python3
"""Train a lightweight intent classifier.
Dependencies: scikit-learn>=1.3
Usage: python train_intent_classifier.py --dataset intent_dataset.jsonl --model-out intent_model.pkl
"""
import argparse, json, pickle
try:
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import Pipeline
except Exception as exc:
    raise SystemExit(f"Missing dependency scikit-learn: {exc}")

p=argparse.ArgumentParser();p.add_argument('--dataset',required=True);p.add_argument('--model-out',required=True);a=p.parse_args()
X=[];y=[]
for line in open(a.dataset):
    row=json.loads(line);X.append(row['text']);y.append(row['intent'])
model=Pipeline([('tfidf',TfidfVectorizer(ngram_range=(1,2))),('clf',LogisticRegression(max_iter=1200))])
model.fit(X,y)
with open(a.model_out,'wb') as f: pickle.dump(model,f)
print(f"saved {a.model_out}")

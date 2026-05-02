import argparse, json
from pathlib import Path

def main():
    p=argparse.ArgumentParser(); p.add_argument('--config',required=True); args=p.parse_args()
    cfg=json.loads(Path(args.config).read_text())
    dataset_dir=Path(cfg['dataset_dir'])
    train=dataset_dir/'train_sft.jsonl'; val=dataset_dir/'val_sft.jsonl'
    report={"agent":cfg["agent"],"train_records":sum(1 for _ in train.open()),"val_records":sum(1 for _ in val.open()),"config":cfg,"notes":"Use Unsloth FastLanguageModel + LoRA in runtime env"}
    out=Path(cfg['output_dir']); out.mkdir(parents=True,exist_ok=True)
    (out/'training_report.json').write_text(json.dumps(report,indent=2)+"\n")
    print('prepared SFT run', cfg['agent'])
if __name__=='__main__': main()

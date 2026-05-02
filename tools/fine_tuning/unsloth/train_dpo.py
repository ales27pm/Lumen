import argparse, json
from pathlib import Path

def main():
    p=argparse.ArgumentParser(); p.add_argument('--config',required=True); args=p.parse_args()
    cfg=json.loads(Path(args.config).read_text())
    d=Path(cfg['dataset_dir'])
    assert (d/'train_dpo.jsonl').exists() and (d/'val_dpo.jsonl').exists()
    out=Path(cfg['output_dir']); out.mkdir(parents=True,exist_ok=True)
    (out/'dpo_report.json').write_text(json.dumps({'agent':cfg['agent'],'trainer':'trl.DPOTrainer_or_orpo_path'},indent=2)+"\n")
    print('prepared DPO run', cfg['agent'])
if __name__=='__main__': main()

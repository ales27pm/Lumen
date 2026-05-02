from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from lumen_manifest_crawler.manifest import AgentBehaviorManifest

AGENTS = ["cortex", "executor", "mouth", "mimicry", "rem", "fleet"]
SYSTEM_PROMPTS = {
    "cortex": "You are Cortex, Lumen’s routing and planning agent. Select manifest-approved tools, persist required action steps, and delegate execution to Executor.",
    "executor": "You are Executor, Lumen’s tool-call agent. Produce strict manifest-valid tool JSON only. Never invent tools or arguments.",
    "mouth": "You are Mouth, Lumen’s user-facing response agent. Explain tool results clearly without leaking internal JSON or sentinels.",
    "mimicry": "You are Mimicry, Lumen’s style adaptation agent. Adapt tone within safety and privacy boundaries.",
    "rem": "You are REM, Lumen’s reflection and repair agent. Diagnose failures, repair datasets, enforce memory policy, and produce regression samples.",
    "fleet": "You are part of the Lumen model fleet. Know every slot, delegation rule, memory scope, and boundary.",
}

@dataclass(frozen=True)
class FineTuningDatasetConfig:
    deterministic: bool = True
    validation_ratio: float = 0.15
    min_validation_records: int = 1
    include_dpo: bool = True
    include_eval: bool = True
    include_unsloth_config: bool = True
    max_sequence_length: int = 4096

@dataclass(frozen=True)
class AgentFineTuningDataset:
    agent: str
    train_sft: list[dict]
    val_sft: list[dict]
    train_dpo: list[dict]
    val_dpo: list[dict]
    eval: list[dict]
    dataset_card: dict
    unsloth_config: dict


def compile_agent_fine_tuning_datasets(manifest: AgentBehaviorManifest, compiled_records: dict[str, list[dict]], fleet_artifacts: dict | None = None, runtime_audit_reports: list[dict] | None = None, config: FineTuningDatasetConfig | None = None) -> dict[str, AgentFineTuningDataset]:
    config = config or FineTuningDatasetConfig()
    out = {}
    known_tools = {t.id for t in manifest.tools}
    for agent in AGENTS:
        sft = []
        for rec in compiled_records.get("train_sft", []) + compiled_records.get("validation_sft", []):
            role = ((rec.get("metadata") or {}).get("agent") or rec.get("agentRole") or "").replace("tool_executor","executor")
            fam = rec.get("sourceFamily")
            if role == agent or (agent=="fleet" and fam in {"manifest_grounding_cards","fleet_system_prompts"}) or (agent=="executor" and fam in {"executor_tool_calls","tool_schema_cards","approval_boundary_samples"}):
                user = next((m.get("content","") for m in rec.get("messages",[]) if m.get("role")=="user"), "")
                assistant = next((m.get("content","") for m in rec.get("messages",[]) if m.get("role")=="assistant"), "")
                if not assistant:
                    continue
                sft.append({"messages":[{"role":"system","content":SYSTEM_PROMPTS[agent]},{"role":"user","content":user},{"role":"assistant","content":assistant}],"metadata":{"agent":agent,"taskType":rec.get("taskType","unknown"),"toolIDs":[t for t in rec.get("toolIDs",[]) if t in known_tools],"risk":((rec.get("quality") or {}).get("risk") or "standard"),"sourceFamily":fam or "unknown","manifestCommit":manifest.sourceIntegrity.commit}})
        sft = sorted(sft,key=lambda r: json.dumps(r,sort_keys=True,ensure_ascii=False))
        cut = max(config.min_validation_records,int(round(len(sft)*config.validation_ratio))) if len(sft)>1 else 0
        cut = min(cut,max(0,len(sft)-1))
        val,train = sft[:cut],sft[cut:]
        dpo=[]
        for r in compiled_records.get("dpo_preference_pairs",[]):
            prompt=r.get("prompt") or []
            chosen=r.get("chosen") or {}
            rejected=r.get("rejected") or {}
            if chosen.get("content")==rejected.get("content"): continue
            dpo.append({"prompt":[{"role":"system","content":SYSTEM_PROMPTS[agent]},{"role":"user","content": (prompt[-1].get("content","") if prompt else "") }],"chosen":{"role":"assistant","content":chosen.get("content","")},"rejected":{"role":"assistant","content":rejected.get("content","")},"metadata":{"agent":agent,"preferenceType":"safety_preference","reason":"manifest compliance"}})
        dpo = sorted(dpo,key=lambda r: json.dumps(r,sort_keys=True,ensure_ascii=False))
        dval=dpo[:1] if len(dpo)>1 else []
        dtrain=dpo[1:] if len(dpo)>1 else dpo
        evals=[]
        for e in compiled_records.get("eval_scenarios",[]):
            evals.append({"messages":[{"role":"system","content":SYSTEM_PROMPTS[agent]}]+[m for m in e.get("messages",[]) if m.get("role")!="system"],"expected":e.get("expected",{}),"metadata":{"agent":agent,"evalType":e.get("taskType","general"),"mustPass":True}})
        dataset_card={"agent":agent,"recordCounts":{"train_sft":len(train),"val_sft":len(val),"train_dpo":len(dtrain),"val_dpo":len(dval),"eval":len(evals)},"manifestCommit":manifest.sourceIntegrity.commit}
        lr=0.0002 if agent in {"cortex","executor","rem"} else 0.0001
        epochs=2 if agent in {"cortex","executor","rem"} else 1
        uns={"agent":agent,"base_model_name":"unsloth/Qwen2.5-1.5B-Instruct-bnb-4bit","max_seq_length":config.max_sequence_length,"load_in_4bit":True,"lora_r":16,"lora_alpha":32,"lora_dropout":0.0,"learning_rate":lr,"batch_size":2,"gradient_accumulation_steps":8,"num_train_epochs":epochs,"warmup_steps":20,"dataset_dir":f"generated/fine_tuning/{agent}","output_dir":f"models/lora/{agent}"}
        out[agent]=AgentFineTuningDataset(agent,train,val,dtrain,dval,evals,dataset_card,uns)
    return out

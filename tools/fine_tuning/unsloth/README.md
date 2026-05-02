# Unsloth Fine-tuning
1. Generate datasets.
2. Inspect dataset cards.
3. Train SFT per agent.
4. Optionally train DPO.
5. Merge adapters.
6. Export GGUF/Core ML later.
7. Evaluate with eval.jsonl.
8. Never train on private app exports unless sanitized.

Unsloth adapters can be per-slot. If runtime supports hot-swap, keep separate LoRA per slot. If not, merge strongest common adapters or train unified fleet adapter.

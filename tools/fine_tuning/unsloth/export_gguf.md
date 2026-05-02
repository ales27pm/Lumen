# Export GGUF

1. Merge LoRA adapter into the base model checkpoint.
2. Convert merged weights to GGUF with your `llama.cpp` conversion flow.
3. Quantize for the target device profile.
4. For Core ML, run your separate Core ML conversion path from the merged checkpoint.

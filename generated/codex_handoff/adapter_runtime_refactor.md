# Lumen Qwen3 Adapter Runtime Refactor Handoff

## Changed files

- `ios/Lumen/Models/StoredModel.swift`
- `ios/Lumen/Services/ModelFamilySelection.swift`
- `ios/Lumen/Services/ModelFleet.swift`
- `ios/Lumen/Services/ModelLaunchBootstrap.swift`
- `ios/Lumen/Services/ModelLoader.swift`
- `ios/Lumen/Services/SlotModelRuntimeCoordinator.swift`
- `ios/Lumen/Services/LlamaService.swift`
- `ios/Lumen/Services/RolePipelineAgentService.swift`
- `ios/Lumen/Services/AgentGrounding/AgentBehaviorTrace.swift`
- `ios/Lumen/Views/ModelsView.swift`
- `ios/LumenTests/LumenFleetTests.swift`

## Runtime flow before

- Qwen3 first-launch catalog pointed at five role-baked full chat GGUFs.
- `LumenModelFleetResolver` assigned full chat models per role.
- `SlotModelRuntimeCoordinator.ensureReady(slot:)` unloaded the current chat runtime and loaded the slot-specific full GGUF.
- `AppLlamaService` stored `chatRuntimes: [LumenModelSlot: ChatRuntime]`, so role switches caused model churn.
- Simple chat still flowed through Mouth and then Mimicry synchronously.

## Runtime flow after

- Qwen3 default catalog downloads one shared chat base, one embedding GGUF, and six role LoRA adapter GGUFs.
- `LumenModelFleetResolver` recognizes the Qwen3 shared base and attaches optional role adapter metadata to each slot assignment.
- `SlotModelRuntimeCoordinator.ensureReady(slot:)` loads the shared Qwen3 base once, lazily loads the slot adapter, activates it, and does not call `unloadAllChat()` for Qwen3 slot switches.
- `AppLlamaService` has a shared adapter runtime (`sharedChatRuntime`, `sharedChatBasePath`) plus `roleAdapters` and `activeAdapterSlot`.
- Role-specific grounding/system prompts are still applied via `req.groundingSystemPrompt(for:)` before generation.
- If a role adapter is missing or fails to activate, the coordinator logs the structured failure, clears active adapters, and continues on the shared base with the role prompt.
- Simple chat uses Mouth only. Mimicry is only invoked for explicit style-rewrite requests. REM remains post-turn/background and non-blocking.

## New Hugging Face artifact layout

Shared base repo:

- `ales27pm/lumen-qwen3-bootstrap-gguf`
- `lumen-qwen3-fast-shared-q4_k_m.gguf`

Adapter repo:

- `ales27pm/lumen-qwen3-bootstrap-adapters-gguf`
- `lumen-cortex-lora.gguf`
- `lumen-executor-lora.gguf`
- `lumen-mouth-lora.gguf`
- `lumen-mimicry-lora.gguf`
- `lumen-rem-lora.gguf`
- `lumen-fleet-lora.gguf`

Embedding remains separate:

- `Qwen/Qwen3-Embedding-0.6B-GGUF`
- `Qwen3-Embedding-0.6B-Q8_0.gguf`

## Adapter conversion commands

```bash
cd ~/Lumen
mkdir -p models/lora_qwen3_gguf

for agent in cortex executor mouth mimicry rem fleet; do
  python ~/.unsloth/llama.cpp/convert_lora_to_gguf.py \
    "models/lora_qwen3_bootstrap/$agent" \
    --outfile "models/lora_qwen3_gguf/lumen-$agent-lora.gguf"
done

find models/lora_qwen3_gguf -name "*.gguf" -type f -exec ls -lh {} +
```

## Upload commands

Adapters:

```bash
hf repo create ales27pm/lumen-qwen3-bootstrap-adapters-gguf \
  --type model \
  --private \
  --yes

hf upload ales27pm/lumen-qwen3-bootstrap-adapters-gguf \
  models/lora_qwen3_gguf \
  . \
  --repo-type model
```

Base model:

```bash
hf upload ales27pm/lumen-qwen3-bootstrap-gguf \
  models/base_qwen3_fast/lumen-qwen3-fast-shared-q4_k_m.gguf \
  lumen-qwen3-fast-shared-q4_k_m.gguf \
  --repo-type model
```

## Local validation commands for human Xcode environment

Codex must not run this because the environment does not have Xcode/xcodebuild:

```bash
xcodebuild -project ios/Lumen.xcodeproj -scheme Lumen -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

Codex-available Python check:

```bash
python -m pytest tools/lumen_manifest_crawler/tests
```

## llama.cpp / SwiftLlama adapter bridge verification

The Xcode project pins `swift-llama-cpp` exact version `1.2.0`. Inspection of that package version found these real adapter APIs:

- `llama_adapter_lora_init(model, path)`
- `llama_adapter_lora_free(adapter)`
- `llama_set_adapter_lora(ctx, adapter, scale)`
- `llama_rm_adapter_lora(ctx, adapter)`
- `llama_clear_adapter_lora(ctx)`
- Swift wrappers: `LlamaLoraAdapter`, `LlamaContext.apply(loraAdapter:scale:)`, and `LlamaContext.removeAllLoraAdapters()`.

Because `SwiftLlama.LlamaService` hides its internal `Llama` actor/context, the app-side bridge uses public `SwiftLlama` wrappers (`LlamaModel`, `LlamaContext`, `LlamaBatch`, `LlamaSampler`, `LlamaLoraAdapter`) to run the shared-base adapter path directly. The legacy `SwiftLlama.LlamaService` path remains for Qwen2.5/full-model fallback.

## Swift symbols requiring local Xcode validation

- `AdapterChatRuntime.streamCompletion(...)`
- `LlamaLoraAdapter(model:path:)`
- `LlamaContext.apply(loraAdapter:scale:)`
- `LlamaContext.removeAllLoraAdapters()`
- `LlamaSampler(config:model:)`
- `LlamaBatch(initialSize:)`
- `AgentBehaviorTrace` optional adapter metadata Codable compatibility
- `ModelRole.roleAdapter` SwiftData persisted string compatibility

## Unresolved native bridge risks

- Codex could inspect the pinned Swift package from GitHub but could not compile the iOS target locally because `xcodebuild` is unavailable.
- If the locally resolved Swift package differs from exact version `1.2.0`, adapter method spellings may differ. Re-resolve packages in Xcode and verify the methods above.
- The direct app-side adapter runtime intentionally avoids fake APIs, but its generation loop should be validated with a real GGUF base and LoRA adapter on device/simulator.

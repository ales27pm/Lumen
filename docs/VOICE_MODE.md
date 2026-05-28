# Voice Mode
- Push-to-talk is the default mode.
- Voice capture is user-initiated only.
- No background always-listening or wake-word behavior is implemented.
- Mic + speech permissions are requested only after user initiation.

- VoiceModeView now uses VoiceSessionController as primary runtime; VoiceService retained as compatibility backend for speech engine bridging only.
- Voice permission prompts are user-initiated from push-to-talk action; no startup prompt and no background always-listening.

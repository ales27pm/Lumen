# Entitlements and Info.plist Audit

`BackgroundEntitlementValidator` checks runtime `Info.plist` values for:
- `BGTaskSchedulerPermittedIdentifiers` containing:
  - `com.27pm.lumen.agent.refresh`
  - `com.27pm.lumen.agent.process`
- Usage description keys currently referenced by app capabilities/tools:
  - `NSMicrophoneUsageDescription`
  - `NSSpeechRecognitionUsageDescription`
  - `NSCalendarsUsageDescription`
  - `NSContactsUsageDescription`

Validator emits non-fatal warnings for diagnostics.

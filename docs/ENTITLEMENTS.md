# Entitlements and Usage Descriptions

Required background task identifiers:
- `com.27pm.lumen.agent.refresh`
- `com.27pm.lumen.agent.process`

Generated Info.plist usage descriptions are configured in `ios/Lumen.xcodeproj/project.pbxproj` for microphone, speech recognition, contacts, location, photos, AlarmKit, calendar full access, reminders full access, motion, and background modes.

The entitlement validator accepts either `NSCalendarsUsageDescription` or `NSCalendarsFullAccessUsageDescription` for calendar access to match modern generated Info.plist keys.

AppIntents/Shortcuts added in this phase do not require additional entitlements; sensitive actions return an open-app approval message instead of executing directly.

CarPlay voice-based conversation support is enabled with the Apple-approved `com.apple.developer.carplay-voice-based-conversation` entitlement in `ios/Lumen/Lumen.entitlements`. App Store archives must use a provisioning profile regenerated after enabling the matching App ID capability; stale profiles created before approval can fail with `Provisioning profile ... doesn't include the com.apple.developer.carplay entitlement`.

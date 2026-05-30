# Entitlements and Usage Descriptions

Required background task identifiers:
- `com.27pm.lumen.agent.refresh`
- `com.27pm.lumen.agent.process`

Generated Info.plist usage descriptions are configured in `ios/Lumen.xcodeproj/project.pbxproj` for microphone, speech recognition, contacts, location, photos, AlarmKit, calendar full access, reminders full access, motion, and background modes.

The entitlement validator accepts either `NSCalendarsUsageDescription` or `NSCalendarsFullAccessUsageDescription` for calendar access to match modern generated Info.plist keys.

AppIntents/Shortcuts added in this phase do not require additional entitlements; sensitive actions return an open-app approval message instead of executing directly.

CarPlay support is intentionally not enabled. `ios/Lumen/Lumen.entitlements` must not include generic or category-specific CarPlay entitlements, generated Info.plist settings must not declare `UIApplicationSupportsCarPlay`, and the project must not include a CarPlay scene role or Swift CarPlay integration code.

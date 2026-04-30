# Microsoft Graph MSAL iOS Configuration

Lumen uses `GENERATE_INFOPLIST_FILE=YES`, so the app does not have a checked-in `Info.plist` file. The required MSAL callback keys must live in the Lumen target build settings inside:

```text
ios/Lumen.xcodeproj/project.pbxproj
```

## Required values

```text
Bundle ID: com.27pm.lumen
Redirect URI: msauth.com.27pm.lumen://auth
Client ID: 51aa8fd9-16b2-4f8e-8b97-b8618ceb6c40
Authority: https://login.microsoftonline.com/common
Keychain group: $(AppIdentifierPrefix)com.microsoft.adalcache
```

## Patch generated Info.plist settings

Run from repo root:

```bash
python3 scripts/patch-msal-ios-infoplist.py
```

This idempotently inserts these build settings into both Lumen Debug and Release configurations:

```pbxproj
INFOPLIST_KEY_CFBundleURLTypes = (
	{
		CFBundleURLName = "com.27pm.lumen";
		CFBundleURLSchemes = (
			"msauth.com.27pm.lumen",
		);
	},
);
INFOPLIST_KEY_LSApplicationQueriesSchemes = (
	msauth,
	msauthv2,
	msauthv3,
);
```

## Callback handling

SwiftUI already forwards URLs in `LumenApp.swift`:

```swift
.onOpenURL { url in
    MicrosoftGraphURLHandler.handle(url)
}
```

`LumenAppDelegate` also forwards classic app delegate URL callbacks:

```swift
func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
) -> Bool
```

Both paths call:

```swift
MSALPublicClientApplication.handleMSALResponse(...)
```

## Entitlements

`ios/Lumen/Lumen.entitlements` must include:

```xml
<key>keychain-access-groups</key>
<array>
	<string>$(AppIdentifierPrefix)com.microsoft.adalcache</string>
</array>
```

## Verification

After running the patch script, clean build and inspect the generated app plist. It should contain:

```xml
<key>CFBundleURLTypes</key>
<array>
	<dict>
		<key>CFBundleURLName</key>
		<string>com.27pm.lumen</string>
		<key>CFBundleURLSchemes</key>
		<array>
			<string>msauth.com.27pm.lumen</string>
		</array>
	</dict>
</array>

<key>LSApplicationQueriesSchemes</key>
<array>
	<string>msauth</string>
	<string>msauthv2</string>
	<string>msauthv3</string>
</array>
```

Then test Microsoft sign-in on device or simulator.

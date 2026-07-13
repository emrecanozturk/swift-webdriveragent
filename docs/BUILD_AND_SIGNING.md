# Build and Signing

SwiftWDA ships with generic public defaults. The Xcode project does not contain a private development team, provisioning profile, or organization-specific bundle id.

## Unsigned Build

Use this for CI and syntax-level validation:

```bash
xcodebuild \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

## Device Signing

Create a local config that is not committed:

```bash
cp Config/Signing.xcconfig.example Config/Signing.local.xcconfig
```

Edit these values:

```xcconfig
SWIFT_WDA_DEVELOPMENT_TEAM = YOURTEAMID
SWIFT_WDA_BUNDLE_PREFIX = com.example.automation
```

The project expands the bundle prefix into:

- `$(SWIFT_WDA_BUNDLE_PREFIX).IntegrationApp`
- `$(SWIFT_WDA_BUNDLE_PREFIX).WebDriverAgentRunner`

The installed XCTest runner app normally receives an `.xctrunner` suffix from Xcode at deployment time.

## Build for a Device

```bash
xcodebuild \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "id=$UDID" \
  -xcconfig Config/Signing.local.xcconfig \
  build-for-testing
```

## Launch for a Device

```bash
xcodebuild \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "id=$UDID" \
  -xcconfig Config/Signing.local.xcconfig \
  USE_PORT=8100 \
  MJPEG_SERVER_PORT=9100 \
  test-without-building
```

## Compatibility Bundle IDs

Some existing host stacks allowlist the historical WebDriverAgent runner bundle id. Prefer updating host allowlists to your own bundle prefix. If that is not immediately possible, you can temporarily set:

```xcconfig
SWIFT_WDA_RUNNER_BUNDLE_ID = com.facebook.WebDriverAgentRunner
```

That compatibility setting is optional and is not the public default.

## CI Behavior

CI uses `CODE_SIGNING_ALLOWED=NO` so public forks can validate the project without Apple developer credentials. Real-device deployment still requires a valid team, certificate, device registration, and provisioning entitlement set.

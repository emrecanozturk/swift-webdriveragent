# Compatibility

SwiftWDA aims to be compatible with host stacks that already know how to launch a WebDriverAgent-like XCTest runner.

## Preserved Contracts

- Project file: `WebDriverAgent.xcodeproj`
- Scheme: `WebDriverAgentRunner`
- Startup command: `xcodebuild ... test-without-building`
- Startup markers:
  - `ServerURLHere->http://<ip>:<port>`
  - `MJPEGServerURLHere->http://<ip>:<port>`
- Default HTTP port: `8100`
- Default MJPEG port: `9100`
- JSON response shape with `value` and optional `sessionId`

## Appium-Style Usage

If your client can attach to an already-running WDA server, launch SwiftWDA first and configure the client with the device URL:

```json
{
  "webDriverAgentUrl": "http://127.0.0.1:8100",
  "usePreinstalledWDA": true
}
```

Exact capability names vary by client and Appium driver version.

## Bundle ID Migration

Public defaults use the `io.github.swiftwda` prefix. Existing private systems often allowlist a historical runner bundle id. The safer long-term path is to update those allowlists to your own prefix:

```xcconfig
SWIFT_WDA_BUNDLE_PREFIX = com.example.automation
```

If you need a temporary compatibility bridge, see [Build and Signing](BUILD_AND_SIGNING.md).

## Behavior Differences from Upstream WDA

SwiftWDA is intentionally smaller than upstream WDA. It prioritizes the command surface used by automation platforms that need app lifecycle, source, screenshots, gestures, active app info, metrics, and smoke-testable health. Some deep private integrations from the larger Objective-C codebase are not reproduced.

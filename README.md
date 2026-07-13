# SwiftWDA

[![CI](https://github.com/emrecanozturk/swift-webdriveragent/actions/workflows/ci.yml/badge.svg)](https://github.com/emrecanozturk/swift-webdriveragent/actions/workflows/ci.yml)
[![CodeQL](https://github.com/emrecanozturk/swift-webdriveragent/actions/workflows/codeql.yml/badge.svg)](https://github.com/emrecanozturk/swift-webdriveragent/actions/workflows/codeql.yml)
[![Docs](https://github.com/emrecanozturk/swift-webdriveragent/actions/workflows/docs.yml/badge.svg)](https://github.com/emrecanozturk/swift-webdriveragent/actions/workflows/docs.yml)

SwiftWDA is a Swift-native, iOS-only XCTest runner that exposes a WebDriverAgent-compatible HTTP surface. It is designed for teams that want a small, auditable automation agent with explicit signing knobs, health checks, metrics, MJPEG fallback streaming, and a replaceable project path.

This project is independent and is not affiliated with Apple, Meta, Facebook, Appium, or the upstream WebDriverAgent project. The repository keeps the familiar `WebDriverAgent.xcodeproj` and `WebDriverAgentRunner` scheme names so existing host automation can adopt it with minimal path changes.

## Why

- Swift implementation with no vendored Objective-C WebDriverAgent tree.
- Drop-in startup contract: `xcodebuild ... -scheme WebDriverAgentRunner test-without-building`.
- Runtime markers: `ServerURLHere->http://...:8100` and `MJPEGServerURLHere->http://...:9100`.
- Generic public signing defaults: no embedded team id, provisioning profile, or private bundle prefix.
- XCTest-backed app lifecycle, gestures, source, screenshots, active app info, health checks, metrics, and native location simulation where the iOS runtime supports it.
- Public repository hygiene: CI, CodeQL, issue templates, security policy, wiki source, release checks, and smoke-test tooling.

## Repository Layout

```text
IntegrationApp/                 Minimal host app for the UI test bundle
WebDriverAgentRunner/           Swift XCTest runner and HTTP/MJPEG server
WebDriverAgent.xcodeproj/       Xcode project with WebDriverAgentRunner scheme
Config/                         Signing configuration examples
docs/                           Public documentation and analysis
docs/wiki/                      Source for the GitHub Wiki
examples/                       Curl and signing examples
scripts/                        Build, documentation, release, and wiki helpers
tools/                          Runtime smoke tests and project generator
```

## Quick Start

Clone the repository and build without signing first:

```bash
xcodebuild \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

For a real device, copy the signing template and set your own team and bundle prefix:

```bash
cp Config/Signing.xcconfig.example Config/Signing.local.xcconfig
open Config/Signing.local.xcconfig
```

Then build or launch with the config:

```bash
xcodebuild \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "id=$UDID" \
  -xcconfig Config/Signing.local.xcconfig \
  build-for-testing
```

When the runner is live, forward port 8100 from the device and check status:

```bash
iproxy 8100 8100 -u "$UDID"
curl http://127.0.0.1:8100/status
```

## Runtime Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `USE_PORT` | `8100` | HTTP server port printed in `ServerURLHere`. |
| `USE_IP` | Detected Wi-Fi IP, then `127.0.0.1` | Host-visible IP advertised in startup logs. |
| `MJPEG_SERVER_PORT` | `9100` | Device-side MJPEG fallback stream port. |
| `WDA_PRODUCT_BUNDLE_IDENTIFIER` | Built bundle identifier | Value returned in `/status` build metadata. |
| `UPGRADE_TIMESTAMP` | Empty | Optional deployment marker for warm-reuse workflows. |

## Main Endpoints

SwiftWDA implements the core endpoints commonly used by iOS automation stacks:

- `GET /status`
- `POST /session`, `GET /session/:id`, `DELETE /session/:id`
- `GET/POST /session/:id/appium/settings`
- `POST /session/:id/actions`
- `POST /session/:id/wda/tap`
- `POST /session/:id/wda/apps/launch`
- `POST /session/:id/wda/apps/activate`
- `POST /session/:id/wda/apps/terminate`
- `GET /wda/activeAppInfo`
- `GET /wda/device/info`
- `GET /wda/healthcheck`
- `GET/POST/DELETE /wda/simulatedLocation`
- `GET /source?format=json|xml`
- `GET /screenshot`
- `GET /metrics`

See [API Reference](docs/API_REFERENCE.md) for the full surface and payload notes.

## Documentation

- [Build and Signing](docs/BUILD_AND_SIGNING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [API Reference](docs/API_REFERENCE.md)
- [Feature Matrix](docs/FEATURE_MATRIX.md)
- [Compatibility Notes](docs/COMPATIBILITY.md)
- [Operations Guide](docs/OPERATIONS.md)
- [Security Model](docs/SECURITY_MODEL.md)
- [Implementation Analysis](docs/ANALYSIS.md)
- [Roadmap](ROADMAP.md)

The GitHub Wiki source lives in [docs/wiki](docs/wiki/Home.md). GitHub may require creating the first Wiki page in the web UI before the backing `.wiki.git` repository exists; after that one-time initialization, publish updates with `scripts/publish-wiki.sh`.

## Validation

Local public-readiness checks:

```bash
bash scripts/check-public-ready.sh
bash scripts/check-docs.sh
bash scripts/build-for-testing.sh
```

Runtime smoke tests after a live runner is reachable:

```bash
ruby tools/smoke_contract.rb http://127.0.0.1:8100
ruby tools/mjpeg_smoke.rb http://127.0.0.1:9100
ruby tools/stream_continuity_smoke.rb http://127.0.0.1:8100
```

## License

MIT. See [LICENSE](LICENSE).

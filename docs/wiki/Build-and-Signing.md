# Build and Signing

SwiftWDA uses generic bundle settings by default:

- `SWIFT_WDA_BUNDLE_PREFIX = io.github.swiftwda`
- `SWIFT_WDA_DEVELOPMENT_TEAM =`

Create `Config/Signing.local.xcconfig` from the example and set your own values. Do not commit local signing files.

Use `CODE_SIGNING_ALLOWED=NO` for CI builds and `-xcconfig Config/Signing.local.xcconfig` for device builds.

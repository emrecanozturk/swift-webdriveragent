# Quick Start

Build without signing:

```bash
xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing
```

For a real device:

```bash
cp Config/Signing.xcconfig.example Config/Signing.local.xcconfig
xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination "id=$UDID" -xcconfig Config/Signing.local.xcconfig build-for-testing
```

Forward the HTTP port and check status:

```bash
iproxy 8100 8100 -u "$UDID"
curl http://127.0.0.1:8100/status
```

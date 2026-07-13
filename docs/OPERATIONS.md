# Operations Guide

## Launch Checklist

1. Device is trusted by the host.
2. `xcrun devicectl list devices` shows the device as available.
3. Signing config has a real development team and unique bundle prefix.
4. `build-for-testing` succeeds.
5. `test-without-building` prints `ServerURLHere->`.
6. `curl /status` returns `ready: true`.
7. Runtime smoke tests pass for the target iOS version.

## Health Checks

```bash
curl http://127.0.0.1:8100/status
curl http://127.0.0.1:8100/wda/healthcheck
curl http://127.0.0.1:8100/metrics
```

## Smoke Tests

```bash
ruby tools/smoke_contract.rb http://127.0.0.1:8100
ruby tools/mjpeg_smoke.rb http://127.0.0.1:9100
ruby tools/stream_continuity_smoke.rb http://127.0.0.1:8100
```

The smoke tests intentionally exercise a real app foreground path instead of only checking an idle SpringBoard session.

## Troubleshooting

| Symptom | Likely Layer | First Check |
| --- | --- | --- |
| Device not listed | USB/CoreDevice | `xcrun devicectl list devices` |
| Build fails before signing | Xcode project | `xcodebuild -list` and CI build command |
| Build fails at signing | Apple signing | Team id, bundle prefix, profiles, device registration |
| No `ServerURLHere` marker | XCTest startup | Scheme, destination, test runner logs |
| `/status` not reachable | Transport | `iproxy`, Wi-Fi route, port mismatch |
| Source or screenshot slow | XCTest runtime | Foreground app state and device load |
| Location simulation unsupported | iOS runtime | `/wda/simulatedLocation` support payload |

## Production Rollout

Start with a canary group. Track:

- Startup success rate.
- Time to first `/status`.
- Command error rate from `/metrics`.
- Screenshot and source latency.
- Session reuse behavior.
- iOS version and device model distribution.

Keep the upstream or previous runner available during the first rollout so client systems can fail back quickly.

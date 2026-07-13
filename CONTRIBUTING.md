# Contributing

Thanks for helping improve SwiftWDA.

## Local Checks

Run these before opening a pull request:

```bash
bash scripts/check-public-ready.sh
bash scripts/check-docs.sh
bash scripts/build-for-testing.sh
```

If you change runtime behavior, also run the smoke tests against a real device:

```bash
ruby tools/smoke_contract.rb http://127.0.0.1:8100
ruby tools/mjpeg_smoke.rb http://127.0.0.1:9100
ruby tools/stream_continuity_smoke.rb http://127.0.0.1:8100
```

## Contribution Rules

- Do not commit signing certificates, provisioning profiles, local signing config, device UDIDs, or private host paths.
- Keep project defaults generic.
- Keep the `WebDriverAgentRunner` scheme unless the compatibility story is updated.
- Update docs when adding or removing endpoints.
- Add a runtime smoke note when behavior depends on a specific iOS or Xcode version.

## Pull Request Shape

A good PR includes:

- What changed.
- Why it changed.
- Device/iOS/Xcode versions used for validation.
- Build and smoke-test output summary.
- Any compatibility risks.

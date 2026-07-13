# Feature Matrix

This matrix describes the public repository state. Always validate on your own device fleet before production rollout.

## Implemented

| Area | Status | Notes |
| --- | --- | --- |
| Startup markers | Implemented | Prints `ServerURLHere->` and `MJPEGServerURLHere->`. |
| Session lifecycle | Implemented | One active session at a time. |
| App lifecycle | Implemented | Launch, activate, terminate by bundle id. |
| Active app info | Implemented | Foreground app heuristic based on XCTest application states. |
| Source tree | Implemented | JSON and XML output. |
| Element lookup | Implemented | Accessibility id, class name, predicate-like matching, and scoped XPath subset. |
| Screenshots | Implemented | Base64 PNG/JPEG response through XCTest screenshot APIs. |
| Gestures | Implemented | Common tap, pointer actions, and drag flows through XCTest coordinate APIs. |
| Alert handling | Implemented | Text, accept, dismiss, button listing, and first-launch auto handling. |
| Settings | Implemented | Appium-style settings endpoint. |
| Metrics | Implemented | Prometheus text endpoint. |
| Health check | Implemented | HTTP and XCTest responsiveness state. |
| MJPEG fallback | Implemented | Device-side listener on configurable port. |
| Native location simulation | Conditional | Available only when XCTest exposes the required runtime API. |

## Partial or Intentional Limits

| Area | Limit |
| --- | --- |
| XPath | Supports practical accessibility patterns, not full WebDriver XPath conformance. |
| Lock/unlock | Depends on runtime capability and platform restrictions. |
| Foreground app detection | XCTest state heuristics, not private SpringBoard introspection. |
| Video streaming | MJPEG fallback is included; high-performance H.264/WebRTC remains outside this repo. |
| Multi-session concurrency | Not a goal; use one runner per device. |

## Not Included

- Provisioning profiles, certificates, or team-specific signing material.
- Host-side device farm scheduler.
- iOS supervision or MDM policy management.
- Appium server wrapper.
- Private enterprise deployment automation.

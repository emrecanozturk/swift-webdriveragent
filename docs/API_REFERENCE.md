# API Reference

SwiftWDA follows the response shape used by WebDriverAgent-style clients: most JSON responses include `value` and, when relevant, `sessionId`.

## Status and Health

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/status` | Readiness, build metadata, session state, metrics summary. |
| `GET` | `/wda/healthcheck` | HTTP server and XCTest responsiveness check. |
| `GET` | `/metrics` | Prometheus text metrics. |

## Session

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/session` | Creates a session and optionally launches the requested bundle id. |
| `GET` | `/session/:id` | Returns the active session. |
| `DELETE` | `/session/:id` | Ends the active session. |
| `GET` | `/session/:id/appium/settings` | Reads runtime settings. |
| `POST` | `/session/:id/appium/settings` | Updates alert, MJPEG, and interaction settings. |

## Device and App Lifecycle

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/wda/activeAppInfo` | Best-effort foreground app info. |
| `GET` | `/wda/device/info` | Device and screen metadata. |
| `GET` | `/wda/device/performance` | Lightweight performance payload for a bundle id when available. |
| `POST` | `/session/:id/wda/apps/launch` | Launches an app by bundle id. |
| `POST` | `/session/:id/wda/apps/activate` | Activates an app by bundle id. |
| `POST` | `/session/:id/wda/apps/terminate` | Terminates an app by bundle id. |

## UI Interaction

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/session/:id/actions` | Pointer action support for common touch gestures. |
| `POST` | `/session/:id/wda/tap` | Coordinate tap. |
| `POST` | `/session/:id/wda/pressAndDragWithVelocity` | Drag/press gesture. |
| `POST` | `/session/:id/wda/keys` | Keyboard text input. |
| `POST` | `/session/:id/wda/keyboard/dismiss` | Keyboard dismissal. |
| `POST` | `/session/:id/wda/pressButton` | Hardware/software button abstraction where XCTest supports it. |

## Source and Elements

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/source?format=json` | JSON accessibility tree. |
| `GET` | `/source?format=xml` | XML accessibility tree. |
| `GET` | `/screenshot` | Base64 screenshot. |
| `POST` | `/session/:id/element` | Single element lookup. |
| `POST` | `/session/:id/elements` | Multiple element lookup. |
| `POST` | `/session/:id/element/:id/click` | Element click. |
| `POST` | `/session/:id/element/:id/value` | Element text input. |
| `POST` | `/session/:id/element/:id/clear` | Clear text-like element. |
| `GET` | `/session/:id/element/:id/attribute/:name` | Attribute lookup. |

## Alerts, Locking, and Orientation

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/session/:id/alert/text` | Reads alert text. |
| `POST` | `/session/:id/alert/text` | Types into alert text fields when present. |
| `POST` | `/session/:id/alert/accept` | Accepts the active alert. |
| `POST` | `/session/:id/alert/dismiss` | Dismisses the active alert. |
| `GET` | `/session/:id/wda/alert/buttons` | Returns alert buttons. |
| `GET` | `/session/:id/orientation` | Current orientation. |
| `GET` | `/session/:id/rotation` | Rotation payload. |
| `POST` | `/session/:id/rotation` | Attempts rotation change. |
| `GET` | `/session/:id/wda/locked` | Last known lock state. |
| `POST` | `/session/:id/wda/lock` | Attempts lock where runtime support exists. |
| `POST` | `/session/:id/wda/unlock` | Attempts unlock where runtime support exists. |

## Location Simulation

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/wda/simulatedLocation` | Returns support and current simulated location state. |
| `POST` | `/wda/simulatedLocation` | Sets latitude and longitude when XCTest runtime supports native simulation. |
| `DELETE` | `/wda/simulatedLocation` | Clears the simulated location cache and runtime state where supported. |

Native location simulation depends on XCTest runtime support. Older iOS runtimes may still need a host-side location simulation fallback.

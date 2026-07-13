# API and Compatibility

SwiftWDA preserves the host-facing launch contract used by WebDriverAgent-style stacks:

- `WebDriverAgent.xcodeproj`
- `WebDriverAgentRunner`
- `ServerURLHere->`
- `MJPEGServerURLHere->`
- HTTP port `8100`
- MJPEG port `9100`

Main endpoints include `/status`, `/session`, `/wda/activeAppInfo`, `/wda/device/info`, `/wda/healthcheck`, `/source`, `/screenshot`, `/metrics`, and app lifecycle routes.

# FAQ

## Is this upstream WebDriverAgent?

No. SwiftWDA is an independent Swift XCTest runner with a compatible command surface for common automation flows.

## Does it replace Appium?

No. It can be used by host automation or by clients that attach to an already-running WDA-compatible server.

## Can it run without signing?

CI can build without signing. Real-device launch requires valid Apple signing.

## Does it include high-performance video streaming?

It includes an MJPEG fallback stream. A production H.264/WebRTC stack is intentionally outside this repository.

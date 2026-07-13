# Architecture

SwiftWDA has four core parts:

- `IntegrationApp`: minimal UI test host app.
- `WebDriverAgentRunnerTests.swift`: XCTest entrypoint.
- `HTTPServer.swift`: Network.framework HTTP and MJPEG server.
- `WDAAgent.swift`: route handling and XCTest bridge.

The host launches the runner with Xcode, reads the startup marker, forwards ports if needed, and sends HTTP commands.

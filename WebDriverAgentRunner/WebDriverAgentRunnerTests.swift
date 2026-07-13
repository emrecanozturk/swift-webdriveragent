import XCTest

final class WebDriverAgentRunnerTests: XCTestCase {
    private var server: HTTPServer?
    private var mjpegServer: MJPEGServer?

    private var wdaListenPort: UInt16 {
        let raw = ProcessInfo.processInfo.environment["USE_PORT"] ?? "8100"
        return UInt16(raw) ?? 8100
    }

    override func tearDown() {
        server?.stop()
        server = nil
        mjpegServer?.stop()
        mjpegServer = nil
        super.tearDown()
    }

    func testRunner() throws {
        continueAfterFailure = false

        let agent = WDAAgent()
        let server = HTTPServer(port: wdaListenPort, connectionLimit: 8) { request in
            agent.handle(request)
        }
        try server.start()
        self.server = server

        let mjpegServer = MJPEGServer(
            port: agent.mjpegServerPort,
            connectionLimit: 3,
            settingsProvider: {
                agent.mjpegStreamSettings()
            },
            frameProvider: { _ in
                agent.mjpegFrame()
            }
        )
        try mjpegServer.start()
        self.mjpegServer = mjpegServer

        print("ServerURLHere->http://\(agent.advertisedIPAddress):\(wdaListenPort)")
        print("MJPEGServerURLHere->http://\(agent.advertisedIPAddress):\(agent.mjpegServerPort)")

        while true {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }
}

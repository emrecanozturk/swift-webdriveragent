import XCTest
import UIKit
import MediaPlayer
import AVFoundation
import CoreLocation
import Darwin
import ObjectiveC.runtime

final class WDAAgent {
    private enum AlertAction {
        case accept
        case dismiss
    }

    private struct SessionState {
        let id: String
        let createdAt: Date
        var requestedBundleId: String?
        var knownBundleIds: [String]
        var defaultAlertAction: String?
        var lastKnownForegroundBundleId: String?
    }

    private struct ElementSearchCandidate {
        let element: XCUIElement
        let appIndex: Int
        let sourceIndex: Int
        let matchPriority: Int
    }

    private let startedAt = Date()
    private let upgradeTimestamp = ProcessInfo.processInfo.environment["UPGRADE_TIMESTAMP"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    private let productBundleIdentifier = ProcessInfo.processInfo.environment["WDA_PRODUCT_BUNDLE_IDENTIFIER"]?.isEmpty == false
        ? ProcessInfo.processInfo.environment["WDA_PRODUCT_BUNDLE_IDENTIFIER"]!
        : (Bundle.main.bundleIdentifier ?? "io.github.swiftwda.WebDriverAgentRunner")
    var advertisedIPAddress: String {
        if let configured = normalizedEnvironmentValue("USE_IP") {
            return configured
        }
        return detectedWiFiIPAddress() ?? "127.0.0.1"
    }
    let mjpegServerPort: UInt16 = {
        let env = ProcessInfo.processInfo.environment
        let rawValue = env["MJPEG_SERVER_PORT"] ?? env["WDA_MJPEG_SERVER_PORT"] ?? "9100"
        return UInt16(rawValue) ?? 9100
    }()

    private var lifecycleState: AgentLifecycleState = .starting
    private var settings = AgentSettings()
    private var session: SessionState?
    private var elementCache: [String: XCUIElement] = [:]
    private var requestCount = 0
    private var errorCount = 0
    private var totalLatencyMs: Double = 0
    private var lastKnownLockedState = false
    private var lastFailureMessage: String?
    private let locationSimulation = LocationSimulationController()

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let start = CFAbsoluteTimeGetCurrent()
        let response: HTTPResponse

        if Thread.isMainThread {
            response = handleOnMain(request)
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var captured: HTTPResponse?
            DispatchQueue.main.async {
                captured = self.handleOnMain(request)
                semaphore.signal()
            }
            semaphore.wait()
            response = captured ?? jsonError(WDAErrorPayload(error: "unknown error", message: "No response produced", statusCode: 500))
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        DispatchQueue.main.async {
            self.requestCount += 1
            self.totalLatencyMs += elapsedMs
            if response.statusCode >= 400 {
                self.errorCount += 1
            }
        }
        return response
    }

    private func handleOnMain(_ request: HTTPRequest) -> HTTPResponse {
        if lifecycleState == .starting {
            lifecycleState = .idle
        }

        do {
            let response = try route(request)
            if response.statusCode < 400 {
                lastFailureMessage = nil
            }
            return response
        } catch {
            lifecycleState = .error
            lastFailureMessage = error.localizedDescription
            return jsonError(
                WDAErrorPayload(
                    error: "unknown error",
                    message: error.localizedDescription,
                    statusCode: 500
                )
            )
        }
    }

    private func route(_ request: HTTPRequest) throws -> HTTPResponse {
        let components = request.pathComponents

        if request.method == .options {
            return ok(NSNull(), sessionId: session?.id)
        }

        if request.method == .get && components == ["status"] {
            return ok(statusPayload(), sessionId: session?.id)
        }

        if request.method == .get && components == ["wda", "healthcheck"] {
            return ok(healthcheckPayload(), sessionId: session?.id)
        }

        if request.method == .post && components == ["wda", "homescreen"] {
            return homeScreen(sessionId: session?.id)
        }

        if request.method == .get && components == ["metrics"] {
            return HTTPResponse.text(prometheusMetricsPayload(), headers: ["Content-Type": "text/plain; version=0.0.4; charset=utf-8"])
        }

        if request.method == .post && components == ["session"] {
            return try createSession(from: request)
        }

        if request.method == .get && components == ["wda", "activeAppInfo"] {
            return ok(activeAppInfoPayload(), sessionId: session?.id)
        }

        if request.method == .get && components == ["wda", "device", "info"] {
            return ok(deviceInfoPayload(), sessionId: session?.id)
        }

        if request.method == .get && components == ["wda", "device", "performance"] {
            return ok(devicePerformancePayload(bundleId: request.queryItems["bundleId"]), sessionId: session?.id)
        }

        if request.method == .get && components == ["wda", "screen"] {
            return ok(screenPayload(), sessionId: session?.id)
        }

        if request.method == .get && components == ["source"] {
            return ok(sourcePayload(format: request.queryItems["format"] ?? "xml"), sessionId: session?.id)
        }

        if request.method == .get && components == ["screenshot"] {
            return ok(screenshotPayload(), sessionId: session?.id)
        }

        if request.method == .get && components == ["alert", "text"] {
            return alertText(sessionId: session?.id)
        }

        if request.method == .post && components == ["alert", "accept"] {
            return acceptAlert(from: request, sessionId: session?.id)
        }

        if request.method == .post && components == ["alert", "dismiss"] {
            return dismissAlert(from: request, sessionId: session?.id)
        }

        if request.method == .get && components == ["wda", "alert", "buttons"] {
            return alertButtons(sessionId: session?.id)
        }

        if request.method == .get && components == ["wda", "simulatedLocation"] {
            return getSimulatedLocation(sessionId: session?.id)
        }

        if request.method == .get && components == ["wda", "locked"] {
            return ok(lastKnownLockedState, sessionId: session?.id)
        }

        if request.method == .post && components == ["wda", "lock"] {
            return lock(sessionId: session?.id)
        }

        if request.method == .post && components == ["wda", "unlock"] {
            return unlock(sessionId: session?.id)
        }

        if request.method == .post && components == ["wda", "simulatedLocation"] {
            return setSimulatedLocation(from: request, sessionId: session?.id)
        }

        if request.method == .delete && components == ["wda", "simulatedLocation"] {
            return clearSimulatedLocation(sessionId: session?.id)
        }

        if request.method == .get && components == ["window", "size"] {
            return ok(windowSizePayload(), sessionId: session?.id)
        }

        if request.method == .get && components == ["window", "rect"] {
            return ok(windowRectPayload(), sessionId: session?.id)
        }

        guard components.count >= 2, components[0] == "session" else {
            return jsonError(WDAErrorPayload(error: "unknown command", message: "Unhandled route \(request.path)", statusCode: 404))
        }

        guard let currentSession = session, currentSession.id == components[1] else {
            return jsonError(WDAErrorPayload(error: "invalid session id", message: "Session \(components[1]) is not active", statusCode: 404))
        }

        let tail = Array(components.dropFirst(2))

        if request.method == .delete && tail.isEmpty {
            return deleteSession(currentSession)
        }

        if request.method == .get && tail.isEmpty {
            return ok(sessionPayload(currentSession), sessionId: currentSession.id)
        }

        switch (request.method, tail) {
        case (.get, ["appium", "settings"]):
            return ok(settings.values, sessionId: currentSession.id)
        case (.post, ["appium", "settings"]):
            return setSettings(from: request, sessionId: currentSession.id)
        case (.post, ["actions"]):
            return performActions(from: request, sessionId: currentSession.id)
        case (.post, ["url"]):
            return openURL(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "tap"]):
            return tap(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "pressAndDragWithVelocity"]):
            return drag(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "keys"]):
            return sendKeys(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "keyboard", "dismiss"]):
            return dismissKeyboard(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "pressButton"]):
            return pressButton(from: request, sessionId: currentSession.id)
        case (.get, ["wda", "device", "info"]):
            return ok(deviceInfoPayload(), sessionId: currentSession.id)
        case (.get, ["wda", "device", "performance"]):
            return ok(devicePerformancePayload(bundleId: request.queryItems["bundleId"]), sessionId: currentSession.id)
        case (.get, ["alert", "text"]):
            return alertText(sessionId: currentSession.id)
        case (.post, ["alert", "text"]):
            return setAlertText(from: request, sessionId: currentSession.id)
        case (.post, ["alert", "accept"]):
            return acceptAlert(from: request, sessionId: currentSession.id)
        case (.post, ["alert", "dismiss"]):
            return dismissAlert(from: request, sessionId: currentSession.id)
        case (.get, ["wda", "alert", "buttons"]):
            return alertButtons(sessionId: currentSession.id)
        case (.get, ["wda", "locked"]):
            return ok(lastKnownLockedState, sessionId: currentSession.id)
        case (.post, ["wda", "lock"]):
            return lock(sessionId: currentSession.id)
        case (.post, ["wda", "unlock"]):
            return unlock(sessionId: currentSession.id)
        case (.get, ["wda", "simulatedLocation"]):
            return getSimulatedLocation(sessionId: currentSession.id)
        case (.post, ["wda", "simulatedLocation"]):
            return setSimulatedLocation(from: request, sessionId: currentSession.id)
        case (.delete, ["wda", "simulatedLocation"]):
            return clearSimulatedLocation(sessionId: currentSession.id)
        case (.get, ["rotation"]):
            return ok(rotationPayload(), sessionId: currentSession.id)
        case (.post, ["rotation"]):
            return setRotation(from: request, sessionId: currentSession.id)
        case (.get, ["orientation"]):
            return ok(orientationPayload(), sessionId: currentSession.id)
        case (.get, ["window", "size"]):
            return ok(windowSizePayload(), sessionId: currentSession.id)
        case (.get, ["window", "rect"]):
            return ok(windowRectPayload(), sessionId: currentSession.id)
        case (.post, ["wda", "apps", "launch"]):
            return launchApp(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "apps", "activate"]):
            return activateApp(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "apps", "terminate"]):
            return terminateApp(from: request, sessionId: currentSession.id)
        case (.post, ["wda", "apps", "state"]):
            return appState(from: request, sessionId: currentSession.id)
        case (.post, ["element"]):
            return findElement(from: request, sessionId: currentSession.id, firstOnly: true)
        case (.post, ["elements"]):
            return findElement(from: request, sessionId: currentSession.id, firstOnly: false)
        default:
            break
        }

        if request.method == .post, tail.count == 3, tail[0] == "element", tail[2] == "click" {
            return clickElement(id: tail[1], sessionId: currentSession.id)
        }

        if request.method == .post, tail.count == 3, tail[0] == "element", tail[2] == "value" {
            return setElementValue(id: tail[1], from: request, sessionId: currentSession.id)
        }

        if request.method == .post, tail.count == 3, tail[0] == "element", tail[2] == "clear" {
            return clearElement(id: tail[1], sessionId: currentSession.id)
        }

        if request.method == .get, tail.count == 4, tail[0] == "element", tail[2] == "attribute" {
            return getElementAttribute(id: tail[1], name: tail[3], sessionId: currentSession.id)
        }

        if request.method == .post,
           tail.count == 4,
           tail[0] == "wda",
           tail[1] == "element",
           tail[3] == "keyboardInput" {
            return setElementValue(id: tail[2], from: request, sessionId: currentSession.id)
        }

        if request.method == .post,
           tail.count == 4,
           tail[0] == "wda",
           tail[1] == "element",
           tail[3] == "scrollTo" {
            return scrollElementToVisible(id: tail[2], sessionId: currentSession.id)
        }

        return jsonError(WDAErrorPayload(error: "unknown command", message: "Unhandled route \(request.path)", statusCode: 404))
    }

    private func createSession(from request: HTTPRequest) throws -> HTTPResponse {
        elementCache.removeAll()
        var merged = mergedCapabilities(from: request.jsonDictionary())
        let sessionId = UUID().uuidString.lowercased()
        let bundleId = stringValue(merged["bundleId"])
        let defaultAlertAction = stringValue(merged["defaultAlertAction"])
        applyBootstrapSettings(from: merged)

        var knownBundleIds = ["com.apple.springboard"]
        if let bundleId, !bundleId.isEmpty {
            knownBundleIds.insert(bundleId, at: 0)
        }

        session = SessionState(
            id: sessionId,
            createdAt: Date(),
            requestedBundleId: bundleId,
            knownBundleIds: knownBundleIds,
            defaultAlertAction: defaultAlertAction,
            lastKnownForegroundBundleId: bundleId
        )
        lifecycleState = .active

        if let bundleId,
           shouldLaunchApplication(using: merged) {
            let app = XCUIApplication(bundleIdentifier: bundleId)
            if let args = merged["arguments"] as? [String] {
                app.launchArguments = args
            }
            if let env = merged["environment"] as? [String: String] {
                app.launchEnvironment = env
            }
            launchOrActivate(app, bundleId: bundleId)
            session?.lastKnownForegroundBundleId = bundleId
        }

        if defaultAlertAction == nil {
            merged["defaultAlertAction"] = settings.values["defaultAlertAction"]
        }
        if merged["mjpegServerPort"] == nil {
            merged["mjpegServerPort"] = Int(mjpegServerPort)
        }

        return ok(
            [
                "sessionId": sessionId,
                "capabilities": merged,
            ],
            sessionId: sessionId
        )
    }

    private func deleteSession(_ currentSession: SessionState) -> HTTPResponse {
        lifecycleState = .cleaning
        if let bundleId = currentSession.requestedBundleId, !bundleId.isEmpty {
            let app = XCUIApplication(bundleIdentifier: bundleId)
            if app.state == .runningForeground {
                app.terminate()
            }
        }
        session = nil
        elementCache.removeAll()
        lifecycleState = .idle
        return ok(NSNull(), sessionId: nil)
    }

    private func setSettings(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        let incoming = body["settings"] as? [String: Any] ?? [:]
        settings.apply(incoming)
        if let action = stringValue(incoming["defaultAlertAction"]) {
            session?.defaultAlertAction = action
        }
        return ok(settings.values, sessionId: sessionId)
    }

    private func performActions(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        let actions = body["actions"] as? [[String: Any]] ?? []

        if let keySource = actions.first(where: { stringValue($0["type"]) == "key" }) {
            return performKeyActions(source: keySource, sessionId: sessionId)
        }

        if let pointerSource = actions.first(where: { stringValue($0["type"]) == "pointer" }) {
            return performPointerActions(source: pointerSource, sessionId: sessionId)
        }

        return jsonError(WDAErrorPayload(error: "invalid argument", message: "Unsupported W3C action payload", statusCode: 400), sessionId: sessionId)
    }

    private func performKeyActions(source: [String: Any], sessionId: String) -> HTTPResponse {
        let actions = source["actions"] as? [[String: Any]] ?? []
        var text = ""
        for action in actions where stringValue(action["type"]) == "keyDown" {
            text.append(mappedKey(stringValue(action["value"]) ?? ""))
        }
        guard !text.isEmpty else {
            return ok(NSNull(), sessionId: sessionId)
        }

        preferredTypingApplication().typeText(text)
        return ok(NSNull(), sessionId: sessionId)
    }

    private func performPointerActions(source: [String: Any], sessionId: String) -> HTTPResponse {
        let steps = source["actions"] as? [[String: Any]] ?? []
        var currentPoint: CGPoint?
        var isPressed = false

        for step in steps {
            let type = stringValue(step["type"]) ?? ""
            switch type {
            case "pointerMove":
                let x = doubleValue(step["x"])
                let y = doubleValue(step["y"])
                let nextPoint = CGPoint(x: x, y: y)
                if isPressed, let start = currentPoint {
                    coordinate(at: start).press(forDuration: 0.01, thenDragTo: coordinate(at: nextPoint))
                    isPressed = false
                }
                currentPoint = nextPoint
            case "pointerDown":
                isPressed = true
            case "pause":
                let duration = max(0.01, doubleValue(step["duration"]) / 1000.0)
                if isPressed, let point = currentPoint {
                    coordinate(at: point).press(forDuration: duration)
                    isPressed = false
                } else {
                    RunLoop.current.run(until: Date().addingTimeInterval(duration))
                }
            case "pointerUp":
                if isPressed, let point = currentPoint {
                    coordinate(at: point).tap()
                    isPressed = false
                }
            default:
                continue
            }
        }

        return ok(NSNull(), sessionId: sessionId)
    }

    private func tap(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        coordinate(at: CGPoint(x: doubleValue(body["x"]), y: doubleValue(body["y"]))).tap()
        return ok(NSNull(), sessionId: sessionId)
    }

    private func drag(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        let start = CGPoint(x: doubleValue(body["fromX"]), y: doubleValue(body["fromY"]))
        let end = CGPoint(x: doubleValue(body["toX"]), y: doubleValue(body["toY"]))
        let pressDuration = max(0.01, doubleValue(body["pressDuration"]))
        coordinate(at: start).press(forDuration: pressDuration, thenDragTo: coordinate(at: end))
        return ok(NSNull(), sessionId: sessionId)
    }

    private func sendKeys(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        let value = body["value"]
        let text: String
        if let array = value as? [String] {
            text = array.joined()
        } else {
            text = stringValue(value) ?? ""
        }
        preferredTypingApplication().typeText(text)
        return ok(NSNull(), sessionId: sessionId)
    }

    private func pressButton(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let name = stringValue(request.jsonDictionary()["name"])?.lowercased()
        switch name {
        case "home":
            return homeScreen(sessionId: sessionId)
        case "volumeup":
            guard pressVolumeButton(increment: true) else {
                return jsonError(
                    WDAErrorPayload(
                        error: "unsupported operation",
                        message: "Volume Up button is unavailable on this runtime",
                        statusCode: 500
                    ),
                    sessionId: sessionId
                )
            }
            return ok(NSNull(), sessionId: sessionId)
        case "volumedown":
            guard pressVolumeButton(increment: false) else {
                return jsonError(
                    WDAErrorPayload(
                        error: "unsupported operation",
                        message: "Volume Down button is unavailable on this runtime",
                        statusCode: 500
                    ),
                    sessionId: sessionId
                )
            }
            return ok(NSNull(), sessionId: sessionId)
        default:
            return jsonError(
                WDAErrorPayload(
                    error: "unsupported operation",
                    message: "Only home, volumeUp and volumeDown buttons are supported",
                    statusCode: 400
                ),
                sessionId: sessionId
            )
        }
    }

    private func homeScreen(sessionId: String?) -> HTTPResponse {
        XCUIDevice.shared.press(.home)
        session?.lastKnownForegroundBundleId = "com.apple.springboard"
        return ok(NSNull(), sessionId: sessionId)
    }

    private func lock(sessionId: String?) -> HTTPResponse {
        guard pressLockButton() else {
            return jsonError(WDAErrorPayload(error: "unsupported operation", message: "Lock button API is unavailable on this XCTest runtime", statusCode: 500), sessionId: sessionId)
        }
        lastKnownLockedState = true
        return ok(NSNull(), sessionId: sessionId)
    }

    private func unlock(sessionId: String?) -> HTTPResponse {
        _ = pressLockButton()
        XCUIDevice.shared.press(.home)
        let springboard = springboardApplication()
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        lastKnownLockedState = false
        return ok(NSNull(), sessionId: sessionId)
    }

    private func setRotation(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        let z = Int(doubleValue(body["z"]))

        switch z {
        case 0:
            XCUIDevice.shared.orientation = .portrait
        case 90:
            XCUIDevice.shared.orientation = .landscapeLeft
        case 180:
            XCUIDevice.shared.orientation = .portraitUpsideDown
        case 270:
            XCUIDevice.shared.orientation = .landscapeRight
        default:
            return jsonError(WDAErrorPayload(error: "invalid argument", message: "Unsupported z rotation \(z)", statusCode: 400), sessionId: sessionId)
        }

        return ok(NSNull(), sessionId: sessionId)
    }

    private func launchApp(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        let bundleId = stringValue(body["bundleId"]) ?? ""
        guard !bundleId.isEmpty else {
            return jsonError(WDAErrorPayload(error: "invalid argument", message: "bundleId is required", statusCode: 400), sessionId: sessionId)
        }
        let app = XCUIApplication(bundleIdentifier: bundleId)
        if let args = body["arguments"] as? [String] {
            app.launchArguments = args
        }
        if let env = body["environment"] as? [String: String] {
            app.launchEnvironment = env
        }
        launchOrActivate(app, bundleId: bundleId)
        return ok(NSNull(), sessionId: sessionId)
    }

    private func activateApp(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let bundleId = stringValue(request.jsonDictionary()["bundleId"]) ?? ""
        guard !bundleId.isEmpty else {
            return jsonError(WDAErrorPayload(error: "invalid argument", message: "bundleId is required", statusCode: 400), sessionId: sessionId)
        }
        let app = XCUIApplication(bundleIdentifier: bundleId)
        activateOrFallbackLaunch(app, bundleId: bundleId)
        return ok(NSNull(), sessionId: sessionId)
    }

    private func terminateApp(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let bundleId = stringValue(request.jsonDictionary()["bundleId"]) ?? ""
        guard !bundleId.isEmpty else {
            return jsonError(WDAErrorPayload(error: "invalid argument", message: "bundleId is required", statusCode: 400), sessionId: sessionId)
        }
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate()
        if session?.lastKnownForegroundBundleId == bundleId {
            session?.lastKnownForegroundBundleId = "com.apple.springboard"
        }
        return ok(true, sessionId: sessionId)
    }

    private func appState(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let bundleId = stringValue(request.jsonDictionary()["bundleId"]) ?? ""
        guard !bundleId.isEmpty else {
            return jsonError(WDAErrorPayload(error: "invalid argument", message: "bundleId is required", statusCode: 400), sessionId: sessionId)
        }

        track(bundleId: bundleId)
        let app = XCUIApplication(bundleIdentifier: bundleId)
        return ok(app.state.rawValue, sessionId: sessionId)
    }

    private func getSimulatedLocation(sessionId: String?) -> HTTPResponse {
        switch locationSimulation.getSimulatedLocation() {
        case let .success(location):
            return ok(locationPayload(for: location), sessionId: sessionId)
        case let .failure(error):
            return jsonError(WDAErrorPayload(error: error.errorName, message: error.message, statusCode: error.statusCode), sessionId: sessionId)
        }
    }

    private func setSimulatedLocation(from request: HTTPRequest, sessionId: String?) -> HTTPResponse {
        let body = request.jsonDictionary()
        guard let latitude = numericValue(body["latitude"]),
              let longitude = numericValue(body["longitude"]) else {
            return jsonError(WDAErrorPayload(error: "invalid argument", message: "Both latitude and longitude must be provided", statusCode: 400), sessionId: sessionId)
        }

        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            return jsonError(WDAErrorPayload(error: "invalid argument", message: "Latitude must be between -90 and 90, longitude must be between -180 and 180", statusCode: 400), sessionId: sessionId)
        }

        let altitude = numericValue(body["altitude"]) ?? 0
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: Date()
        )

        switch locationSimulation.setSimulatedLocation(location) {
        case let .success(appliedLocation):
            return ok(locationPayload(for: appliedLocation), sessionId: sessionId)
        case let .failure(error):
            return jsonError(WDAErrorPayload(error: error.errorName, message: error.message, statusCode: error.statusCode), sessionId: sessionId)
        }
    }

    private func clearSimulatedLocation(sessionId: String?) -> HTTPResponse {
        switch locationSimulation.clearSimulatedLocation() {
        case .success:
            return ok(NSNull(), sessionId: sessionId)
        case let .failure(error):
            return jsonError(WDAErrorPayload(error: error.errorName, message: error.message, statusCode: error.statusCode), sessionId: sessionId)
        }
    }

    private func findElement(from request: HTTPRequest, sessionId: String, firstOnly: Bool) -> HTTPResponse {
        let body = request.jsonDictionary()
        let using = stringValue(body["using"]) ?? ""
        let value = stringValue(body["value"]) ?? ""

        let elements = locateElements(using: using, value: value)
        if firstOnly {
            guard let element = elements.first else {
                return jsonError(WDAErrorPayload(error: "no such element", message: "Unable to find an element using '\(using)', value '\(value)'", statusCode: 404), sessionId: sessionId)
            }
            return ok(cache(element: element), sessionId: sessionId)
        }
        return ok(elements.map(cache(element:)), sessionId: sessionId)
    }

    private func clickElement(id: String, sessionId: String) -> HTTPResponse {
        guard let element = elementCache[id] else {
            return jsonError(WDAErrorPayload(error: "stale element reference", message: "Element \(id) is not cached", statusCode: 404), sessionId: sessionId)
        }
        tapElement(element)
        return ok(NSNull(), sessionId: sessionId)
    }

    private func getElementAttribute(id: String, name: String, sessionId: String) -> HTTPResponse {
        guard let element = elementCache[id] else {
            return jsonError(WDAErrorPayload(error: "stale element reference", message: "Element \(id) is not cached", statusCode: 404), sessionId: sessionId)
        }
        return ok(attributeValue(name: name, for: element) ?? NSNull(), sessionId: sessionId)
    }

    private func setElementValue(id: String, from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        guard let element = elementCache[id] else {
            return jsonError(WDAErrorPayload(error: "stale element reference", message: "Element \(id) is not cached", statusCode: 404), sessionId: sessionId)
        }

        let body = request.jsonDictionary()
        let rawValue = body["value"] ?? body["text"]
        let textToType: String
        if let array = rawValue as? [String] {
            textToType = array.joined()
        } else {
            textToType = stringValue(rawValue) ?? ""
        }

        if rawValue == nil {
            return jsonError(
                WDAErrorPayload(
                    error: "invalid argument",
                    message: "Neither 'value' nor 'text' parameter is provided",
                    statusCode: 400
                ),
                sessionId: sessionId
            )
        }

        if element.elementType == .slider {
            guard let position = numericValue(rawValue), (0.0...1.0).contains(position) else {
                return jsonError(
                    WDAErrorPayload(
                        error: "invalid argument",
                        message: "Value of slider should be in 0..1 range",
                        statusCode: 400
                    ),
                    sessionId: sessionId
                )
            }
            element.adjust(toNormalizedSliderPosition: CGFloat(position))
            return ok(NSNull(), sessionId: sessionId)
        }

        if element.elementType == .pickerWheel {
            element.adjust(toPickerWheelValue: textToType)
            return ok(NSNull(), sessionId: sessionId)
        }

        focus(element)
        if boolValue(body["replace"]) == true || boolValue(body["clear"]) == true {
            _ = clearText(in: element)
        }
        element.typeText(textToType)
        return ok(NSNull(), sessionId: sessionId)
    }

    private func clearElement(id: String, sessionId: String) -> HTTPResponse {
        guard let element = elementCache[id] else {
            return jsonError(WDAErrorPayload(error: "stale element reference", message: "Element \(id) is not cached", statusCode: 404), sessionId: sessionId)
        }

        guard clearText(in: element) else {
            return jsonError(
                WDAErrorPayload(
                    error: "invalid element state",
                    message: "Unable to clear the target element",
                    statusCode: 400
                ),
                sessionId: sessionId
            )
        }

        return ok(NSNull(), sessionId: sessionId)
    }

    private func statusPayload() -> [String: Any] {
        let uptimeMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let avgLatency = requestCount == 0 ? 0 : Int(totalLatencyMs / Double(requestCount))
        let activeBundle = activeBundleIdentifier()
        let locationSupport = locationSimulation.supportInfo()
        var buildInfo: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: startedAt),
            "productBundleIdentifier": productBundleIdentifier,
            "version": "1.0.0",
        ]
        if let upgradeTimestamp, !upgradeTimestamp.isEmpty {
            buildInfo["upgradedAt"] = upgradeTimestamp
        }
        return [
            "ready": true,
            "message": "SwiftWDA is ready to accept commands",
            "state": "success",
            "agent": [
                "name": "SwiftWDA",
                "implementation": "swift-native",
                "mode": "drop-in-replacement",
                "uptimeMs": uptimeMs,
            ],
            "sessionState": lifecycleState.rawValue,
            "sessionId": session?.id as Any,
            "metrics": [
                "requestCount": requestCount,
                "avgLatencyMs": avgLatency,
                "errorCount": errorCount,
            ],
            "os": [
                "name": UIDevice.current.systemName,
                "version": UIDevice.current.systemVersion,
            ],
            "build": buildInfo,
            "diagnostics": [
                "lastFailureMessage": lastFailureMessage as Any,
                "canLockDevice": canLockDevice(),
                "locationSimulation": locationSupport.payload(),
            ],
            "mjpeg": [
                "mjpegServerPort": Int(mjpegServerPort),
                "framerate": settings.mjpegServerFramerate,
                "screenshotQuality": settings.mjpegServerScreenshotQuality,
                "scalingFactor": settings.mjpegScalingFactor,
                "fixOrientation": settings.mjpegFixOrientation,
            ],
            "ios": [
                "activeBundleId": activeBundle as Any,
                "ip": advertisedIPAddress,
            ],
        ]
    }

    private func healthcheckPayload() -> [String: Any] {
        let foregroundApps = queryApplicationDescriptors().filter { $0.application.state == .runningForeground }.map(\.bundleId)
        let locationSupport = locationSimulation.supportInfo()
        return [
            "ready": true,
            "sessionActive": session != nil,
            "sessionState": lifecycleState.rawValue,
            "activeBundleId": activeBundleIdentifier() as Any,
            "foregroundBundleIds": foregroundApps,
            "xcuitestResponsive": rootElementForInspection().exists,
            "lockCapabilityAvailable": canLockDevice(),
            "mjpegServerPort": Int(mjpegServerPort),
            "lastFailureMessage": lastFailureMessage as Any,
            "locationSimulation": locationSupport.payload(),
        ]
    }

    private func sessionPayload(_ currentSession: SessionState) -> [String: Any] {
        let locationSupport = locationSimulation.supportInfo()
        return [
            "id": currentSession.id,
            "createdAt": ISO8601DateFormatter().string(from: currentSession.createdAt),
            "requestedBundleId": currentSession.requestedBundleId as Any,
            "knownBundleIds": currentSession.knownBundleIds,
            "defaultAlertAction": currentSession.defaultAlertAction as Any,
            "mjpegServerPort": Int(mjpegServerPort),
            "activeBundleId": activeBundleIdentifier() as Any,
            "locationSimulation": locationSupport.payload(),
        ]
    }

    private func screenPayload() -> [String: Any] {
        let bounds = UIScreen.main.bounds
        return [
            "width": bounds.width,
            "height": bounds.height,
            "screenSize": [
                "width": bounds.width,
                "height": bounds.height,
            ],
            "statusBarSize": [
                "width": 0,
                "height": 0,
            ],
            "scale": UIScreen.main.scale,
        ]
    }

    private func windowSizePayload() -> [String: Any] {
        let bounds = UIScreen.main.bounds
        return [
            "width": bounds.width,
            "height": bounds.height,
        ]
    }

    private func windowRectPayload() -> [String: Any] {
        let bounds = UIScreen.main.bounds
        return [
            "x": bounds.origin.x,
            "y": bounds.origin.y,
            "width": bounds.width,
            "height": bounds.height,
        ]
    }

    private func sourcePayload(format: String) -> Any {
        let root = rootElementForInspection()
        let tree = ElementTreeBuilder.build(from: root, maxDepth: settings.snapshotMaxDepth)
        if format.lowercased() == "json" {
            return tree.toJSON()
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <AppiumAUT>
        \(tree.toXML(indentation: "  "))
        </AppiumAUT>
        """
    }

    private func screenshotPayload() -> String {
        XCUIScreen.main.screenshot().pngRepresentation.base64EncodedString()
    }

    private func activeAppInfoPayload() -> [String: Any] {
        let bundleId = activeBundleIdentifier()
        return [
            "pid": 0,
            "bundleId": bundleId as Any,
            "name": bundleId as Any,
            "processArguments": [
                "args": [],
                "env": [:],
            ],
        ]
    }

    private func deviceInfoPayload() -> [String: Any] {
        let currentDevice = UIDevice.current
        let locale = Locale.autoupdatingCurrent.identifier
        let timeZone = TimeZone.current.identifier
        let style: String

        switch UIScreen.main.traitCollection.userInterfaceStyle {
        case .light:
            style = "light"
        case .dark:
            style = "dark"
        case .unspecified:
            style = "automatic"
        @unknown default:
            style = "unknown"
        }

        return [
            "currentLocale": locale,
            "timeZone": timeZone,
            "name": currentDevice.name,
            "model": currentDevice.model,
            "systemName": currentDevice.systemName,
            "systemVersion": currentDevice.systemVersion,
            "uuid": currentDevice.identifierForVendor?.uuidString ?? "unknown",
            "userInterfaceIdiom": currentDevice.userInterfaceIdiom.rawValue,
            "userInterfaceStyle": style,
            "isSimulator": {
#if targetEnvironment(simulator)
                true
#else
                false
#endif
            }(),
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        ]
    }

    private func devicePerformancePayload(bundleId: String?) -> [String: Any] {
        let currentDevice = UIDevice.current
        let previousBatteryMonitoring = currentDevice.isBatteryMonitoringEnabled
        currentDevice.isBatteryMonitoringEnabled = true

        let batteryLevel: Any
        if currentDevice.batteryLevel >= 0 {
            batteryLevel = Int((currentDevice.batteryLevel * 100).rounded())
        } else {
            batteryLevel = NSNull()
        }

        currentDevice.isBatteryMonitoringEnabled = previousBatteryMonitoring
        let totalMemoryKb = Int(ProcessInfo.processInfo.physicalMemory / 1024)

        return [
            "source": "wda-native-limited",
            "bundleId": bundleId as Any,
            "supportsRealtimeProcessMetrics": false,
            "limitationReason": "XCTest/WebDriverAgent cannot access host sysmontap counters or other apps' real-time CPU and memory from the runner sandbox.",
            "cpuUsage": 0,
            "appCpuUsage": 0,
            "appMemoryUsage": 0,
            "totalMemoryUsage": 0,
            "totalMemory": totalMemoryKb,
            "batteryLevel": batteryLevel,
            "batteryState": currentDevice.batteryState.rawValue,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "os": [
                "name": currentDevice.systemName,
                "version": currentDevice.systemVersion,
            ],
        ]
    }

    private func rotationPayload() -> [String: Any] {
        let orientation = XCUIDevice.shared.orientation
        let z: Int
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            z = 90
        case .portraitUpsideDown:
            z = 180
        default:
            z = 0
        }
        return ["x": 0, "y": 0, "z": z]
    }

    private func orientationPayload() -> String {
        let z = Int(doubleValue(rotationPayload()["z"]))
        return z == 0 ? "PORTRAIT" : "LANDSCAPE"
    }

    private func ok(_ value: Any, sessionId: String?) -> HTTPResponse {
        let payload: [String: Any] = [
            "sessionId": sessionId as Any,
            "value": value,
        ]
        return HTTPResponse.json(payload)
    }

    private func jsonError(_ error: WDAErrorPayload, sessionId: String? = nil) -> HTTPResponse {
        let payload: [String: Any] = [
            "sessionId": sessionId as Any,
            "value": [
                "error": error.error,
                "message": error.message,
                "traceback": "",
            ],
        ]
        return HTTPResponse.json(payload, statusCode: error.statusCode)
    }

    private func mergedCapabilities(from body: [String: Any]) -> [String: Any] {
        let caps = body["capabilities"] as? [String: Any] ?? [:]
        var merged = caps["alwaysMatch"] as? [String: Any] ?? [:]
        if let firstMatch = (caps["firstMatch"] as? [[String: Any]])?.first {
            for (key, value) in firstMatch where merged[key] == nil {
                merged[key] = value
            }
        }

        return Dictionary(uniqueKeysWithValues: merged.map { key, value in
            let normalized = key.hasPrefix("appium:") ? String(key.dropFirst("appium:".count)) : key
            return (normalized, value)
        })
    }

    private func shouldLaunchApplication(using capabilities: [String: Any]) -> Bool {
        if let autoLaunch = boolValue(capabilities["autoLaunch"]) {
            return autoLaunch
        }
        return true
    }

    private func track(bundleId: String) {
        if !(session?.knownBundleIds.contains(bundleId) ?? false) {
            session?.knownBundleIds.insert(bundleId, at: 0)
        }
    }

    private func remember(bundleId: String) {
        track(bundleId: bundleId)
        session?.lastKnownForegroundBundleId = bundleId
    }

    private func locateElements(using: String, value: String) -> [XCUIElement] {
        let strategy = using.lowercased()
        let descriptors = queryApplicationDescriptors()
        var candidates: [ElementSearchCandidate] = []

        for (appIndex, descriptor) in descriptors.enumerated() {
            let elements = searchableElements(in: descriptor.application)
            for (sourceIndex, element) in elements.enumerated() {
                guard let matchPriority = matchPriority(for: element, using: strategy, value: value) else {
                    continue
                }
                candidates.append(
                    ElementSearchCandidate(
                        element: element,
                        appIndex: appIndex,
                        sourceIndex: sourceIndex,
                        matchPriority: matchPriority
                    )
                )
            }
        }

        return candidates
            .sorted(by: isHigherPriorityElement(_:_:))
            .map(\.element)
    }

    private func searchableElements(in application: XCUIApplication) -> [XCUIElement] {
        [application] + application.descendants(matching: .any).allElementsBoundByIndex
    }

    private func matchPriority(for element: XCUIElement, using strategy: String, value: String) -> Int? {
        switch strategy {
        case "accessibility id", "id", "name":
            let identifier = element.identifier
            if !identifier.isEmpty, identifier == value {
                return 0
            }

            let label = element.label
            if !label.isEmpty, label == value {
                return 1
            }

            let elementValue = ElementTreeBuilder.stringify(element.value)
            if !elementValue.isEmpty, elementValue == value {
                return 2
            }

            return nil

        case "class name":
            guard let elementType = ElementTypeMapper.elementType(from: value) else {
                return nil
            }
            return element.elementType == elementType ? 0 : nil

        case "predicate string":
            let predicate = NSPredicate(format: value)
            return predicate.evaluate(with: element) ? 0 : nil

        case "xpath":
            guard let query = XPathQuery.parse(value) else {
                return nil
            }
            let node = ElementTreeBuilder.build(from: element, maxDepth: 0)
            return query.matches(node) ? 0 : nil

        default:
            return nil
        }
    }

    private func isHigherPriorityElement(_ lhs: ElementSearchCandidate, _ rhs: ElementSearchCandidate) -> Bool {
        if lhs.matchPriority != rhs.matchPriority {
            return lhs.matchPriority < rhs.matchPriority
        }

        let lhsInteraction = interactionPriority(for: lhs.element)
        let rhsInteraction = interactionPriority(for: rhs.element)
        if lhsInteraction != rhsInteraction {
            return lhsInteraction < rhsInteraction
        }

        let lhsType = elementTypePriority(lhs.element.elementType)
        let rhsType = elementTypePriority(rhs.element.elementType)
        if lhsType != rhsType {
            return lhsType < rhsType
        }

        if lhs.appIndex != rhs.appIndex {
            return lhs.appIndex < rhs.appIndex
        }

        return lhs.sourceIndex < rhs.sourceIndex
    }

    private func interactionPriority(for element: XCUIElement) -> Int {
        let visible = element.exists && !element.frame.isEmpty
        let interactive = isInteractiveElementType(element.elementType)

        if element.isHittable && interactive {
            return 0
        }
        if element.isHittable {
            return 1
        }
        if visible && interactive {
            return 2
        }
        if visible {
            return 3
        }
        return 4
    }

    private func elementTypePriority(_ type: XCUIElement.ElementType) -> Int {
        switch type {
        case .button:
            return 0
        case .switch, .slider, .textField, .secureTextField, .pickerWheel, .cell, .key:
            return 1
        case .alert, .sheet:
            return 2
        case .other, .image:
            return 3
        case .staticText:
            return 4
        case .window:
            return 5
        case .application:
            return 6
        default:
            return 7
        }
    }

    private func tapTargetPriority(for element: XCUIElement) -> Int {
        let visible = element.exists && !element.frame.isEmpty
        let interactive = isInteractiveElementType(element.elementType)

        if interactive && element.isHittable {
            return 0
        }
        if interactive && visible {
            return 1
        }
        if element.isHittable {
            return 2
        }
        if visible {
            return 3
        }
        return 4
    }

    private func isInteractiveElementType(_ type: XCUIElement.ElementType) -> Bool {
        switch type {
        case .button, .cell, .switch, .slider, .textField, .secureTextField, .pickerWheel, .key, .link:
            return true
        default:
            return false
        }
    }

    private func tapElement(_ element: XCUIElement) {
        if let descendant = bestDescendantTapTarget(in: element),
           shouldPreferDescendantTapTarget(descendant, over: element) {
            tapCandidate(descendant)
            return
        }

        if element.exists && element.isHittable {
            element.tap()
            return
        }

        if let descendant = bestDescendantTapTarget(in: element) {
            tapCandidate(descendant)
            return
        }

        if !element.frame.isEmpty {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }

        element.tap()
    }

    private func bestDescendantTapTarget(in element: XCUIElement) -> XCUIElement? {
        let descendants = element.descendants(matching: .any).allElementsBoundByIndex
        return descendants.sorted {
            let lhsInteraction = tapTargetPriority(for: $0)
            let rhsInteraction = tapTargetPriority(for: $1)
            if lhsInteraction != rhsInteraction {
                return lhsInteraction < rhsInteraction
            }
            return elementTypePriority($0.elementType) < elementTypePriority($1.elementType)
        }.first
    }

    private func shouldPreferDescendantTapTarget(_ descendant: XCUIElement, over element: XCUIElement) -> Bool {
        let descendantPriority = tapTargetPriority(for: descendant)
        let elementPriority = tapTargetPriority(for: element)
        if descendantPriority < elementPriority {
            return true
        }

        let descendantInteractive = isInteractiveElementType(descendant.elementType)
        let elementInteractive = isInteractiveElementType(element.elementType)
        if descendantInteractive && !elementInteractive {
            return true
        }

        return false
    }

    private func tapCandidate(_ element: XCUIElement) {
        if element.exists && element.isHittable {
            element.tap()
            return
        }

        if !element.frame.isEmpty {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }

        element.tap()
    }

    private func cache(element: XCUIElement) -> [String: Any] {
        let id = UUID().uuidString.lowercased()
        elementCache[id] = element
        return [
            "ELEMENT": id,
            "element-6066-11e4-a52e-4f735466cecf": id,
        ]
    }

    private func attributeValue(name: String, for element: XCUIElement) -> Any? {
        switch name.lowercased() {
        case "label":
            return element.label
        case "value":
            return ElementTreeBuilder.stringify(element.value)
        case "name":
            return element.identifier.isEmpty ? element.label : element.identifier
        case "type":
            return ElementTypeMapper.fullName(for: element.elementType)
        case "enabled":
            return element.isEnabled
        case "selected":
            return element.isSelected
        case "visible":
            return element.exists && !element.frame.isEmpty
        case "hittable":
            return element.isHittable
        default:
            return nil
        }
    }

    private func mappedKey(_ value: String) -> String {
        switch value {
        case "\u{0008}":
            return "\u{0008}"
        case "\u{000D}":
            return "\n"
        default:
            return value
        }
    }

    private func alertText(sessionId: String?) -> HTTPResponse {
        guard let alert = firstVisibleAlertElement() else {
            return noSuchAlertResponse(sessionId: sessionId)
        }

        let texts = alertTextComponents(in: alert)
        return ok(texts.joined(separator: "\n"), sessionId: sessionId)
    }

    private func setAlertText(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        guard let alert = firstVisibleAlertElement() else {
            return noSuchAlertResponse(sessionId: sessionId)
        }

        let value = request.jsonDictionary()["value"]
        let text: String
        if let values = value as? [String] {
            text = values.joined()
        } else {
            text = stringValue(value) ?? ""
        }

        guard value != nil else {
            return jsonError(
                WDAErrorPayload(error: "invalid argument", message: "Missing 'value' parameter", statusCode: 400),
                sessionId: sessionId
            )
        }

        let inputFields = (
            alert.descendants(matching: .textField).allElementsBoundByIndex +
            alert.descendants(matching: .secureTextField).allElementsBoundByIndex +
            alert.descendants(matching: .searchField).allElementsBoundByIndex +
            alert.descendants(matching: .textView).allElementsBoundByIndex
        ).filter { $0.exists }

        guard let input = inputFields.first else {
            return jsonError(
                WDAErrorPayload(
                    error: "unsupported operation",
                    message: "The current alert does not expose a text input field",
                    statusCode: 400
                ),
                sessionId: sessionId
            )
        }

        focus(input)
        input.typeText(text)
        return ok(NSNull(), sessionId: sessionId)
    }

    private func acceptAlert(from request: HTTPRequest, sessionId: String?) -> HTTPResponse {
        performAlertAction(.accept, from: request, sessionId: sessionId)
    }

    private func dismissAlert(from request: HTTPRequest, sessionId: String?) -> HTTPResponse {
        performAlertAction(.dismiss, from: request, sessionId: sessionId)
    }

    private func alertButtons(sessionId: String?) -> HTTPResponse {
        guard let alert = firstVisibleAlertElement() else {
            return noSuchAlertResponse(sessionId: sessionId)
        }

        let labels = alert.descendants(matching: .button).allElementsBoundByIndex.compactMap { element -> String? in
            let label = preferredLabel(for: element)
            return label.isEmpty ? nil : label
        }

        return ok(Array(NSOrderedSet(array: labels)) as? [String] ?? labels, sessionId: sessionId)
    }

    private func performAlertAction(_ action: AlertAction, from request: HTTPRequest, sessionId: String?) -> HTTPResponse {
        guard let alert = firstVisibleAlertElement() else {
            return noSuchAlertResponse(sessionId: sessionId)
        }

        let requestedName = stringValue(request.jsonDictionary()["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedName, !requestedName.isEmpty {
            let buttons = alert.descendants(matching: .button).allElementsBoundByIndex.filter { $0.exists }
            if let exactButton = buttons.first(where: { preferredLabel(for: $0).caseInsensitiveCompare(requestedName) == .orderedSame }) {
                tapElement(exactButton)
                return ok(NSNull(), sessionId: sessionId)
            }

            return jsonError(
                WDAErrorPayload(
                    error: "invalid element state",
                    message: "Alert button '\(requestedName)' could not be found",
                    statusCode: 400
                ),
                sessionId: sessionId
            )
        }

        guard handleAlert(alert, action: action) else {
            return jsonError(
                WDAErrorPayload(
                    error: "invalid element state",
                    message: "Unable to interact with the visible alert",
                    statusCode: 400
                ),
                sessionId: sessionId
            )
        }

        return ok(NSNull(), sessionId: sessionId)
    }

    private func noSuchAlertResponse(sessionId: String?) -> HTTPResponse {
        jsonError(
            WDAErrorPayload(error: "no such alert", message: "No alert is currently open", statusCode: 404),
            sessionId: sessionId
        )
    }

    private func alertTextComponents(in alert: XCUIElement) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        let candidates = [alert]
            + alert.descendants(matching: .staticText).allElementsBoundByIndex
            + alert.descendants(matching: .textField).allElementsBoundByIndex
            + alert.descendants(matching: .secureTextField).allElementsBoundByIndex
            + alert.descendants(matching: .textView).allElementsBoundByIndex

        for element in candidates where element.exists {
            for rawValue in [element.label, ElementTreeBuilder.stringify(element.value)] {
                let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                result.append(normalized)
            }
        }

        return result
    }

    private func preferredLabel(for element: XCUIElement) -> String {
        if !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return element.label
        }
        if !element.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return element.identifier
        }
        return ElementTreeBuilder.stringify(element.value)
    }

    private func queryApplications() -> [XCUIApplication] {
        queryApplicationDescriptors().map(\.application)
    }

    private func queryApplicationDescriptors() -> [(bundleId: String, application: XCUIApplication)] {
        var bundleIds: [String] = []
        if let foreground = session?.lastKnownForegroundBundleId {
            bundleIds.append(foreground)
        }
        if let requested = session?.requestedBundleId {
            bundleIds.append(requested)
        }
        bundleIds.append(contentsOf: session?.knownBundleIds ?? [])
        bundleIds.append("com.apple.springboard")

        var seen = Set<String>()
        return bundleIds.compactMap { bundleId in
            guard seen.insert(bundleId).inserted else { return nil }
            return (bundleId, XCUIApplication(bundleIdentifier: bundleId))
        }
    }

    private func actualForegroundDescriptor(preferNonSpringboard: Bool = true) -> (bundleId: String, application: XCUIApplication)? {
        let descriptors = queryApplicationDescriptors()

        if preferNonSpringboard,
           let active = descriptors.first(where: {
               $0.bundleId != "com.apple.springboard" && $0.application.state == .runningForeground
           }) {
            return active
        }

        if let springboard = descriptors.first(where: {
            $0.bundleId == "com.apple.springboard" && $0.application.state == .runningForeground
        }) {
            return springboard
        }

        if !preferNonSpringboard,
           let anyForeground = descriptors.first(where: { $0.application.state == .runningForeground }) {
            return anyForeground
        }

        return nil
    }

    private func waitForForeground(of application: XCUIApplication, timeout: TimeInterval) -> Bool {
        if application.state == .runningForeground {
            return true
        }

        if application.wait(for: .runningForeground, timeout: timeout) {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if application.state == .runningForeground {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return application.state == .runningForeground
    }

    private func applicationStateDescription(_ state: XCUIApplication.State) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .notRunning:
            return "notRunning"
        case .runningBackgroundSuspended:
            return "runningBackgroundSuspended"
        case .runningBackground:
            return "runningBackground"
        case .runningForeground:
            return "runningForeground"
        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }

    private func rootElementForInspection() -> XCUIElement {
        if let active = actualForegroundDescriptor() {
            return active.application
        }
        if let foreground = session?.lastKnownForegroundBundleId {
            let app = XCUIApplication(bundleIdentifier: foreground)
            if app.exists {
                return app
            }
        }
        return springboardApplication()
    }

    private func springboardApplication() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    private func preferredTypingApplication() -> XCUIApplication {
        if let active = actualForegroundDescriptor() {
            return active.application
        }
        return queryApplications().first ?? springboardApplication()
    }

    private func activeApplicationOrSpringboard() -> XCUIApplication {
        actualForegroundDescriptor(preferNonSpringboard: false)?.application ?? springboardApplication()
    }

    private func activeBundleIdentifier() -> String? {
        if let active = actualForegroundDescriptor() {
            remember(bundleId: active.bundleId)
            return active.bundleId
        }
        return nil
    }

    private func launchOrActivate(_ application: XCUIApplication, bundleId: String) {
        track(bundleId: bundleId)

        if application.state == .runningForeground {
            remember(bundleId: bundleId)
            lastFailureMessage = nil
            return
        }

        let initialState = applicationStateDescription(application.state)
        let strategies: [() -> Void] = [
            {
                if application.state == .notRunning {
                    application.launch()
                } else {
                    application.activate()
                }
            },
            {
                application.activate()
            },
            {
                application.launch()
            },
        ]

        for strategy in strategies {
            strategy()
            if waitForForeground(of: application, timeout: 8.0) {
                remember(bundleId: bundleId)
                autoHandleVisibleAlertAfterLaunch()
                lastFailureMessage = nil
                return
            }
        }

        lastFailureMessage = "Failed to foreground \(bundleId). Initial state: \(initialState), final state: \(applicationStateDescription(application.state))"
    }

    private func activateOrFallbackLaunch(_ application: XCUIApplication, bundleId: String) {
        track(bundleId: bundleId)

        if application.state == .runningForeground {
            remember(bundleId: bundleId)
            lastFailureMessage = nil
            return
        }

        application.activate()
        if waitForForeground(of: application, timeout: 6.0) {
            remember(bundleId: bundleId)
            autoHandleVisibleAlertAfterLaunch()
            lastFailureMessage = nil
            return
        }

        launchOrActivate(application, bundleId: bundleId)
    }

    private func applyBootstrapSettings(from capabilities: [String: Any]) {
        let bootstrapKeys = [
            "defaultAlertAction",
            "acceptAlertButtonSelector",
            "dismissAlertButtonSelector",
            "autoClickAlertSelector",
        ]

        var bootstrapSettings: [String: Any] = [:]
        for key in bootstrapKeys {
            if let value = capabilities[key] {
                bootstrapSettings[key] = value
            }
        }

        guard !bootstrapSettings.isEmpty else { return }
        settings.apply(bootstrapSettings)
    }

    private func autoHandleVisibleAlertAfterLaunch(timeout: TimeInterval = 0.8) {
        guard let action = configuredAlertAction() else { return }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let alert = firstVisibleAlertElement() else {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            if !handleAlert(alert, action: action) {
                return
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        }
    }

    private func configuredAlertAction() -> AlertAction? {
        let rawAction = session?.defaultAlertAction ?? settings.defaultAlertAction
        switch rawAction?.lowercased() {
        case "accept":
            return .accept
        case "dismiss":
            return .dismiss
        default:
            return nil
        }
    }

    private func firstVisibleAlertElement() -> XCUIElement? {
        var roots = [springboardApplication(), rootElementForInspection()]
        if let foreground = session?.lastKnownForegroundBundleId, !foreground.isEmpty {
            roots.insert(XCUIApplication(bundleIdentifier: foreground), at: 1)
        }

        var seen = Set<String>()
        for root in roots {
            let alerts = root.descendants(matching: .alert).allElementsBoundByIndex
            let sheets = root.descendants(matching: .sheet).allElementsBoundByIndex
            for element in alerts + sheets {
                guard element.exists, !element.frame.isEmpty else { continue }
                let fingerprint = "\(element.elementType.rawValue)|\(element.identifier)|\(element.label)|\(NSCoder.string(for: element.frame))"
                guard seen.insert(fingerprint).inserted else { continue }
                return element
            }
        }

        return nil
    }

    private func handleAlert(_ alert: XCUIElement, action: AlertAction) -> Bool {
        guard let button = alertButton(for: action, in: alert) else {
            return false
        }

        if button.isHittable {
            button.tap()
        } else {
            tapElement(button)
        }
        return true
    }

    private func alertButton(for action: AlertAction, in alert: XCUIElement) -> XCUIElement? {
        let selectorNames = alertSelectorNames(for: action)
        let buttons = alert.descendants(matching: .button).allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }

        if let matched = buttons.first(where: { matchesAlertButton($0, names: selectorNames) }) {
            return matched
        }

        if !buttons.isEmpty {
            return action == .accept ? buttons.last : buttons.first
        }

        let staticTexts = alert.descendants(matching: .staticText).allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
        if let matchedText = staticTexts.first(where: { matchesAlertButton($0, names: selectorNames) }) {
            return matchedText
        }

        return action == .accept ? staticTexts.last : staticTexts.first
    }

    private func alertSelectorNames(for action: AlertAction) -> [String] {
        var selectors: [String?] = [settings.autoClickAlertSelector]
        switch action {
        case .accept:
            selectors.append(settings.acceptAlertButtonSelector)
        case .dismiss:
            selectors.append(settings.dismissAlertButtonSelector)
        }

        let names = selectors
            .compactMap { $0 }
            .flatMap(extractAlertSelectorNames(from:))

        return NSOrderedSet(array: names).array.compactMap { $0 as? String }
    }

    private func extractAlertSelectorNames(from selector: String) -> [String] {
        let pattern = #"name\s*==\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let source = selector as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.matches(in: selector, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return source.substring(with: match.range(at: 1))
        }
    }

    private func matchesAlertButton(_ element: XCUIElement, names: [String]) -> Bool {
        guard !names.isEmpty else { return false }

        let candidates = [
            element.identifier,
            element.label,
            stringValue(element.value),
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        return names.contains { expected in
            let normalized = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return candidates.contains(normalized)
        }
    }

    private func openURL(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let body = request.jsonDictionary()
        guard let rawURL = stringValue(body["url"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return jsonError(
                WDAErrorPayload(error: "invalid argument", message: "URL is required", statusCode: 400),
                sessionId: sessionId
            )
        }

        guard let parsedURL = URL(string: rawURL) else {
            return jsonError(
                WDAErrorPayload(error: "invalid argument", message: "'\(rawURL)' is not a valid URL", statusCode: 400),
                sessionId: sessionId
            )
        }

        let bundleId = stringValue(body["bundleId"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idleTimeout = max(0, (numericValue(body["idleTimeoutMs"]) ?? 0) / 1000.0)

        guard openURL(parsedURL) else {
            return jsonError(
                WDAErrorPayload(
                    error: "unknown error",
                    message: "Unable to open '\(rawURL)'",
                    statusCode: 500
                ),
                sessionId: sessionId
            )
        }

        if let bundleId, !bundleId.isEmpty {
            let application = XCUIApplication(bundleIdentifier: bundleId)
            _ = waitForForeground(of: application, timeout: max(2.0, idleTimeout))
            if application.state == .runningForeground {
                remember(bundleId: bundleId)
            } else {
                activateOrFallbackLaunch(application, bundleId: bundleId)
            }
        } else if idleTimeout > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(idleTimeout))
        }

        return ok(NSNull(), sessionId: sessionId)
    }

    private func dismissKeyboard(from request: HTTPRequest, sessionId: String) -> HTTPResponse {
        let keyNames = request.jsonDictionary()["keyNames"] as? [String] ?? []
        let application = activeApplicationOrSpringboard()

        guard let keyboard = visibleKeyboard(in: application) else {
            return ok(NSNull(), sessionId: sessionId)
        }

        if !keyNames.isEmpty, tapKeyboardKey(in: keyboard, preferredNames: keyNames), visibleKeyboard(in: application) == nil {
            return ok(NSNull(), sessionId: sessionId)
        }

        let defaultNames = ["Done", "Return", "Hide keyboard", "Dismiss", "Tamam", "Bitti", "Gizle"]
        if tapKeyboardKey(in: keyboard, preferredNames: defaultNames), waitForKeyboardToDisappear(in: application, timeout: 3.0) {
            return ok(NSNull(), sessionId: sessionId)
        }

        if UIDevice.current.userInterfaceIdiom == .pad {
            let tappableCandidates = keyboard.descendants(matching: .any).allElementsBoundByIndex.filter {
                $0.exists && !$0.frame.isEmpty && ($0.elementType == .key || $0.elementType == .button)
            }
            if let lastCandidate = tappableCandidates.last {
                tapElement(lastCandidate)
                if waitForKeyboardToDisappear(in: application, timeout: 3.0) {
                    return ok(NSNull(), sessionId: sessionId)
                }
            }
        }

        return jsonError(
            WDAErrorPayload(
                error: "invalid element state",
                message: "Did not know how to dismiss the keyboard. Try to dismiss it in the way supported by your application under test.",
                statusCode: 400
            ),
            sessionId: sessionId
        )
    }

    private func visibleKeyboard(in application: XCUIApplication) -> XCUIElement? {
        application.descendants(matching: .keyboard).allElementsBoundByIndex.first {
            $0.exists && !$0.frame.isEmpty
        }
    }

    private func tapKeyboardKey(in keyboard: XCUIElement, preferredNames: [String]) -> Bool {
        let candidates = keyboard.descendants(matching: .any).allElementsBoundByIndex.filter {
            $0.exists && ($0.elementType == .key || $0.elementType == .button)
        }

        for name in preferredNames {
            if let candidate = candidates.first(where: { preferredLabel(for: $0).caseInsensitiveCompare(name) == .orderedSame }) {
                tapElement(candidate)
                return true
            }
        }

        return false
    }

    private func waitForKeyboardToDisappear(in application: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if visibleKeyboard(in: application) == nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return visibleKeyboard(in: application) == nil
    }

    private func scrollElementToVisible(id: String, sessionId: String) -> HTTPResponse {
        guard let element = elementCache[id] else {
            return jsonError(WDAErrorPayload(error: "stale element reference", message: "Element \(id) is not cached", statusCode: 404), sessionId: sessionId)
        }

        if element.isHittable || (element.exists && !element.frame.isEmpty && UIScreen.main.bounds.intersects(element.frame)) {
            return ok(NSNull(), sessionId: sessionId)
        }

        let application = activeApplicationOrSpringboard()
        let containers = (
            application.descendants(matching: .scrollView).allElementsBoundByIndex +
            application.descendants(matching: .table).allElementsBoundByIndex +
            application.descendants(matching: .collectionView).allElementsBoundByIndex +
            application.descendants(matching: .webView).allElementsBoundByIndex
        ).filter { $0.exists && !$0.frame.isEmpty }

        let container = containers.first(where: { $0.isHittable }) ?? containers.first ?? application
        let screenBounds = UIScreen.main.bounds

        for _ in 0..<12 {
            if element.isHittable || (element.exists && !element.frame.isEmpty && screenBounds.intersects(element.frame)) {
                return ok(NSNull(), sessionId: sessionId)
            }

            let frame = element.frame
            if !frame.isEmpty {
                if frame.maxY > screenBounds.maxY {
                    container.swipeUp()
                } else if frame.minY < screenBounds.minY {
                    container.swipeDown()
                } else if frame.maxX > screenBounds.maxX {
                    container.swipeLeft()
                } else if frame.minX < screenBounds.minX {
                    container.swipeRight()
                } else {
                    container.swipeUp()
                }
            } else {
                container.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        return jsonError(
            WDAErrorPayload(
                error: "invalid element state",
                message: "Unable to scroll the requested element into view",
                statusCode: 400
            ),
            sessionId: sessionId
        )
    }

    private func focus(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        tapElement(element)
    }

    private func clearText(in element: XCUIElement) -> Bool {
        focus(element)

        let currentValue = ElementTreeBuilder.stringify(element.value)
        if currentValue.isEmpty {
            return true
        }

        let deleteCount = min(max(currentValue.count, 1), 128)
        let deleteSequence = String(repeating: "\u{0008}", count: deleteCount)
        element.typeText(deleteSequence)

        let updatedValue = ElementTreeBuilder.stringify(element.value)
        return updatedValue.isEmpty || updatedValue == currentValue.replacingOccurrences(of: "\u{2022}", with: "")
    }

    private func openURL(_ url: URL) -> Bool {
        var success = false
        var completed = false
        UIApplication.shared.open(url, options: [:]) { opened in
            success = opened
            completed = true
        }

        let deadline = Date().addingTimeInterval(5)
        while !completed && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return success
    }

    private func pressVolumeButton(increment: Bool) -> Bool {
        if performDeviceButtonPress(named: increment ? "volumeUp" : "volumeDown") {
            return true
        }

        let volumeView = MPVolumeView(frame: .zero)
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            return false
        }

        let currentVolume = AVAudioSession.sharedInstance().outputVolume
        let delta: Float = increment ? 0.0625 : -0.0625
        let nextValue = min(1.0, max(0.0, currentVolume + delta))
        if abs(nextValue - currentVolume) < 0.0001 {
            return true
        }

        slider.value = nextValue
        slider.sendActions(for: [.touchUpInside, .valueChanged])
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return true
    }

    private func performDeviceButtonPress(named name: String) -> Bool {
        let selector = NSSelectorFromString("pressButton:")
        guard XCUIDevice.shared.responds(to: selector) else {
            return false
        }

        let rawValue: Int32
        switch name.lowercased() {
        case "home":
            rawValue = 1
        case "volumeup":
            rawValue = 2
        case "volumedown":
            rawValue = 3
        default:
            return false
        }

        typealias PressButtonFunction = @convention(c) (AnyObject, Selector, Int32) -> Void
        let implementation = XCUIDevice.shared.method(for: selector)
        let function = unsafeBitCast(implementation, to: PressButtonFunction.self)
        function(XCUIDevice.shared, selector, rawValue)
        return true
    }

    private func normalizedEnvironmentValue(_ key: String) -> String? {
        guard let rawValue = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        if isUnresolvedEnvironmentPlaceholder(rawValue) {
            return nil
        }
        return rawValue
    }

    private func isUnresolvedEnvironmentPlaceholder(_ value: String) -> Bool {
        if value == "0.0.0.0" {
            return true
        }
        if value.hasPrefix("$(") && value.hasSuffix(")") {
            return true
        }
        if value.hasPrefix("${") && value.hasSuffix("}") {
            return true
        }
        if value.hasPrefix("$") && !value.contains(".") {
            return true
        }
        return false
    }

    private func detectedWiFiIPAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        var currentInterface: UnsafeMutablePointer<ifaddrs>?
        let success = getifaddrs(&interfaces)
        if success != 0 {
            freeifaddrs(interfaces)
            return nil
        }
        defer { freeifaddrs(interfaces) }

        currentInterface = interfaces
        while currentInterface != nil {
            guard let address = currentInterface?.pointee.ifa_addr else {
                currentInterface = currentInterface?.pointee.ifa_next
                continue
            }
            if address.pointee.sa_family != UInt8(AF_INET) {
                currentInterface = currentInterface?.pointee.ifa_next
                continue
            }

            let interfaceName = String(cString: currentInterface!.pointee.ifa_name)
            if interfaceName != "en0" {
                currentInterface = currentInterface?.pointee.ifa_next
                continue
            }

            let addressString = String(cString: inet_ntoa(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }))
            return addressString
        }

        return nil
    }

    private func coordinate(at point: CGPoint) -> XCUICoordinate {
        let anchor = springboardApplication().coordinate(withNormalizedOffset: .zero)
        return anchor.withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> CGFloat {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let string as String:
            return CGFloat(Double(string) ?? 0)
        default:
            return 0
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return NSString(string: string).boolValue
        default:
            return nil
        }
    }

    private func prometheusMetricsPayload() -> String {
        let uptimeSeconds = Int(Date().timeIntervalSince(startedAt))
        let avgLatency = requestCount == 0 ? 0 : Int(totalLatencyMs / Double(requestCount))
        let sessionActive = session == nil ? 0 : 1
        let locked = lastKnownLockedState ? 1 : 0
        let canLock = canLockDevice() ? 1 : 0
        let locationSupport = locationSimulation.supportInfo()
        let locationSupported = locationSupport.supported ? 1 : 0
        let locationSet = locationSupport.currentLocation == nil ? 0 : 1

        return [
            "# HELP swiftwda_requests_total Total HTTP requests handled by the agent",
            "# TYPE swiftwda_requests_total counter",
            "swiftwda_requests_total \(requestCount)",
            "# HELP swiftwda_errors_total Total HTTP requests that returned an error status",
            "# TYPE swiftwda_errors_total counter",
            "swiftwda_errors_total \(errorCount)",
            "# HELP swiftwda_average_latency_milliseconds Average request latency in milliseconds",
            "# TYPE swiftwda_average_latency_milliseconds gauge",
            "swiftwda_average_latency_milliseconds \(avgLatency)",
            "# HELP swiftwda_uptime_seconds Agent uptime in seconds",
            "# TYPE swiftwda_uptime_seconds gauge",
            "swiftwda_uptime_seconds \(uptimeSeconds)",
            "# HELP swiftwda_session_active Whether a session is currently active",
            "# TYPE swiftwda_session_active gauge",
            "swiftwda_session_active \(sessionActive)",
            "# HELP swiftwda_locked_state Last known locked state",
            "# TYPE swiftwda_locked_state gauge",
            "swiftwda_locked_state \(locked)",
            "# HELP swiftwda_lock_capability_available Whether the runtime exposes a lock button API",
            "# TYPE swiftwda_lock_capability_available gauge",
            "swiftwda_lock_capability_available \(canLock)",
            "# HELP swiftwda_mjpeg_server_port Device-side MJPEG server port",
            "# TYPE swiftwda_mjpeg_server_port gauge",
            "swiftwda_mjpeg_server_port \(mjpegServerPort)",
            "# HELP swiftwda_location_simulation_supported Whether the runtime can simulate location natively",
            "# TYPE swiftwda_location_simulation_supported gauge",
            "swiftwda_location_simulation_supported \(locationSupported)",
            "# HELP swiftwda_simulated_location_active Whether a simulated location is currently cached as active",
            "# TYPE swiftwda_simulated_location_active gauge",
            "swiftwda_simulated_location_active \(locationSet)",
        ].joined(separator: "\n") + "\n"
    }

    private func canLockDevice() -> Bool {
        XCUIDevice.shared.responds(to: NSSelectorFromString("pressLockButton"))
    }

    func mjpegStreamSettings() -> MJPEGStreamSettings {
        MJPEGStreamSettings(
            framerate: settings.mjpegServerFramerate,
            compressionQuality: CGFloat(settings.mjpegServerScreenshotQuality) / 100.0,
            scalingFactor: CGFloat(settings.mjpegScalingFactor) / 100.0,
            fixOrientation: settings.mjpegFixOrientation
        )
    }

    func mjpegFrame() -> Data? {
        let settings = mjpegStreamSettings()
        let captureBlock = {
            let screenshot = XCUIScreen.main.screenshot()
            guard var image = UIImage(data: screenshot.pngRepresentation) else {
                return Data?.none
            }

            if settings.fixOrientation {
                image = image.wda_normalized()
            }

            if settings.scalingFactor < 0.999 {
                image = image.wda_scaled(by: settings.scalingFactor)
            }

            return image.jpegData(compressionQuality: settings.compressionQuality)
        }

        if Thread.isMainThread {
            return captureBlock()
        }

        var frame: Data?
        DispatchQueue.main.sync {
            frame = captureBlock()
        }
        return frame
    }

    private func pressLockButton() -> Bool {
        let selector = NSSelectorFromString("pressLockButton")
        guard canLockDevice() else {
            return false
        }
        _ = XCUIDevice.shared.perform(selector)
        return true
    }

    private func locationPayload(for location: CLLocation?) -> [String: Any] {
        [
            "latitude": location?.coordinate.latitude as Any,
            "longitude": location?.coordinate.longitude as Any,
            "altitude": location?.altitude as Any,
        ]
    }
}

private extension UIImage {
    func wda_normalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func wda_scaled(by factor: CGFloat) -> UIImage {
        guard factor > 0, factor < 0.999 else { return self }
        let targetSize = CGSize(
            width: max(1, floor(size.width * factor)),
            height: max(1, floor(size.height * factor))
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private final class LocationSimulationController {
    struct SupportInfo {
        let supported: Bool
        let strategy: String
        let minimumSupportedOSVersion: String
        let requiresHostFallback: Bool
        let reason: String?
        let currentLocation: CLLocation?

        func payload() -> [String: Any] {
            [
                "supported": supported,
                "strategy": strategy,
                "minimumSupportedOSVersion": minimumSupportedOSVersion,
                "requiresHostFallback": requiresHostFallback,
                "reason": reason as Any,
                "current": [
                    "latitude": currentLocation?.coordinate.latitude as Any,
                    "longitude": currentLocation?.coordinate.longitude as Any,
                    "altitude": currentLocation?.altitude as Any,
                ],
            ]
        }
    }

    struct CommandError: Error {
        let errorName: String
        let message: String
        let statusCode: Int
    }

    private let minimumSupportedVersion = OperatingSystemVersion(majorVersion: 16, minorVersion: 4, patchVersion: 0)
    private let locationStateQueue = DispatchQueue(label: "io.github.swiftwda.location.state")
    private var cachedLocation: CLLocation?

    func supportInfo() -> SupportInfo {
        let fallbackRequired = requiresHostFallback()
        do {
            let session = try daemonSession()
            try ensureLocationInvocationSelectors(on: session)
            let supported = try runtimeSupportsLocationSimulation(on: session)
            let strategy = supported ? "xctrunner-daemon" : (fallbackRequired ? "host-dvt-required" : "xctrunner-daemon")
            let reason = supported
                ? nil
                : "The current XCTest runtime reported that the device does not support native location simulation."
            return SupportInfo(
                supported: supported,
                strategy: strategy,
                minimumSupportedOSVersion: "16.4",
                requiresHostFallback: fallbackRequired && !supported,
                reason: reason,
                currentLocation: cachedLocationSnapshot()
            )
        } catch let error as CommandError {
            return SupportInfo(
                supported: false,
                strategy: fallbackRequired ? "host-dvt-required" : "unavailable",
                minimumSupportedOSVersion: "16.4",
                requiresHostFallback: fallbackRequired,
                reason: error.message,
                currentLocation: cachedLocationSnapshot()
            )
        } catch {
            return SupportInfo(
                supported: false,
                strategy: fallbackRequired ? "host-dvt-required" : "unavailable",
                minimumSupportedOSVersion: "16.4",
                requiresHostFallback: fallbackRequired,
                reason: error.localizedDescription,
                currentLocation: cachedLocationSnapshot()
            )
        }
    }

    func getSimulatedLocation() -> Result<CLLocation?, CommandError> {
        do {
            let session = try daemonSession()
            let selector = NSSelectorFromString("getSimulatedLocationWithReply:")
            guard session.responds(to: selector) else {
                throw unsupportedError(
                    "The current XCTest runtime does not expose getSimulatedLocationWithReply:. Native WDA location simulation starts at roughly iOS 16.4+. Older iOS 15.x and 16.0-16.3 devices still need host-side DVT simulate-location fallback."
                )
            }
            guard try runtimeSupportsLocationSimulation(on: session) else {
                throw unsupportedError(
                    "This device/runtime reports that native location simulation is unavailable. Older iOS 15.x and 16.0-16.3 devices still require host-side DVT simulate-location fallback."
                )
            }

            let location = try invokeLocationGetter(on: session, selector: selector)
            updateCachedLocation(location)
            return .success(location)
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(CommandError(errorName: "unknown error", message: error.localizedDescription, statusCode: 500))
        }
    }

    func setSimulatedLocation(_ location: CLLocation) -> Result<CLLocation, CommandError> {
        do {
            let session = try daemonSession()
            let selector = NSSelectorFromString("setSimulatedLocation:completion:")
            guard session.responds(to: selector) else {
                throw unsupportedError(
                    "The current XCTest runtime does not expose setSimulatedLocation:completion:. Native WDA location simulation starts at roughly iOS 16.4+. Older iOS 15.x and 16.0-16.3 devices still need host-side DVT simulate-location fallback."
                )
            }
            guard try runtimeSupportsLocationSimulation(on: session) else {
                throw unsupportedError(
                    "This device/runtime reports that native location simulation is unavailable. Older iOS 15.x and 16.0-16.3 devices still require host-side DVT simulate-location fallback."
                )
            }

            try invokeLocationSetter(on: session, selector: selector, location: location)
            updateCachedLocation(location)
            return .success(location)
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(CommandError(errorName: "unknown error", message: error.localizedDescription, statusCode: 500))
        }
    }

    func clearSimulatedLocation() -> Result<Void, CommandError> {
        do {
            let session = try daemonSession()
            let selector = NSSelectorFromString("clearSimulatedLocationWithReply:")
            guard session.responds(to: selector) else {
                throw unsupportedError(
                    "The current XCTest runtime does not expose clearSimulatedLocationWithReply:. Native WDA location simulation starts at roughly iOS 16.4+. Older iOS 15.x and 16.0-16.3 devices still need host-side DVT simulate-location fallback."
                )
            }
            guard try runtimeSupportsLocationSimulation(on: session) else {
                throw unsupportedError(
                    "This device/runtime reports that native location simulation is unavailable. Older iOS 15.x and 16.0-16.3 devices still require host-side DVT simulate-location fallback."
                )
            }

            try invokeLocationClear(on: session, selector: selector)
            updateCachedLocation(nil)
            return .success(())
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(CommandError(errorName: "unknown error", message: error.localizedDescription, statusCode: 500))
        }
    }

    private func daemonSession() throws -> NSObject {
        guard let sessionClass = NSClassFromString("XCTRunnerDaemonSession") else {
            throw unsupportedError(
                "XCTest does not expose XCTRunnerDaemonSession on this runtime. Pure iOS-native location simulation is unavailable here; older iOS 15.x and 16.0-16.3 devices still need a host-side DVT simulate-location fallback."
            )
        }

        let selector = NSSelectorFromString("sharedSession")
        guard let method = class_getClassMethod(sessionClass, selector) else {
            throw unsupportedError(
                "XCTest does not expose XCTRunnerDaemonSession.sharedSession. Native location simulation cannot be initialized on this runtime."
            )
        }

        typealias SharedSessionFunction = @convention(c) (AnyClass, Selector) -> AnyObject?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: SharedSessionFunction.self)
        guard let session = function(sessionClass, selector) as? NSObject else {
            throw CommandError(errorName: "unknown error", message: "XCTest returned an invalid XCTRunnerDaemonSession instance", statusCode: 500)
        }
        return session
    }

    private func ensureLocationInvocationSelectors(on session: NSObject) throws {
        let requiredSelectors = [
            NSSelectorFromString("setSimulatedLocation:completion:"),
            NSSelectorFromString("getSimulatedLocationWithReply:"),
            NSSelectorFromString("clearSimulatedLocationWithReply:"),
        ]

        let missing = requiredSelectors.filter { !session.responds(to: $0) }
        guard missing.isEmpty else {
            throw unsupportedError(
                "The current XCTest runtime is missing one or more location simulation selectors. Native support is expected on roughly iOS 16.4+ runtimes; older versions still require host-side DVT simulate-location fallback."
            )
        }
    }

    private func runtimeSupportsLocationSimulation(on session: NSObject) throws -> Bool {
        let selector = NSSelectorFromString("supportsLocationSimulation")
        guard session.responds(to: selector) else {
            return !requiresHostFallback()
        }

        typealias SupportsLocationFunction = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = session.method(for: selector)
        let function = unsafeBitCast(implementation, to: SupportsLocationFunction.self)
        return function(session, selector)
    }

    private func invokeLocationSetter(on session: NSObject, selector: Selector, location: CLLocation) throws {
        typealias SetterFunction = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (Bool, NSError?) -> Void) -> Void
        let implementation = session.method(for: selector)
        let function = unsafeBitCast(implementation, to: SetterFunction.self)

        var completed = false
        var succeeded = false
        var invocationError: NSError?
        function(session, selector, location) { result, error in
            succeeded = result
            invocationError = error
            completed = true
        }
        try waitForInvocationCompletion(named: "set simulated location", completed: &completed)
        if let invocationError {
            throw CommandError(errorName: "unknown error", message: invocationError.localizedDescription, statusCode: 500)
        }
        if !succeeded {
            throw CommandError(errorName: "unknown error", message: "XCTest declined to apply the simulated location", statusCode: 500)
        }
    }

    private func invokeLocationGetter(on session: NSObject, selector: Selector) throws -> CLLocation? {
        typealias GetterFunction = @convention(c) (AnyObject, Selector, @escaping @convention(block) (AnyObject?, NSError?) -> Void) -> Void
        let implementation = session.method(for: selector)
        let function = unsafeBitCast(implementation, to: GetterFunction.self)

        var completed = false
        var location: CLLocation?
        var invocationError: NSError?
        function(session, selector) { reply, error in
            location = reply as? CLLocation
            invocationError = error
            completed = true
        }
        try waitForInvocationCompletion(named: "get simulated location", completed: &completed)
        if let invocationError {
            throw CommandError(errorName: "unknown error", message: invocationError.localizedDescription, statusCode: 500)
        }
        return location
    }

    private func invokeLocationClear(on session: NSObject, selector: Selector) throws {
        typealias ClearFunction = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool, NSError?) -> Void) -> Void
        let implementation = session.method(for: selector)
        let function = unsafeBitCast(implementation, to: ClearFunction.self)

        var completed = false
        var succeeded = false
        var invocationError: NSError?
        function(session, selector) { result, error in
            succeeded = result
            invocationError = error
            completed = true
        }
        try waitForInvocationCompletion(named: "clear simulated location", completed: &completed)
        if let invocationError {
            throw CommandError(errorName: "unknown error", message: invocationError.localizedDescription, statusCode: 500)
        }
        if !succeeded {
            throw CommandError(errorName: "unknown error", message: "XCTest declined to clear the simulated location", statusCode: 500)
        }
    }

    private func waitForInvocationCompletion(named operation: String, completed: inout Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !completed && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        guard completed else {
            throw CommandError(errorName: "timeout", message: "Timed out while waiting to \(operation)", statusCode: 500)
        }
    }

    private func updateCachedLocation(_ location: CLLocation?) {
        locationStateQueue.sync {
            cachedLocation = location
        }
    }

    private func cachedLocationSnapshot() -> CLLocation? {
        locationStateQueue.sync { cachedLocation }
    }

    private func requiresHostFallback() -> Bool {
        let current = ProcessInfo.processInfo.operatingSystemVersion
        if current.majorVersion < minimumSupportedVersion.majorVersion {
            return true
        }
        if current.majorVersion > minimumSupportedVersion.majorVersion {
            return false
        }
        if current.minorVersion < minimumSupportedVersion.minorVersion {
            return true
        }
        if current.minorVersion > minimumSupportedVersion.minorVersion {
            return false
        }
        return current.patchVersion < minimumSupportedVersion.patchVersion
    }

    private func unsupportedError(_ message: String) -> CommandError {
        CommandError(errorName: "unsupported operation", message: message, statusCode: 500)
    }
}

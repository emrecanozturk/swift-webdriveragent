import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
    case options = "OPTIONS"
}

struct HTTPRequest {
    let method: HTTPMethod
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data

    var pathComponents: [String] {
        path.split(separator: "/").map(String.init)
    }

    func jsonObject() -> Any? {
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body)
    }

    func jsonDictionary() -> [String: Any] {
        jsonObject() as? [String: Any] ?? [:]
    }

    func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    static func json(_ object: Any, statusCode: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        var mergedHeaders = headers
        if mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/json; charset=utf-8"
        }
        return HTTPResponse(statusCode: statusCode, headers: mergedHeaders, body: data)
    }

    static func text(_ text: String, statusCode: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var mergedHeaders = headers
        if mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "text/plain; charset=utf-8"
        }
        return HTTPResponse(statusCode: statusCode, headers: mergedHeaders, body: Data(text.utf8))
    }

    func serialized() -> Data {
        var output = Data()
        let reason = HTTPStatus.reasonPhrase(for: statusCode)
        output.append(Data("HTTP/1.1 \(statusCode) \(reason)\r\n".utf8))

        var responseHeaders = headers
        responseHeaders["Content-Length"] = "\(body.count)"
        responseHeaders["Connection"] = "close"
        responseHeaders["Access-Control-Allow-Origin"] = responseHeaders["Access-Control-Allow-Origin"] ?? "*"
        responseHeaders["Access-Control-Allow-Headers"] = responseHeaders["Access-Control-Allow-Headers"] ?? "Content-Type, Authorization"
        responseHeaders["Access-Control-Allow-Methods"] = responseHeaders["Access-Control-Allow-Methods"] ?? "GET, POST, DELETE, OPTIONS"

        for (name, value) in responseHeaders.sorted(by: { $0.key < $1.key }) {
            output.append(Data("\(name): \(value)\r\n".utf8))
        }
        output.append(Data("\r\n".utf8))
        output.append(body)
        return output
    }
}

enum HTTPStatus {
    static func reasonPhrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

enum AgentLifecycleState: String {
    case starting = "STARTING"
    case idle = "IDLE"
    case active = "ACTIVE"
    case cleaning = "CLEANING"
    case error = "ERROR"
}

struct AgentSettings {
    private(set) var values: [String: Any] = [
        "defaultAlertAction": "accept",
        "acceptAlertButtonSelector": "",
        "dismissAlertButtonSelector": "",
        "autoClickAlertSelector": "",
        "waitForQuiescence": false,
        "shouldWaitForQuiescence": false,
        "waitForIdleTimeout": 0,
        "animationWait": 0,
        "shouldUseTestManagerForVisibilityDetection": false,
        "snapshotTimeout": 0,
        "customSnapshotTimeout": 0,
        "shouldUseCompactResponses": true,
        "eventloopIdleDelaySec": 0,
        "snapshotMaxDepth": 15,
        "maxTypingFrequency": 60,
        "screenshotQuality": 1,
        "elementResponseAttributes": "type,label",
        "animationCoolOffTimeout": 0,
        "mjpegServerFramerate": 10,
        "mjpegServerScreenshotQuality": 25,
        "mjpegServerScreenshootQuality": 25,
        "mjpegScalingFactor": 100,
        "mjpegFixOrientation": false,
    ]

    var snapshotMaxDepth: Int {
        intValue(values["snapshotMaxDepth"], fallback: 15)
    }

    var defaultAlertAction: String? {
        normalizedString(values["defaultAlertAction"])
    }

    var acceptAlertButtonSelector: String? {
        normalizedString(values["acceptAlertButtonSelector"])
    }

    var dismissAlertButtonSelector: String? {
        normalizedString(values["dismissAlertButtonSelector"])
    }

    var autoClickAlertSelector: String? {
        normalizedString(values["autoClickAlertSelector"])
    }

    var mjpegServerFramerate: Int {
        max(1, intValue(values["mjpegServerFramerate"], fallback: 10))
    }

    var mjpegServerScreenshotQuality: Int {
        let value = values["mjpegServerScreenshotQuality"] ?? values["mjpegServerScreenshootQuality"]
        return max(1, min(100, intValue(value, fallback: 25)))
    }

    var mjpegScalingFactor: Int {
        max(1, min(100, intValue(values["mjpegScalingFactor"], fallback: 100)))
    }

    var mjpegFixOrientation: Bool {
        boolValue(values["mjpegFixOrientation"], fallback: false)
    }

    mutating func apply(_ incoming: [String: Any]) {
        for (key, value) in incoming {
            switch key {
            case "mjpegServerScreenshootQuality":
                values["mjpegServerScreenshootQuality"] = value
                values["mjpegServerScreenshotQuality"] = value
            case "mjpegServerScreenshotQuality":
                values["mjpegServerScreenshotQuality"] = value
                values["mjpegServerScreenshootQuality"] = value
            default:
                values[key] = value
            }
        }
    }

    private func intValue(_ value: Any?, fallback: Int) -> Int {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string) ?? fallback
        default:
            return fallback
        }
    }

    private func boolValue(_ value: Any?, fallback: Bool) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return NSString(string: string).boolValue
        default:
            return fallback
        }
    }

    private func normalizedString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

struct WDAErrorPayload {
    let error: String
    let message: String
    let statusCode: Int
}

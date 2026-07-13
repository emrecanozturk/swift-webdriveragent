import XCTest
import CoreGraphics

struct ElementSnapshotNode {
    let type: String
    let fullType: String
    let name: String
    let label: String
    let value: String
    let rect: CGRect
    let isVisible: Bool
    let isEnabled: Bool
    let isHittable: Bool
    let children: [ElementSnapshotNode]

    func toJSON() -> [String: Any] {
        [
            "type": type,
            "name": name,
            "label": label,
            "value": value,
            "rect": [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height,
            ],
            "isVisible": isVisible,
            "isEnabled": isEnabled,
            "isHittable": isHittable,
            "children": children.map { $0.toJSON() },
        ]
    }

    func toXML(indentation: String = "") -> String {
        let attrs = [
            "type=\"\(fullType.xmlEscaped)\"",
            "name=\"\(name.xmlEscaped)\"",
            "label=\"\(label.xmlEscaped)\"",
            "value=\"\(value.xmlEscaped)\"",
            "x=\"\(rect.origin.x)\"",
            "y=\"\(rect.origin.y)\"",
            "width=\"\(rect.size.width)\"",
            "height=\"\(rect.size.height)\"",
            "visible=\"\(isVisible)\"",
            "enabled=\"\(isEnabled)\"",
            "hittable=\"\(isHittable)\"",
        ].joined(separator: " ")

        guard !children.isEmpty else {
            return "\(indentation)<\(fullType) \(attrs)/>"
        }

        let childrenXML = children.map { $0.toXML(indentation: indentation + "  ") }.joined(separator: "\n")
        return """
        \(indentation)<\(fullType) \(attrs)>
        \(childrenXML)
        \(indentation)</\(fullType)>
        """
    }
}

enum ElementTreeBuilder {
    static func build(from element: XCUIElement, maxDepth: Int, depth: Int = 0) -> ElementSnapshotNode {
        let type = ElementTypeMapper.shortName(for: element.elementType)
        let fullType = ElementTypeMapper.fullName(for: element.elementType)
        let rect = element.frame
        let identifier = element.identifier
        let label = element.label
        let value = stringify(element.value)
        let visible = element.exists && !rect.isEmpty
        let children: [ElementSnapshotNode]

        if depth < maxDepth {
            children = element.children(matching: .any).allElementsBoundByIndex.map {
                build(from: $0, maxDepth: maxDepth, depth: depth + 1)
            }
        } else {
            children = []
        }

        return ElementSnapshotNode(
            type: type,
            fullType: fullType,
            name: identifier.isEmpty ? label : identifier,
            label: label,
            value: value,
            rect: rect,
            isVisible: visible,
            isEnabled: element.isEnabled,
            isHittable: element.isHittable,
            children: children
        )
    }

    static func stringify(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }
}

enum ElementTypeMapper {
    static func shortName(for type: XCUIElement.ElementType) -> String {
        switch type {
        case .application: return "Application"
        case .window: return "Window"
        case .sheet: return "Sheet"
        case .alert: return "Alert"
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .image: return "Image"
        case .cell: return "Cell"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .scrollView: return "ScrollView"
        case .other: return "Other"
        case .switch: return "Switch"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .keyboard: return "Keyboard"
        case .key: return "Key"
        case .textView: return "TextView"
        case .statusBar: return "StatusBar"
        case .link: return "Link"
        case .slider: return "Slider"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .activityIndicator: return "ActivityIndicator"
        case .pageIndicator: return "PageIndicator"
        case .searchField: return "SearchField"
        case .toolbar: return "Toolbar"
        case .segmentedControl: return "SegmentedControl"
        case .progressIndicator: return "ProgressIndicator"
        case .webView: return "WebView"
        default: return "Other"
        }
    }

    static func fullName(for type: XCUIElement.ElementType) -> String {
        "XCUIElementType\(shortName(for: type))"
    }

    static func elementType(from className: String) -> XCUIElement.ElementType? {
        switch className {
        case "Application", "XCUIElementTypeApplication": return .application
        case "Window", "XCUIElementTypeWindow": return .window
        case "Sheet", "XCUIElementTypeSheet": return .sheet
        case "Alert", "XCUIElementTypeAlert": return .alert
        case "Button", "XCUIElementTypeButton": return .button
        case "StaticText", "XCUIElementTypeStaticText": return .staticText
        case "TextField", "XCUIElementTypeTextField": return .textField
        case "SecureTextField", "XCUIElementTypeSecureTextField": return .secureTextField
        case "Image", "XCUIElementTypeImage": return .image
        case "Cell", "XCUIElementTypeCell": return .cell
        case "Table", "XCUIElementTypeTable": return .table
        case "CollectionView", "XCUIElementTypeCollectionView": return .collectionView
        case "ScrollView", "XCUIElementTypeScrollView": return .scrollView
        case "Other", "XCUIElementTypeOther": return .other
        case "Switch", "XCUIElementTypeSwitch": return .switch
        case "NavigationBar", "XCUIElementTypeNavigationBar": return .navigationBar
        case "TabBar", "XCUIElementTypeTabBar": return .tabBar
        case "Keyboard", "XCUIElementTypeKeyboard": return .keyboard
        case "Key", "XCUIElementTypeKey": return .key
        case "TextView", "XCUIElementTypeTextView": return .textView
        case "StatusBar", "XCUIElementTypeStatusBar": return .statusBar
        case "Link", "XCUIElementTypeLink": return .link
        case "Slider", "XCUIElementTypeSlider": return .slider
        case "Picker", "XCUIElementTypePicker": return .picker
        case "PickerWheel", "XCUIElementTypePickerWheel": return .pickerWheel
        case "ActivityIndicator", "XCUIElementTypeActivityIndicator": return .activityIndicator
        case "PageIndicator", "XCUIElementTypePageIndicator": return .pageIndicator
        case "SearchField", "XCUIElementTypeSearchField": return .searchField
        case "Toolbar", "XCUIElementTypeToolbar": return .toolbar
        case "SegmentedControl", "XCUIElementTypeSegmentedControl": return .segmentedControl
        case "ProgressIndicator", "XCUIElementTypeProgressIndicator": return .progressIndicator
        case "WebView", "XCUIElementTypeWebView": return .webView
        default: return nil
        }
    }
}

struct XPathQuery {
    enum ClauseOperator {
        case contains
        case equals
    }

    enum PredicateMode {
        case any
        case all
    }

    struct Clause {
        let attribute: String
        let operation: ClauseOperator
        let value: String
    }

    let fullType: String?
    let mode: PredicateMode
    let clauses: [Clause]

    static func parse(_ raw: String) -> XPathQuery? {
        guard raw.hasPrefix("//") else { return nil }

        let body = String(raw.dropFirst(2))
        let parts = body.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false)
        let rawType = parts.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let predicate = parts.count > 1 ? String(parts[1].dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let fullType = rawType.isEmpty || rawType == "*" ? nil : rawType

        guard !predicate.isEmpty else {
            return XPathQuery(fullType: fullType, mode: .all, clauses: [])
        }

        let mode: PredicateMode = predicate.contains(" or ") ? .any : .all
        var clauses: [Clause] = []

        for match in predicate.captureGroups(for: #"contains\(@([A-Za-z]+),\s*["']([^"']+)["']\)"#) where match.count == 2 {
            clauses.append(Clause(attribute: match[0], operation: .contains, value: match[1]))
        }

        for match in predicate.captureGroups(for: #"@([A-Za-z]+)\s*=\s*["']([^"']+)["']"#) where match.count == 2 {
            clauses.append(Clause(attribute: match[0], operation: .equals, value: match[1]))
        }

        guard !clauses.isEmpty else { return nil }
        return XPathQuery(fullType: fullType, mode: mode, clauses: clauses)
    }

    func matches(_ node: ElementSnapshotNode) -> Bool {
        if let fullType, node.fullType != fullType {
            return false
        }

        guard !clauses.isEmpty else { return true }

        switch mode {
        case .any:
            return clauses.contains(where: { clause in
                clauseMatches(clause, node: node)
            })
        case .all:
            return clauses.allSatisfy { clause in
                clauseMatches(clause, node: node)
            }
        }
    }

    private func clauseMatches(_ clause: Clause, node: ElementSnapshotNode) -> Bool {
        let candidate: String
        switch clause.attribute.lowercased() {
        case "label":
            candidate = node.label
        case "name":
            candidate = node.name
        case "value":
            candidate = node.value
        case "type":
            candidate = node.fullType
        default:
            candidate = ""
        }

        switch clause.operation {
        case .contains:
            return candidate.localizedCaseInsensitiveContains(clause.value)
        case .equals:
            return candidate == clause.value
        }
    }
}

private extension String {
    var xmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: nsRange).compactMap { result in
            guard result.numberOfRanges > 1,
                  let range = Range(result.range(at: 1), in: self) else {
                return nil
            }
            return String(self[range])
        }
    }

    func captureGroups(for pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: nsRange).map { result in
            (1..<result.numberOfRanges).compactMap { index in
                guard let range = Range(result.range(at: index), in: self) else {
                    return nil
                }
                return String(self[range])
            }
        }
    }
}

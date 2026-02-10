import AppKit
import ApplicationServices
import Foundation
import WhispCore

enum AccessibilityContextCollector {
    static func captureSnapshot(frontmostApp: NSRunningApplication?) -> (snapshot: AccessibilitySnapshot, context: ContextInfo?) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let appName = frontmostApp?.localizedName
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier

        guard DirectInput.isAccessibilityTrusted() else {
            let snapshot = AccessibilitySnapshot(
                capturedAt: timestamp,
                trusted: false,
                appName: appName,
                bundleID: bundleID,
                processID: pid,
                error: "accessibility_not_trusted"
            )
            return (snapshot, nil)
        }

        guard let pid else {
            let snapshot = AccessibilitySnapshot(
                capturedAt: timestamp,
                trusted: true,
                appName: appName,
                bundleID: bundleID,
                processID: nil,
                error: "frontmost_app_unavailable"
            )
            return (snapshot, nil)
        }

        let appElement = AXUIElementCreateApplication(pid)
        let focusedElement = axElementAttribute(appElement, kAXFocusedUIElementAttribute as CFString)
        let focusedWindow = axElementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let windowTitle = focusedWindow.flatMap {
            stringAttribute($0, kAXTitleAttribute as CFString)
        }
        let windowText = focusedWindow.flatMap { collectWindowVisibleText(from: $0) }
        let windowTextChars = windowText?.count ?? 0

        guard let focusedElement else {
            let err = axErrorForAttribute(appElement, kAXFocusedUIElementAttribute as CFString)
            let snapshot = AccessibilitySnapshot(
                capturedAt: timestamp,
                trusted: true,
                appName: appName,
                bundleID: bundleID,
                processID: pid,
                windowTitle: windowTitle,
                windowText: windowText,
                windowTextChars: windowTextChars,
                error: "focused_element_unavailable:\(err)"
            )
            let context = windowText.flatMap { text in
                ContextInfo(windowText: tailExcerpt(from: text, maxChars: 1200))
            }
            return (snapshot, context)
        }

        let selectedRange = rangeAttribute(focusedElement, kAXSelectedTextRangeAttribute as CFString)
        let caretIndex = max(0, selectedRange.map { $0.location + $0.length } ?? 0)

        let value = stringAttribute(focusedElement, kAXValueAttribute as CFString)
        let selectedText = stringAttribute(focusedElement, kAXSelectedTextAttribute as CFString)
        let valueChars = value?.count ?? 0

        let caretWindow = 180
        let contextStart = max(0, caretIndex - caretWindow)
        let contextLength = caretWindow * 2
        let requestedRange = CFRange(location: contextStart, length: contextLength)

        let caretContext: String?
        if let ranged = stringForRange(focusedElement, requestedRange) {
            caretContext = ranged
        } else if let value {
            caretContext = excerpt(from: value, around: caretIndex, window: caretWindow)
        } else {
            caretContext = nil
        }

        let element = AccessibilityElementSnapshot(
            role: stringAttribute(focusedElement, kAXRoleAttribute as CFString),
            subrole: stringAttribute(focusedElement, kAXSubroleAttribute as CFString),
            title: stringAttribute(focusedElement, kAXTitleAttribute as CFString),
            elementDescription: stringAttribute(focusedElement, kAXDescriptionAttribute as CFString),
            help: stringAttribute(focusedElement, kAXHelpAttribute as CFString),
            placeholder: stringAttribute(focusedElement, kAXPlaceholderValueAttribute as CFString),
            value: value,
            valueChars: valueChars,
            selectedText: selectedText,
            selectedRange: selectedRange.map { AccessibilityTextRange(location: $0.location, length: $0.length) },
            insertionPointLineNumber: intAttribute(focusedElement, kAXInsertionPointLineNumberAttribute as CFString),
            labelTexts: labelTexts(focusedElement),
            caretContext: caretContext,
            caretContextRange: AccessibilityTextRange(location: requestedRange.location, length: requestedRange.length)
        )

        let snapshot = AccessibilitySnapshot(
            capturedAt: timestamp,
            trusted: true,
            appName: appName,
            bundleID: bundleID,
            processID: pid,
            windowTitle: windowTitle,
            windowText: windowText,
            windowTextChars: windowTextChars,
            focusedElement: element,
            error: nil
        )

        let focusedContextText = firstNonEmpty([
            selectedText,
            caretContext,
            value.flatMap { excerpt(from: $0, around: caretIndex, window: 120) },
        ])
        let context = makeAccessibilityContext(
            focusedText: focusedContextText,
            windowText: windowText
        )

        return (snapshot, context)
    }

    private static func makeAccessibilityContext(
        focusedText: String?,
        windowText: String?
    ) -> ContextInfo? {
        let focused = focusedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowExcerpt = windowText.map { tailExcerpt(from: $0, maxChars: 1200) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedFocused = (focused?.isEmpty == false) ? focused : nil
        let normalizedWindow = (windowExcerpt?.isEmpty == false) ? windowExcerpt : nil
        if normalizedFocused == nil, normalizedWindow == nil {
            return nil
        }
        return ContextInfo(accessibilityText: normalizedFocused, windowText: normalizedWindow)
    }

    private static func labelTexts(_ element: AXUIElement) -> [String] {
        guard let labels = axElementArrayAttribute(element, kAXLabelUIElementsAttribute as CFString) else {
            return []
        }

        var results: [String] = []
        for label in labels {
            let text = firstNonEmpty([
                stringAttribute(label, kAXTitleAttribute as CFString),
                stringAttribute(label, kAXDescriptionAttribute as CFString),
                stringAttribute(label, kAXValueAttribute as CFString),
            ])
            if let text {
                results.append(text)
            }
        }
        return results
    }

    private static func collectWindowVisibleText(from root: AXUIElement) -> String? {
        var queue: [AXUIElement] = [root]
        var visited: Set<Int> = []
        var uniqueLines: Set<String> = []
        var lines: [String] = []
        var accumulatedChars = 0

        let maxNodes = 500
        let maxLines = 120
        let maxChars = 4000
        let maxChildrenPerNode = 40

        while !queue.isEmpty,
              visited.count < maxNodes,
              lines.count < maxLines,
              accumulatedChars < maxChars {
            let element = queue.removeFirst()
            let key = Int(CFHash(element))
            if visited.contains(key) {
                continue
            }
            visited.insert(key)

            for candidate in textCandidates(from: element) {
                guard let normalized = normalizeWindowLine(candidate),
                      !uniqueLines.contains(normalized)
                else {
                    continue
                }
                uniqueLines.insert(normalized)
                lines.append(normalized)
                accumulatedChars += normalized.count + 1
                if lines.count >= maxLines || accumulatedChars >= maxChars {
                    break
                }
            }

            if let children = axElementArrayAttribute(element, kAXChildrenAttribute as CFString), !children.isEmpty {
                queue.append(contentsOf: children.prefix(maxChildrenPerNode))
            }
        }

        guard !lines.isEmpty else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private static func textCandidates(from element: AXUIElement) -> [String] {
        [
            stringAttribute(element, kAXValueAttribute as CFString),
            stringAttribute(element, kAXSelectedTextAttribute as CFString),
            stringAttribute(element, kAXTitleAttribute as CFString),
            stringAttribute(element, kAXDescriptionAttribute as CFString),
            stringAttribute(element, kAXHelpAttribute as CFString),
            stringAttribute(element, kAXPlaceholderValueAttribute as CFString),
        ]
        .compactMap { $0 }
    }

    private static func normalizeWindowLine(_ raw: String) -> String? {
        let flattened = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let chunks = flattened
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !chunks.isEmpty else {
            return nil
        }
        let joined = chunks.joined(separator: " ")
        let collapsed = joined.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        guard !collapsed.isEmpty else {
            return nil
        }
        let limit = min(collapsed.count, 220)
        return String(collapsed.prefix(limit))
    }

    private static func axErrorForAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
        var rawValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        return "\(err.rawValue)"
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
            return nil
        }
        return stringify(rawValue)
    }

    private static func intAttribute(_ element: AXUIElement, _ attribute: CFString) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
            return nil
        }
        guard let value = rawValue as? NSNumber else { return nil }
        return value.intValue
    }

    private static func rangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
            return nil
        }
        guard let axValue = rawValue, CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let value = unsafeDowncast(axValue, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func stringForRange(_ element: AXUIElement, _ range: CFRange) -> String? {
        var mutableRange = range
        guard let rangeAXValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var rawValue: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeAXValue,
            &rawValue
        )
        guard status == .success else {
            return nil
        }
        return stringify(rawValue)
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(rawValue, to: AXUIElement.self)
    }

    private static func axElementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement]? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let array = rawValue as? [Any]
        else {
            return nil
        }

        let typeID = AXUIElementGetTypeID()
        var result: [AXUIElement] = []
        for item in array {
            let anyRef = item as AnyObject
            let cf = anyRef as CFTypeRef
            guard CFGetTypeID(cf) == typeID else { continue }
            result.append(unsafeDowncast(cf, to: AXUIElement.self))
        }
        return result
    }

    private static func excerpt(from text: String, around center: Int, window: Int) -> String {
        let ns = text as NSString
        if ns.length == 0 {
            return ""
        }

        let safeCenter = min(max(center, 0), ns.length)
        let start = max(0, safeCenter - window)
        let end = min(ns.length, safeCenter + window)
        guard end > start else {
            return ""
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func tailExcerpt(from text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        let length = min(ns.length, maxChars)
        let location = ns.length - length
        return ns.substring(with: NSRange(location: location, length: length))
    }

    private static func stringify(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let attributed = value as? NSAttributedString {
            let string = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

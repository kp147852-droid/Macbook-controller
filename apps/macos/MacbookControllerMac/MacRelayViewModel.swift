import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
final class MacRelayViewModel: ObservableObject {
    @Published var relayHTTPURL = "http://127.0.0.1:8787"
    @Published var relayWSURL = "ws://127.0.0.1:8787"
    @Published var deviceToken = "change-me"
    @Published var pairingCode = "-"
    @Published var status = "Idle"

    private var socketTask: URLSessionWebSocketTask?
    private var frameTask: Task<Void, Never>?
    private let session = URLSession(configuration: .default)
    private let frameProducer = ScreenFrameProducer()
    private let injector = CGEventInjector()

    func startSession() async {
        stopSession()
        status = "Creating pairing code..."

        do {
            let code = try await createPairCode()
            pairingCode = code
            status = "Code \(code) created. Connecting..."
            try connectWebSocket(code: code)
            receiveLoop()
            startFrameLoop()
            status = "Connected. Waiting for iPhone controller..."
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stopSession() {
        frameTask?.cancel()
        frameTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        status = "Stopped"
    }

    private func createPairCode() async throws -> String {
        guard let url = URL(string: relayHTTPURL + "/api/codes") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Relay", code: 1)
        }

        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let code = payload?["code"] as? String else {
            throw NSError(domain: "Relay", code: 2)
        }
        return code
    }

    private func connectWebSocket(code: String) throws {
        let clean = relayWSURL.hasSuffix("/") ? String(relayWSURL.dropLast()) : relayWSURL
        guard let url = URL(string: "\(clean)/ws/mac/\(code)?token=\(deviceToken)") else {
            throw URLError(.badURL)
        }

        let task = session.webSocketTask(with: url)
        socketTask = task
        task.resume()
    }

    private func receiveLoop() {
        guard let task = socketTask else { return }

        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .failure(let error):
                    self.status = "Socket receive error: \(error.localizedDescription)"
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleIncomingMessage(obj)
                    }
                    self.receiveLoop()
                @unknown default:
                    self.receiveLoop()
                }
            }
        }
    }

    private func startFrameLoop() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let socketTask = self.socketTask else {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    continue
                }

                do {
                    if let frame = try await self.frameProducer.makeFrameMessage() {
                        let data = try JSONSerialization.data(withJSONObject: frame)
                        if let text = String(data: data, encoding: .utf8) {
                            try await socketTask.send(.string(text))
                        }
                    }
                } catch {
                    self.status = "Frame send error: \(error.localizedDescription)"
                }

                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    private func handleIncomingMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        if type == "status", let text = message["message"] as? String {
            status = text
            return
        }

        injector.apply(message: message)
    }
}

actor ScreenFrameProducer {
    private var contentFilter: SCContentFilter?
    private var width = 1280
    private var height = 720

    func makeFrameMessage(quality: CGFloat = 0.45) async throws -> [String: Any]? {
        let filter = try await getContentFilter()
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)

        guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }

        let b64 = data.base64EncodedString()
        return [
            "type": "frame",
            "width": width,
            "height": height,
            "image": "data:image/jpeg;base64,\(b64)",
        ]
    }

    private func getContentFilter() async throws -> SCContentFilter {
        if let contentFilter {
            return contentFilter
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first else {
            throw NSError(domain: "ScreenCapture", code: 1)
        }

        width = Int(display.width)
        height = Int(display.height)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.contentFilter = filter
        return filter
    }
}

final class CGEventInjector {
    private let displayBounds = CGDisplayBounds(CGMainDisplayID())

    func apply(message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "move":
            mouseMove(message)
        case "click":
            mouseClick(message, count: 1)
        case "double_click":
            mouseClick(message, count: 2)
        case "scroll":
            scroll(message)
        case "key":
            keyPress(message)
        case "type_text":
            typeText(message)
        default:
            break
        }
    }

    private func point(from message: [String: Any]) -> CGPoint {
        let x = (message["x"] as? Double) ?? 0.5
        let y = (message["y"] as? Double) ?? 0.5
        return CGPoint(
            x: displayBounds.origin.x + displayBounds.width * x,
            y: displayBounds.origin.y + displayBounds.height * y
        )
    }

    private func mouseMove(_ message: [String: Any]) {
        let p = point(from: message)
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
    }

    private func mouseClick(_ message: [String: Any], count: Int) {
        let p = point(from: message)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(count))

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        if count == 2 {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func scroll(_ message: [String: Any]) {
        let amount = (message["amount"] as? Int) ?? 0
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    private func keyPress(_ message: [String: Any]) {
        guard let key = message["key"] as? String else { return }
        let keyCode = keyCodeFor(key)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func typeText(_ message: [String: Any]) {
        guard let text = message["text"] as? String else { return }
        let chars = Array(text.utf16)
        guard !chars.isEmpty else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up?.post(tap: .cghidEventTap)
    }

    private func keyCodeFor(_ key: String) -> CGKeyCode {
        switch key.lowercased() {
        case "esc", "escape": return 53
        case "return", "enter": return 36
        case "space": return 49
        case "tab": return 48
        case "delete", "backspace": return 51
        case "up": return 126
        case "down": return 125
        case "left": return 123
        case "right": return 124
        default: return 53
        }
    }
}

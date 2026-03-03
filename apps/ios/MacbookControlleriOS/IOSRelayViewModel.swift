import Foundation
import SwiftUI
import UIKit

@MainActor
final class IOSRelayViewModel: ObservableObject {
    @Published var relayWSURL = "ws://127.0.0.1:8787"
    @Published var code = ""
    @Published var status = "Idle"
    @Published var frameImage: UIImage?
    @Published var textToSend = ""

    private let session = URLSession(configuration: .default)
    private var socketTask: URLSessionWebSocketTask?

    func connect() {
        disconnect()

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCode.count == 6 else {
            status = "Enter the 6-digit pairing code"
            return
        }

        let base = relayWSURL.hasSuffix("/") ? String(relayWSURL.dropLast()) : relayWSURL
        guard let url = URL(string: "\(base)/ws/phone/\(trimmedCode)") else {
            status = "Invalid relay URL"
            return
        }

        let task = session.webSocketTask(with: url)
        socketTask = task
        task.resume()
        status = "Connected. Waiting for frames..."
        receiveLoop()
    }

    func disconnect() {
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        status = "Disconnected"
    }

    func sendClick(x: CGFloat, y: CGFloat) {
        send(["type": "click", "x": x, "y": y, "button": "left"])
    }

    func sendScroll(_ amount: Int) {
        send(["type": "scroll", "amount": amount])
    }

    func sendKey(_ key: String) {
        send(["type": "key", "key": key])
    }

    func sendText() {
        let text = textToSend
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(["type": "type_text", "text": text])
        textToSend = ""
    }

    private func send(_ payload: [String: Any]) {
        guard let task = socketTask else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }

        task.send(.string(text)) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.status = "Send failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func receiveLoop() {
        guard let task = socketTask else { return }

        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .failure(let error):
                    self.status = "Socket error: \(error.localizedDescription)"
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.processMessage(obj)
                    }
                    self.receiveLoop()
                @unknown default:
                    self.receiveLoop()
                }
            }
        }
    }

    private func processMessage(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }

        if type == "status", let message = obj["message"] as? String {
            status = message
            return
        }

        if type == "frame", let imageString = obj["image"] as? String {
            let prefix = "data:image/jpeg;base64,"
            guard imageString.hasPrefix(prefix) else { return }
            let raw = String(imageString.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: raw), let image = UIImage(data: data) else { return }
            frameImage = image
            status = "Live"
        }
    }
}

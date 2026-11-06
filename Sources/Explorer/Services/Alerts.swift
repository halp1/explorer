import AppKit
import AVFoundation
import ExplorerKit

enum Alerts {
    static func error(_ title: String, _ message: String, window: NSWindow?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        present(a, window)
    }

    static func info(_ title: String, _ message: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        present(a, window)
    }

    static func present(_ a: NSAlert, _ window: NSWindow?) {
        if let window, window.attachedSheet == nil { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    /// Asks for a text value. Returns nil on cancel.
    static func prompt(_ title: String, message: String = "", defaultValue: String = "", ok: String = "OK",
                       selectStem: Bool = true, secure: Bool = false, accessory extra: NSView? = nil) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        let field: NSTextField = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                                        : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultValue
        if let extra {
            let stack = NSStackView(views: [field, extra])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 300, height: 24 + extra.fittingSize.height + 8)
            a.accessoryView = stack
        } else {
            a.accessoryView = field
        }
        a.window.initialFirstResponder = field
        DispatchQueue.main.async {
            if selectStem, let editor = field.currentEditor() {
                let stem = (defaultValue as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
            }
        }
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func confirm(_ title: String, _ message: String, ok: String, destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = destructive ? .critical : .warning
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        if destructive { a.buttons[0].hasDestructiveAction = true }
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// Short UI sounds: synthesized in-app tones, the system alert sound, or nothing.
enum Sounds {
    enum Kind { case done, error, question }

    private static var cache: [Kind: NSSound] = [:]

    static func play(_ k: Kind) {
        switch Preferences.shared.sounds {
        case .off: return
        case .system:
            switch k {
            case .error: NSSound.beep()
            case .done, .question: _ = NSSound(named: "Tink")?.play()
            }
        case .inApp:
            if cache[k] == nil, let s = synthesize(k) { cache[k] = s }
            cache[k]?.stop()
            cache[k]?.play()
        }
    }

    /// Builds a tiny WAV in memory: a soft two-tone chime per kind.
    static func synthesize(_ k: Kind) -> NSSound? {
        let rate = 44100.0
        let notes: [(Double, Double)]
        switch k {
        case .done: notes = [(880, 0.07), (1320, 0.12)]
        case .error: notes = [(300, 0.10), (240, 0.16)]
        case .question: notes = [(660, 0.08), (880, 0.10)]
        }
        var samples: [Int16] = []
        for (f, d) in notes {
            let n = Int(rate * d)
            for i in 0..<n {
                let t = Double(i) / rate
                let env = min(1, Double(i) / 200) * exp(-4 * t / d)
                let v = sin(2 * .pi * f * t) * 0.25 * env + sin(4 * .pi * f * t) * 0.05 * env
                samples.append(Int16(v * Double(Int16.max)))
            }
        }
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let byteCount = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!); u32(36 + byteCount); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return NSSound(data: data)
    }
}

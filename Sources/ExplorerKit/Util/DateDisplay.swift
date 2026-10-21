import Foundation

public enum DateLength: String, Codable, CaseIterable, Sendable {
    case short = "Short", medium = "Medium", long = "Long"
    public var style: DateFormatter.Style {
        switch self { case .short: return .short; case .medium: return .medium; case .long: return .long }
    }
}

public enum DateDisplayMode: String, Codable, CaseIterable, Sendable { case relative = "Relative", absolute = "Absolute" }

/// Formats dates the way file views show them ("Today at 10:15", "Yesterday", or an absolute date).
public struct DateDisplay {
    public var length: DateLength
    public var mode: DateDisplayMode
    public var showTime: Bool
    public var calendar: Calendar

    public init(length: DateLength = .medium, mode: DateDisplayMode = .relative, showTime: Bool = true, calendar: Calendar = .current) {
        self.length = length; self.mode = mode; self.showTime = showTime; self.calendar = calendar
    }

    public func string(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        f.dateStyle = length.style
        f.timeStyle = showTime ? .short : .none
        f.doesRelativeDateFormatting = mode == .relative
        return f.string(from: date)
    }
}

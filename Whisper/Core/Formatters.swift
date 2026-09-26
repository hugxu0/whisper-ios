import Foundation
import UIKit

enum Format {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    static let time = formatter("HH:mm")
    static let monthDay = formatter("M月d日")
    static let monthDayWeek = formatter("M月d日 EEEE")
    static let fullDate = formatter("yyyy年M月d日")
    static let fullDateTime = formatter("yyyy年M月d日 HH:mm")
    static let dayKey = formatter("yyyy-MM-dd")
    static let yearMonth = formatter("yyyy年M月")
    static let weekday = formatter("EEEE")

    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    static func dayKey(_ date: Date) -> String { dayKey.string(from: date) }

    static func parseDay(_ key: String) -> Date? { dayKey.date(from: key) }

    /// 聊天里的时间分隔：今天只显示时间，昨天、本周、今年、更早各有写法
    static func separator(_ date: Date, now: Date = Date()) -> String {
        let clock = time.string(from: date)
        if calendar.isDateInToday(date) { return clock }
        if calendar.isDateInYesterday(date) { return "昨天 \(clock)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(weekday.string(from: date)) \(clock)" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return "\(monthDay.string(from: date)) \(clock)" }
        return "\(fullDate.string(from: date)) \(clock)"
    }

    /// 会话列表、最后在线等简短时间
    static func short(_ date: Date, now: Date = Date()) -> String {
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return weekday.string(from: date) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return monthDay.string(from: date) }
        return fullDate.string(from: date)
    }

    static func lastSeen(_ ms: Double?) -> String {
        guard let ms else { return "离线" }
        let date = self.date(ms)
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚在线" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前在线" }
        if calendar.isDateInToday(date) { return "今天 \(time.string(from: date)) 在线" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time.string(from: date)) 在线" }
        return "\(short(date)) 在线"
    }

    static func relative(_ ms: Double) -> String {
        let seconds = Date().timeIntervalSince(date(ms))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return short(date(ms))
    }

    static func duration(_ ms: Int?) -> String {
        let total = max(0, (ms ?? 0) / 1000)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func voiceSeconds(_ ms: Int?) -> String {
        "\(max(1, Int(((Double(ms ?? 0)) / 1000).rounded())))″"
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 两个日期之间差几天（按自然日）
    static func daysBetween(_ from: Date, _ to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

enum IDs {
    /// 客户端生成的消息 ID，服务端要求 6~80 位字母数字下划线横线
    static func message() -> String { "c_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

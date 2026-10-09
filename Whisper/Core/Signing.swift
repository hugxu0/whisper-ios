import UIKit

/// 侧载的 App 里带着描述文件（embedded.mobileprovision）。免费 Apple ID 签的七天后过期，过期就打不开了。
/// 这里读出到期时间，快到期时在“我”页面提醒；用 SideStore 装的可以在手机上直接续签（见 docs/DEPLOY.md）。
enum Signing {
    /// 签名什么时候到期；模拟器、开发时直接运行没有描述文件，是 nil
    static let expiresAt: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// 还剩几天，不到一天算 0
    static func daysLeft(now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(now) / 86_400))
    }

    /// 剩两天以内就提醒
    static func expiringSoon(now: Date = Date()) -> Bool {
        guard let days = daysLeft(now: now) else { return false }
        return days <= 2
    }

    private static let sideStore = URL(string: "sidestore://")!

    /// 装了 SideStore 就打开它去续签，没装返回 false
    @MainActor
    static func openSideStore() -> Bool {
        guard UIApplication.shared.canOpenURL(sideStore) else { return false }
        UIApplication.shared.open(sideStore)
        return true
    }
}

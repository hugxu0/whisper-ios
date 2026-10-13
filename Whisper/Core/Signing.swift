import UIKit

/// 侧载的 App 里带着描述文件（embedded.mobileprovision），免费 Apple ID 签的七天后过期。
/// 不显示到期时间：SideStore 续签只往系统里装新的描述文件，不改包里这份，读出来的一直是第一次安装时的日期；
/// 系统里那份 App 读不到，所以只在“我”页面放一个打开 SideStore 的入口，天数以 SideStore 里显示的为准（见 docs/DEPLOY.md）。
enum Signing {
    /// 是不是侧载装的；模拟器、开发时直接运行没有描述文件
    static let isSideloaded = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil

    private static let sideStore = URL(string: "sidestore://")!

    /// 装了 SideStore 就打开它去续签，没装返回 false
    @MainActor
    static func openSideStore() -> Bool {
        guard UIApplication.shared.canOpenURL(sideStore) else { return false }
        UIApplication.shared.open(sideStore)
        return true
    }
}

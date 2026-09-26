# 漫长悄悄话 · iOS 客户端

两个人用的私人聊天 App「漫长悄悄话」的 iOS 客户端。只有两个固定账号能登录，服务端和部署不在这个仓库里。

这个仓库只用来在 GitHub Actions 上打未签名的 IPA（用 iloader 侧载），代码从私有仓库同步过来，不接受 PR。

- iOS 26 以上，SwiftUI + UIKit（聊天时间线），XcodeGen 生成工程，没有第三方依赖
- 打包：推送到 `main` 自动触发 `.github/workflows/build.yml`，IPA 在这次运行的 artifacts 里

## 致谢

3D 大橘模型：[Cute Cartoon Cat Low Poly Game Ready](https://sketchfab.com/Hdjusj)，作者 3Dima，[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。

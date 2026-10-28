# Wow

Wow 是一个使用 Swift、SwiftUI 和 UIKit 开发的原生 iOS 工具箱，将计划管理、图片标注、提词和本地记账整合在一起。最低系统版本为 **iOS 18**。

## 功能

- **首页与计划**：管理计划、购物、灵感和归档；通过用户选择的文件夹读取 Markdown 日计划、更新任务勾选状态，并设置本地提醒。
- **Picture Remarker**：照片导入、相机拍照、图形标注、马赛克、图片图层、缩放、撤销及图片导出。
- **Teleprompter**：台词草稿、滚动提词、字号与速度调节、浮动提词窗口，以及无声视频录制和相册保存。
- **Counter**：本地收支、账户、转账、分类、月度统计、截图 OCR 待确认、账单导入导出、备份，以及分享扩展和实时活动。

应用数据保存在设备本地。文件夹、照片、相机和通知功能按需申请系统权限；提词器录制不采集麦克风声音。应用无需配置远程 AI 服务或 API 密钥。

## 项目结构

```text
Wow.xcworkspace/                    Xcode 工作区
CheckBot 首页/ios/                  Wow 主应用、首页、Plan 集成和测试
picture-remarker(mainIOS) copy/     图片编辑器及其独立工程
提词器 copy/                       提词器及其独立工程
Counter copy/                      本地 Swift Package、独立工程、扩展和测试
scripts/                           源码检查和发布辅助工具
```

目录名称及相对位置参与 Xcode 和本地 Swift Package 引用，请保持原样。Wow 直接引用图片与提词器模块的源码，Counter 通过本地 `CounterTool` Package 集成，无需安装 npm 应用依赖。

## 构建

需要 macOS、Xcode 和 iOS Simulator SDK。用 Xcode 打开根目录的 `Wow.xcworkspace`，选择 **Wow** Scheme 和 iPhone 模拟器后运行。

```sh
xcodebuild -workspace Wow.xcworkspace -scheme Wow \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

源码保留原有 Bundle ID、App Group 和签名工程配置，以维持现有安装的数据兼容性；不包含证书、私钥或描述文件。使用自己的真机签名时，需要自行选择开发团队，并协调主应用、Widget、分享扩展的 Bundle ID 与 App Group。请勿在保有重要数据的已安装版本上直接试验标识符变更。

## 检查与测试

跨平台基础检查（Python 3、Git）：

```sh
python3 scripts/cloud-check.py
```

在 Mac 上用 `xcrun simctl list devices available` 查找实际 iPhone 模拟器 UDID，再运行：

```sh
xcodebuild -workspace Wow.xcworkspace -scheme Wow \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:CheckBotTests test
```

导航测试位于 `CheckBotUITests/WowNavigationTests`。其中部分用例会建立或修改测试数据，请使用独立模拟器。照片导入用例需要预先添加测试图片，文件夹选择相关测试可用 `CheckBot 首页/scripts/prepare-ios-picker-test.mjs` 准备隔离夹具。相机与真实设备录制仍需真机验证。

## 开源范围与许可

源码采用 [MIT License](LICENSE)，Picture Remarker 原有版权声明继续保留。发布范围、资源说明及排除项见 [OPEN_SOURCE.md](OPEN_SOURCE.md)。公开版本不包含第三方官方品牌图标，账户界面使用现有系统图标回退逻辑。

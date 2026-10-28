# 开源发布范围

首次公开发布为经过筛选的当前源码快照，不包含此前的本地 Git 历史。原工作目录、历史记录、签名配置和用户数据保留在本地。

## 包含

- Wow 主应用、三个工具模块、Counter 本地 Swift Package、Widget 和分享扩展。
- Xcode 工程、共享 Scheme、工作区、必要的资源目录、无声伙伴动画。
- XCTest 源码和用于迁移测试的合成 SQLite 夹具；该夹具不是个人账本。
- 构建说明、基础检查脚本、MIT 许可证和 Picture Remarker 原版权声明。

## 排除

- 验收截图、录屏、设计参考图和内部审阅/规划文档。
- 第三方官方银行及支付品牌图标 `brand_*.imageset`；现有 `AccountIconArtwork` 在资源缺失时显示系统图标，账户数据和识别规则不变。
- 重复的 `CompanionLoop.mov`、`CompanionLoop.mp4`，只保留应用实际引用的 `CompanionLoopSilent.mp4`。导出时也从 Package 的排除列表中移除前两项。
- 构建产物、IDE 个人状态、缓存、日志、证书、私钥、描述文件、环境变量文件和个人数据库/备份。
- 本地 Git 历史及其作者邮箱。公开快照使用 GitHub noreply 提交邮箱。

## 素材与归属

Counter 分类插画、头像及应用图标的项目来源记录见 `Counter copy/CounterApp/ASSET_SOURCES.md`。伙伴动画是项目中由维护者提供并用于应用的本地资源；仅保留无声音轨版本。项目源码和随附项目资源按根目录 MIT 许可证发布，已有子模块版权声明仍适用。

第三方品牌名称仅用于账户识别；不表示合作或背书，也不授予第三方商标权。官方品牌图标不随公开快照分发。

## 导出方式

在完成本地审阅并提交后运行：

```sh
python3 scripts/export-open-source.py /absolute/path/to/new/Wow
```

工具只从当前 `HEAD` 的白名单路径读取文件，拒绝覆盖已有目录，不复制 `.git`，不创建远程仓库或执行推送。`SOURCE_MANIFEST.json` 记录导出来源提交和每个导出文件的 SHA-256，可用于核对发布内容。清单不包含它自身。

导出是文件筛选工具，不替代每次发布前的敏感信息和资源审阅。检查导出副本后，在副本内初始化独立 Git 仓库、运行 `scripts/cloud-check.py` 和必要的 Xcode 验证，再通过本地 Git 推送。不要直接推送未经历史审阅的开发仓库。

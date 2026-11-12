# SeekZip

[English](README.md) | [Tiếng Việt](README.vi.md) | **简体中文**

**Find it inside. Extract only what you need.**

文档：[从零构建](docs/BUILD_FROM_ZERO.zh-CN.md) ·
[架构](docs/ARCHITECTURE.zh-CN.md) ·
[测试矩阵](docs/TEST-MATRIX.zh-CN.md) ·
[Agent 交接](docs/HANDOFF.zh-CN.md) ·
[参考研究](docs/REFERENCE.md) ·
[发布指南](docs/RELEASE.md)
（每份文档另有 Tiếng Việt 和简体中文版本，后缀分别为 `.vi.md` / `.zh-CN.md`）

一款免费的 macOS 原生归档管理器，专为 Apple Silicon 打造——在解压之前先浏览和
预览归档内容，只解压您选中的文件，并可创建或编辑归档。本项目在研究参考项目
之后（见 `docs/REFERENCE.md`）以 Swift/SwiftUI 净室（clean-room）方式构建；
未复制任何第三方应用代码。

**采用真正的 7-Zip 引擎。**SeekZip 没有重新实现压缩：创建、解压、校验和列出
归档都在官方 `7zz` 二进制文件（7-Zip 26.05，随应用打包）上运行。这与 Windows
版 7-Zip 使用的是同一引擎——在同一台机器上实测：从 150 MB 文本创建 7z 文件
耗时 163.5 秒，而原生 `7zz` 为 158.2 秒，输出字节完全相同。强大来自 7-Zip，
25 年久经验证；SeekZip 是围绕它打造的 macOS 原生应用。（XAD 引擎 `lsar`/`unar`
仅处理 7zz 不支持的旧格式。）

## 架构

一个引擎，三个前端：

```
            ┌─────────────┐
            │ SeekZipApp  │  SwiftUI GUI (browse, preview, queue)
            ├─────────────┤
 frontends  │ seekzip     │  CLI — scriptable, `--json`, stable exit codes
            ├─────────────┤
            │ seekzip-mcp │  MCP server (stdio) for AI assistants
            └──────┬──────┘
                   │
            ┌──────▼──────┐
            │SeekZipCore  │  engine wrapper, listing parser, path safety,
            │             │  queue, models — the only place logic lives
            └──────┬──────┘
                   │  Process (streaming, never loads archives into RAM)
            ┌──────▼──────┐
            │  7zz (7-Zip)│  bundled official macOS ARM binary
            └─────────────┘
```

为什么既要 CLI *又要* MCP，而不是只让终端访问 7-Zip？原始终端给 AI 和脚本
的是非结构化文本，没有共享的队列/密码状态，也没有内置的 zip-slip 防护。CLI
提供结构化 JSON 和稳定的退出代码（也是 CI 中无头运行测试矩阵的工具）；MCP
服务器是构建在同一核心之上的薄模式层（thin schema layer），让 AI 助手获得
安全、带类型的工具（`list_archive`、`extract_entries`、……），而不必解析
shell 输出。

## 状态

v0.1 脚手架：核心模型、`7zz -slt` 列表解析器、解压路径安全、CLI、MCP 服务
器骨架、SwiftUI 浏览器骨架、完整的测试矩阵规格（`docs/TEST-MATRIX.zh-CN.md`）、
macOS CI。

M1 已通过：`swift build` + `swift test` + CLI 冒烟测试在 CI（macos-15）
上通过。M2 已完成：列表从 `7zz` 流式读取（增量解析器、进度、取消、
`list --stream`）。M3 已完成：预览（文本经 `7zz e -so` 流式读入，上限
64 KB / 200 行；图片、PDF 与二进制文件交由 Quick Look）与嵌套归档
（`list outer.zip inner.zip`、`preview outer.zip "inner.zip!/file.txt"`）。
GUI 预览接线目前仅为代码，需待 M7 的 Xcode 工程。M4 已完成：持久化任务
队列——批量解压/创建/测试，支持暂停/继续/取消、临时名 + 原子重命名创建、
磁盘空间预检、干净的 Ctrl-C 处理——通过 `seekzip queue` 与 MCP 队列工具
使用。GUI 队列面板目前仅为代码，需待 M7 的 Xcode 工程。M5 已完成：创建/
编辑完善——在 ZIP/7z/TAR 归档中添加、删除与重命名条目（临时副本 + 原子
重命名，失败的编辑绝不会损坏原文件）、格式转换（ZIP ↔ 7z ↔ TAR；无法
创建 RAR）、逐条目的 CRC-32/SHA-256 校验与 `verify` 命令，以及密码存入
macOS Keychain（另一通道为 `SEEKZIP_PASSWORD` 环境变量，绝不使用 `-p`
参数）。GUI 编辑面板与 CRC 列目前仅为代码，需待 M7 的 Xcode 工程。M6 已完成：路由协议后的 XAD 备用引擎——带能力矩阵的 `ArchiveEngine`、`EngineRouter`（优先 7zz，失败或空列表时回退到 XAD；StuffIt/Zoo/ARC 等旧格式优先 XAD；加密 7z 始终使用 7zz）、经 `lsar`/`unar` 的 XAD 列表/解压/测试（仅解压，通过暂存目录解压故失败不留残余文件，恢复的文件名编码保留在条目元数据中）、CLI `--engine auto|7zz|xad` 与 `seekzip engines`、MCP 的 `engine` 参数与 `list_engines` 工具、GUI 引擎设置（目前仅为代码，需待 M7 的 Xcode 工程）。`seekzip list/test/extract` 会报告处理该归档的引擎。

M7 已完成：扩展与打包——`SeekZip.xcodeproj`（应用 + Finder Sync + Quick Look 预览扩展，共享静态库 SeekZipCore，并通过 App Group 共享引擎设置）、由 `scripts/package-engines.sh` 准备的 7zz/lsar/unar 二进制文件（7-Zip 26.05，已固定 SHA-256）放入应用包的 `Resources/Helpers/` 并以 inherit entitlement 签名、`scripts/release.sh`（归档、Developer ID 导出、公证、装订、DMG/ZIP），以及 `packaging/homebrew/` 中的 Homebrew formula 与 cask（tap `TranManhTuanLabs/homebrew-seekzip`）。M6 遗留的 XAD 预览缺口已补上：预览仅支持 XAD 的归档中的条目时，会将该条目解压到临时目录再读取受限的头部（仍遵循 64 KB / 200 行规则）。GUI 仍需在装有完整 Xcode 的 Mac 上完成首次真实构建——见 `docs/RELEASE.md`。

## 构建（在 Mac 上）

```sh
swift build          # core + CLI + MCP（GUI 需要完整 Xcode，见 Package.swift）
swift test           # unit tests for parser and path safety
./Tests/Matrix/generate-matrix.sh   # build the edge-case fixture archives
```

应用（Xcode 工程——首次构建需要在装有完整 Xcode 的 Mac 上）：

```sh
open SeekZip.xcodeproj   # 设置你的 Team，然后 Product > Build（⌘B）
./scripts/package-engines.sh   # 将 7zz/lsar/unar 准备到 build/Helpers
./scripts/release.sh           # 归档、公证、DMG（需要 DEVELOPER_TEAM_ID）
```

完整发布检查清单见 `docs/RELEASE.md`，包括首次签名发布前必须解决的 Apple Developer 账号与磁盘空间问题。

## 队列

```sh
seekzip queue add extract big.zip ~/out   # 入队，暂不运行
seekzip queue add create out.7z src --format 7z
seekzip queue run                         # 按顺序运行已入队的任务
seekzip queue list                        # 持久化任务——重启应用后仍在
seekzip queue pause <id>                  # SIGSTOP；恢复后原地继续
seekzip queue cancel <id>                 # 终止 7zz，清理临时输出
```

任务逐个顺序运行，保存在
`~/Library/Application Support/SeekZip/queue.json`。创建归档时，7zz
先写入暂存目录，成功后才重命名到位，因此取消或失败的创建不会留下
写了一半的文件。解压与创建都会先检查剩余空间，目标卷空间不足时
立即报错。密码永不写入队列文件——来自 `SEEKZIP_PASSWORD` 或 Keychain
（见下文）。

## 编辑、转换、校验

```sh
seekzip add archive.zip newfile.txt --into docs   # 添加条目（ZIP/7z/TAR）
seekzip remove archive.zip old.txt                # 删除条目
seekzip rename archive.zip old.txt new.txt        # 重命名（仅 ZIP/7z）
seekzip convert archive.zip archive.7z            # 转换 ZIP → 7z（也支持 7z → ZIP、TAR → 7z）
seekzip verify archive.zip [--sha256]             # 重新校验每个条目的 CRC（及 SHA-256）
seekzip checksums archive.zip                     # 每个条目的 CRC-32，来自列表
```

每次编辑都在同一文件夹的临时副本上进行，只有编辑后的副本能干净列出
时才以原子重命名替换原文件——失败的编辑会让原文件逐字节保持不变。
转换时先解压到临时目录再重新创建；条目名与内容得以保留，而转换*为*
RAR 会明确报错（没有任何第三方工具能创建 RAR）。`verify` 会逐个流式
读取条目并计算哈希（CRC-32，加上 `--sha256` 时还有 SHA-256），再与列表
中的 CRC 对照；损坏的条目会被报告，其余条目仍会继续校验。

## 密码

```sh
SEEKZIP_PASSWORD=hunter2 seekzip list secret.zip  # 环境变量（绝不使用 -p 参数）
seekzip password store secret.zip                 # 存入 macOS Keychain（会提示输入两次）
seekzip password forget secret.zip                # 忘记已保存的密码
```

密码绝不作为命令行参数传入（那样会出现在进程列表中）。CLI 从
`SEEKZIP_PASSWORD` 或已保存的密码获取密码——在应用与 CLI 中使用 macOS
Keychain（`com.seekzip.passwords`），Linux 测试运行时仅用内存存储。
显式传入的密码永远优先于已保存的密码。MCP 工具使用相同的 `password`
字段（`add_entries`、`remove_entries`、`rename_entries`、
`convert_archive`、`verify_archive`）。

RAR 归档可以解压但不能创建——RAR 的创建是专有技术
（所有 macOS 归档工具都是如此）。

## 支持

如果这个应用对你有帮助，请请我喝杯咖啡，支持我继续完善它。

<img src="SeekZip/DonateCard.png" width="300" alt="VietQR 捐赠卡——BIDV，账号 2600786466，TRAN MANH TUAN">

BIDV — 2600786466 — TRAN MANH TUAN

## 许可证

MIT（计划中）。内置的 `7zz` 仍遵循 7-Zip 的 LGPL 许可证。

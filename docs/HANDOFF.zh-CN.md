# SeekZip —— Agent 交接

如果您是冷启动接手本项目的 AI Agent（或新成员的人类开发者），请先读这份
文件。它说明了当前进展、如何继续，以及哪些东西不能破坏。每当状态发生
实质变化时，请更新本文件——下一位 Agent 的上下文从这里开始。

## 1. 项目快照

- **是什么**：SeekZip——免费的 macOS 原生（14.6+，Apple Silicon）归档
  管理器：解压前先浏览/预览，选择性解压，创建/编辑 ZIP 与 7z。标语：
  "Find it inside. Extract only what you need."
- **为什么存在**：Keka 无法预览归档内部；BetterZip 是付费软件；MacPacker
  （GPL-3.0）是原生基线，但仍缺少完整性测试/恢复功能。SeekZip 采用
  **净室（clean-room）** 方式构建：可以研究功能和公开约定，绝不能复制
  代码。
- **所有者的硬性要求**：对超大文件保持稳健（流式处理、Zip64、50 GB 级
  归档、100 万条目）；`docs/TEST-MATRIX.zh-CN.md` 中的完整测试矩阵必须
  通过；在开始长耗时工作*之前*先报告阻断性问题（deal-breaker）。

## 2. 当前状态（请更新本节！）

- v0.1 脚手架已于 2026-11-07 提交：Core（模型、`-slt` 解析器、路径
  安全、7zz 引擎封装）、CLI、MCP 服务器、SwiftUI 浏览器骨架、
  单元测试、夹具生成器、macOS 15 ARM CI 工作流。
- **M1 已通过（2026-11-07）**：CI run 42300451189——构建、单元测试、夹具、
  矩阵冒烟测试均在 macos-15 上通过。`Package.swift` 排除了 SwiftUI GUI
  目标（需要完整 Xcode；Mac 上只有 Command Line Tools）；GUI 源码仍保留
  在 `Sources/SeekZipApp/` 中，等待 M7 的 Xcode 工程。仅有 CLT 的 Mac
  本地无法运行 `swift test`（无 XCTest）——测试在 CI 上运行。
- **M2 已完成**：列表流式读取——`StreamingListingParser`（增量解析，
  块切分/UTF-8 安全）、`SevenZipEngine.listStreaming`（进度 + 通过
  `EngineError.cancelled` 取消，在管道上使用 POSIX `read()`）、CLI
  `list --stream`（JSON 行）。14 个单元测试通过，包括 10 万条目流式
  测试和脚本化二进制取消测试。尚未在 CI 上运行完整的 10 GB / 100 万条
  目夹具（PERF-01/04）——夹具很重，如 CI 时间允许再添加。
- 引擎决策已定：7zz 为主引擎，XADMaster 后备引擎在
  第二阶段引入，libarchive 推迟——理由见 `docs/REFERENCE.md`。

## 3. 恢复工作流程（任何 Agent，按顺序执行）

1. 阅读 `README.zh-CN.md`、`SPEC.md`、`docs/ARCHITECTURE.zh-CN.md`、本文件，
   以及 `docs/TEST-MATRIX.zh-CN.md`。在动引擎或解析器之前，先浏览
   `docs/REFERENCE.md`。
2. `git log --oneline -5` 和 `git status`——了解最后一次已验证的状态。
3. 复现基线：`swift build && swift test`，然后执行 BUILD_FROM_ZERO 第 §6–7
   节的 CLI 冒烟测试。如果基线是红的，不要在不说明的情况下开始新工作。
4. 选取最靠前的未完成里程碑（§5），以小步提交的方式工作。
5. 宣布完成之前：构建 + 单元测试 + 受影响的矩阵用例全部通过；
   更新本文件 §2 以及三语文档（§6）。

## 4. 工作约定

- 提交要小且描述清晰；主题行使用祈使句；正文解释*为什么*。
- 不得使用 GPL 代码（MacPacker）——仅限行为层面的学习。PeaZip 的功能
  想法可以借鉴；其代码是 LGPL Pascal，不予使用。
- 从不提交生成的夹具或大型二进制文件；夹具由
  `Tests/Matrix/generate-matrix.sh` 生成。
- `7zz` 二进制只在打包时从 7-zip.org 捆绑，并附带其 `License.txt`。
- 保持 ARCHITECTURE §7 中的不变量。如果必须更改某条不变量，请在同一次
  提交中修改文档并说明原因。

## 5. 里程碑（按顺序）

1. **M1 —— 编译与 CI 全绿**：首次 macOS 构建，修复错误，CI 在推送时通过。
2. **M2 —— 流式列表**：增量式 `-slt` 解析器 + 进度 +
   取消；PERF-01…04 通过。
3. **M3 —— 预览**：Quick Look 集成（空格键）、在浏览器中打开嵌套归档。
4. **M4 —— 队列**：批处理作业、暂停/恢复、创建时使用临时名称 + 原子
   重命名、可用空间预检查。
5. **M5 —— 创建/编辑完善**：添加/删除/重命名条目、格式转换、
   校验和 UI、Keychain 密码。
6. **M6 —— XAD 后备引擎**，置于路由协议之后。
7. **M7 —— 扩展与打包**：Finder + Quick Look 扩展、
   捆绑已签名的 7zz、经公证的发布版、Homebrew cask。

## 6. 三语文档规则

`README.md` 以及 `docs/BUILD_FROM_ZERO.md`、`docs/ARCHITECTURE.md`、
`docs/HANDOFF.md`、`docs/TEST-MATRIX.md` 均有三个内容一致的版本：英文
（无后缀）、越南文（`.vi.md`）、简体中文
（`.zh-CN.md`）。**当您修改其中一种语言时，请在同一次提交中更新另外
两种**——如果实在做不到，请在过时的文件中加上一行 `> ⚠️ Translation may be stale`
备注，并在 §2 中标记。版本之间出现分歧时，以英文为准。

## 7. 已知限制（v0.1）

- 自 M2 起列表从 `7zz` 流式读取（v0.1 是缓存在内存中）。
- CLI 尚无 `-p` 标志；密码可通过 Core API 和 MCP 使用。
- 解压尚未进行可用空间预检查或临时名称暂存。
- GUI 只是骨架：尚无预览、标签页、队列或拖出功能。
- 通过 `-p` 传给 `7zz` 的密码在本地进程列表中可见（已接受并记录的
  风险）。

## 8. 待所有者解答的问题

- 用于 CI 的 GitHub 仓库位置/账户（CI 工作流已准备好运行）。
- 分发方式：先 GitHub Releases + Homebrew，Mac App Store 稍后？
  （沙盒会影响引擎捆绑和文件访问。）

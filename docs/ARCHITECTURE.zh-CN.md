# SeekZip 架构

## 1. 形态

一个引擎核心，三个薄前端。所有归档逻辑都位于
`SeekZipCore`；前端从不自行调用 `7zz`、解析其输出或处理条目路径。

```
SeekZipApp (SwiftUI) ─┐
seekzip (CLI) ────────┼──► SeekZipCore ──► 7zz subprocess ──► archive files
seekzip-mcp (MCP) ────┘        │
                               └──► (phase 2) XADMaster fallback engine
```

## 2. 模块

| 模块 | 职责 |
|---|---|
| `SeekZipCore/ArchiveEntry.swift` | `ArchiveEntry`、`ArchiveInfo` 值模型（Codable——与 CLI 以 JSON 打印、MCP 返回的形状相同） |
| `SeekZipCore/ListingParser.swift` | 将 `7zz l -slt` 技术列表解析为模型 |
| `SeekZipCore/EntryPathSafety.swift` | Zip-slip / 绝对路径 / 符号链接策略，zip 炸弹（zip-bomb）启发式检测 |
| `SeekZipCore/SevenZipEngine.swift` | 子进程封装：列举、测试、（选择性）解压、创建 |
| `SeekZipCLI/main.swift` | 参数处理、人类可读/JSON 输出、退出代码映射 |
| `SeekZipMCP/main.swift` | MCP stdio JSON-RPC 服务器；工具 schema；委托给 Core |
| `SeekZipApp/SeekZipApp.swift` | SwiftUI 浏览器：打开、筛选、选择、解压 |

## 3. 数据流——列举归档

1. 前端向 Core 请求 `list(archive:password:)`。
2. `SevenZipEngine` 运行 `7zz l -slt -sccUTF-8 [-p…] <archive>`，
   **stdin 被设为 `/dev/null`**（密码提示必须快速失败，绝不能阻塞），
   并捕获 stdout。
3. `ListingParser` 在 `--` 行处切分头部，然后按每个条目读取一个
   `Key = Value` 块，只在*第一个* `" = "` 处切分
   （文件名中可能包含 `=` 和空格）。
4. 退出代码 2 且伴随密码/头部错误时，映射为 `EngineError
   .wrongPassword`——头部加密的归档意味着需要密码提示，
   而非文件损坏。完整的 7zz 约定见 `docs/REFERENCE.md` §3。
5. 前端渲染 `ArchiveInfo`。100 万条目的场景需要流式
   解析 + 虚拟化 UI（里程碑，见 TEST-MATRIX 的 PERF-04）；v0.1
   会将列表文本缓存在内存中，在约 10 万条目以内可以接受。

## 4. 数据流——解压

1. Core 先列举归档，并用 `EntryPathSafety.destinationURL` 校验**每一个**
   待解压条目：标准化后的目标路径必须仍位于用户选定的根目录内；绝对路径、
   `..` 穿越以及（默认情况下）符号链接均视为违规。
2. `ArchiveInfo.expansionRatio` 用于 zip 炸弹警告；GUI/CLI
   会在解压之前将其呈现给用户。
3. 只有在此之后，Core 才携带显式条目列表运行 `7zz x -y`。
   7zz 在磁盘之间流式传输字节；归档内容从不进入本进程的内存。
4. CLI 将安全性违规映射为退出代码 4，引擎失败映射为 3。

## 5. 引擎路由（第二阶段）

`SevenZipEngine` 是隐式 `ArchiveEngine` 约定的第一个实现。第二阶段将正式
确立该协议，并加入 XADMaster（`unar`/`lsar`）作为后备引擎：更好的文件名
编码恢复能力（Shift-JIS/GBK）和旧格式支持，并在 7zz 失败时提供第二意见。
按格式选择并自动后备——该模式记录于 `docs/REFERENCE.md` §1–2。libarchive
被推迟（不支持 7z/RAR 解密，也不支持多卷）。

## 6. 前端约定

**CLI 退出代码**（稳定，供脚本依赖）：`0` 成功 · `2` 用法错误 ·
`3` 引擎错误 · `4` 被安全策略阻止 · `5` 需要密码/密码错误。
`--json` 在 stdout 上恰好打印一份 JSON 文档；诊断信息输出到
stderr。

**MCP 工具**：`list_archive`、`test_archive`、`extract_entries`、
`create_archive`——schema 见 `SeekZipMCP/main.swift`。该服务器通过 stdio
使用以换行分隔的 JSON-RPC 2.0（MCP `2024-11-05`）。

## 7. 不变量（不可破坏）

1. **流式处理**：从不在 Core 中将归档字节（或解压出的完整文件）加载到
   内存。列表文本是唯一的大宗数据，且已计划改为流式解析。
2. **引擎之前先做安全检查**：任何解压路径在到达 `7zz` 之前，都必须经过
   `EntryPathSafety` 对完整条目集合的校验。
3. **无交互式子进程**：stdin 始终为 `/dev/null`；每条易触发提示的命令都
   带 `-y`，并在需要时带显式 `-p`。
4. **原子化结果**：操作先写入临时名称，成功后再重命名
   （v0.1 中解压目标除外；创建操作将在队列里程碑中采用这一做法）。
5. **净室（clean-room）**：可以从参考项目学习行为和公开约定；不得复制
   代码（MacPacker 采用 GPL-3.0）。

## 8. 决策记录

| 决策 | 原因 |
|---|---|
| 采用子进程 `7zz` 而非链接库 | 唯一支持创建/编辑/测试 + 头部加密 7z + RAR5 的引擎；进程隔离同时也是抵御恶意构造归档的安全边界 |
| CLI 放在 v1，MCP 作为 Core 之上的薄层 | CLI 是 CI/测试矩阵的运行面，也是稳定的约定；MCP 只增加 schema，不引入新逻辑 |
| 全部使用 SwiftPM 包 | 本地和 CI 中一条命令即可构建/测试；Xcode 项目随扩展/签名阶段再引入 |
| 通过 `-p` 参数传密码 | 7zz 唯一的非交互通道；已知取舍：在同一台机器的进程列表中可见（已记录的风险，见 REFERENCE.md §5） |

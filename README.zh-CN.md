# SeekZip

[English](README.md) | [Tiếng Việt](README.vi.md) | **简体中文**

**Find it inside. Extract only what you need.**

文档：[从零构建](docs/BUILD_FROM_ZERO.zh-CN.md) ·
[架构](docs/ARCHITECTURE.zh-CN.md) ·
[测试矩阵](docs/TEST-MATRIX.zh-CN.md) ·
[Agent 交接](docs/HANDOFF.zh-CN.md) ·
[参考研究](docs/REFERENCE.md)
（每份文档另有 Tiếng Việt 和简体中文版本，后缀分别为 `.vi.md` / `.zh-CN.md`）

一款免费的 macOS 原生归档管理器，专为 Apple Silicon 打造——在解压之前先浏览和
预览归档内容，只解压您选中的文件，并可创建或编辑归档。本项目在研究参考项目
之后（见 `docs/REFERENCE.md`）以 Swift/SwiftUI 净室（clean-room）方式构建；
未复制任何第三方应用代码。

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

## 构建（在 Mac 上）

```sh
swift build          # core + CLI + MCP（GUI 需要完整 Xcode，见 Package.swift）
swift test           # unit tests for parser and path safety
./Tests/Matrix/generate-matrix.sh   # build the edge-case fixture archives
```

RAR 归档可以解压但不能创建——RAR 的创建是专有技术
（所有 macOS 归档工具都是如此）。

## 许可证

MIT（计划中）。内置的 `7zz` 仍遵循 7-Zip 的 LGPL 许可证。

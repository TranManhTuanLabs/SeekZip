# 从零构建 SeekZip

读者对象：一位从未接触过本项目、手边有一台全新 Mac 的开发者（人类或 AI
Agent）。请从头到尾依次执行；每一步都可验证。

## 1. 前置条件

| 需要 | 版本 | 检查命令 |
|---|---|---|
| macOS | 14.6+，Apple Silicon (arm64) | `sw_vers`、`uname -m` → `arm64` |
| Xcode（或 Command Line Tools + Swift） | Swift 5.10+ | `swift --version` |
| Git | 任意较新版本 | `git --version` |
| 7-Zip 引擎 (`7zz`) | 最新稳定版 | 见第 3 步 |

Intel Mac 和 Linux 无法构建 GUI 目标。`SeekZipCore` 库是与平台无关的
Foundation 代码，但整个包以 macOS 为目标平台。

## 2. 获取源代码

```sh
git clone <this-repo> SeekZip
cd SeekZip
```

## 3. 安装引擎

SeekZip 以子进程方式驱动官方 `7zz` 二进制。开发期间，将其安装到系统中：

```sh
brew install sevenzip        # provides /opt/homebrew/bin/7zz
7zz                          # prints the 7-Zip banner
```

引擎解析顺序（见 `SevenZipEngine.init`）：显式路径 →
应用包 Resources 中的 `7zz` → `/opt/homebrew/bin`、`/usr/local/bin`、
`/usr/bin`。发布构建会捆绑来自 7-zip.org 的官方 macOS arm64 版 `7zz` 及其
`License.txt` (LGPL)——切勿从第三方镜像下载。

## 4. 构建

```sh
swift build                  # debug: core + seekzip CLI + seekzip-mcp + app
swift build -c release       # release binaries in .build/release/
```

## 5. 运行单元测试

```sh
swift test                   # listing parser + path-safety tests
```

预期：所有测试通过。这些测试不需要引擎二进制。

## 6. 对 CLI 进行冒烟测试

```sh
echo "hello" > /tmp/hello.txt
.build/debug/seekzip create /tmp/demo.zip /tmp/hello.txt
.build/debug/seekzip list --json /tmp/demo.zip
.build/debug/seekzip test /tmp/demo.zip
mkdir -p /tmp/out && .build/debug/seekzip extract /tmp/demo.zip /tmp/out
cat /tmp/out/tmp/hello.txt
```

## 7. 生成边缘情况测试夹具并运行矩阵冒烟测试

```sh
chmod +x Tests/Matrix/generate-matrix.sh
Tests/Matrix/generate-matrix.sh /tmp/fixtures
.build/debug/seekzip list /tmp/fixtures/solid.7z
.build/debug/seekzip list /tmp/fixtures/truncated.zip   # must fail cleanly, no crash
.build/debug/seekzip extract /tmp/fixtures/zip-slip.zip /tmp/out
echo $?                                                  # must be 4 (safety-blocked)
```

完整的用例清单见 `docs/TEST-MATRIX.zh-CN.md`。大型夹具
（10 GB+、100 万条目）在 CI 运行器上生成，从不提交到仓库。

## 8. 运行 GUI

```sh
swift run SeekZipApp
```

打开一个归档，筛选条目，选中一部分，然后解压它们。

## 9. 试用 MCP 服务器

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | .build/debug/seekzip-mcp
```

任何 MCP 客户端都可以通过 stdio 启动 `seekzip-mcp` 并使用同一套工具。

## 10. CI

`.github/workflows/ci.yml` 在每次推送时于 macOS 15 ARM 运行器上运行：
安装引擎 → `swift build` → `swift test` → 生成夹具 →
CLI 矩阵冒烟测试。CI 红灯会阻止合并。

## 11. 故障排查

| 症状 | 原因 / 修复方法 |
|---|---|
| `EngineError.binaryNotFound` | 未安装 `7zz`；重做第 3 步 |
| 列举加密归档时返回 "wrong password" | 对于未提供密码的头部加密归档，这是预期行为；传入 `-p`（CLI 标志，规划中）/ `password`（API、MCP） |
| 某条命令无限期挂起 | 按设计不应发生：引擎的 stdin 已被设为 `/dev/null`。若确实发生，请附上该归档提交 bug |
| `swift build` 在 Linux 上构建 app 目标时失败 | 预期行为——请在 macOS 上构建 |

## 12. 打包（路线图，尚未实现）

应用包（捆绑 `7zz` + 许可证）、Developer ID 签名、公证（notarisation）、
Finder 和 Quick Look 扩展、Homebrew cask。里程碑顺序见 `docs/HANDOFF.zh-CN.md`。

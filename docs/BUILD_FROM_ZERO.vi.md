# Build SeekZip từ con số 0

Đối tượng: một lập trình viên (người hoặc AI agent) với một máy Mac hoàn
toàn mới, chưa từng thấy dự án này. Làm theo từ trên xuống dưới; mỗi bước
đều có thể kiểm chứng được.

## 1. Điều kiện tiên quyết

| Cần có | Phiên bản | Cách kiểm tra |
|---|---|---|
| macOS | 14.6+ trên Apple Silicon (arm64) | `sw_vers`, `uname -m` → `arm64` |
| Xcode (hoặc Command Line Tools + Swift) | Swift 5.10+ | `swift --version` |
| Git | bản gần đây bất kỳ | `git --version` |
| Engine 7-Zip (`7zz`) | bản stable mới nhất | xem bước 3 |

Mac Intel và Linux không build được target GUI. Thư viện `SeekZipCore` là
code Foundation độc lập với nền tảng, nhưng toàn bộ package nhắm tới macOS.

## 2. Lấy source

```sh
git clone <this-repo> SeekZip
cd SeekZip
```

## 3. Cài engine

SeekZip điều khiển binary `7zz` chính thức dưới dạng subprocess. Để phát
triển, cài nó ở cấp hệ thống:

```sh
brew install sevenzip        # provides /opt/homebrew/bin/7zz
7zz                          # prints the 7-Zip banner
```

Thứ tự phân giải engine (xem `SevenZipEngine.init`): đường dẫn chỉ định rõ →
`7zz` trong Resources của app bundle → `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin`. Bản release đóng gói kèm `7zz` chính thức cho macOS arm64 từ
7-zip.org cùng với `License.txt` của nó (LGPL) — không bao giờ tải nó từ
các mirror của bên thứ ba.

## 4. Build

```sh
swift build                  # debug: core + seekzip CLI + seekzip-mcp + app
swift build -c release       # release binaries in .build/release/
```

## 5. Chạy unit test

```sh
swift test                   # listing parser + path-safety tests
```

Kỳ vọng: mọi test đều pass. Các test này không cần engine binary.

## 6. Kiểm thử nhanh CLI

```sh
echo "hello" > /tmp/hello.txt
.build/debug/seekzip create /tmp/demo.zip /tmp/hello.txt
.build/debug/seekzip list --json /tmp/demo.zip
.build/debug/seekzip test /tmp/demo.zip
mkdir -p /tmp/out && .build/debug/seekzip extract /tmp/demo.zip /tmp/out
cat /tmp/out/tmp/hello.txt
```

## 7. Tạo các fixture ca biên và chạy smoke test của ma trận

```sh
chmod +x Tests/Matrix/generate-matrix.sh
Tests/Matrix/generate-matrix.sh /tmp/fixtures
.build/debug/seekzip list /tmp/fixtures/solid.7z
.build/debug/seekzip list /tmp/fixtures/truncated.zip   # must fail cleanly, no crash
.build/debug/seekzip extract /tmp/fixtures/zip-slip.zip /tmp/out
echo $?                                                  # must be 4 (safety-blocked)
```

Danh sách ca kiểm thử đầy đủ nằm trong `docs/TEST-MATRIX.vi.md`. Các fixture
lớn (10 GB+, 1 triệu entry) được tạo trên CI runner, không bao giờ commit.

## 8. Chạy GUI

```sh
swift run SeekZipApp
```

Mở một archive, lọc entry, chọn một số entry, giải nén chúng.

## 9. Thử MCP server

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | .build/debug/seekzip-mcp
```

Bất kỳ MCP client nào cũng có thể spawn `seekzip-mcp` qua stdio với cùng
các tool đó.

## 10. CI

`.github/workflows/ci.yml` chạy trên runner macOS 15 ARM cho mỗi lần push:
cài engine → `swift build` → `swift test` → tạo fixture →
smoke test ma trận qua CLI. CI đỏ thì chặn merge.

## 11. Xử lý sự cố

| Triệu chứng | Nguyên nhân / cách khắc phục |
|---|---|
| `EngineError.binaryNotFound` | Chưa cài `7zz`; làm lại bước 3 |
| List của archive đã mã hoá trả về "wrong password" | Đây là hành vi đúng kỳ vọng với archive mã hoá header khi chưa có password; truyền `-p` (cờ CLI đang được lên kế hoạch) / `password` (API, MCP) |
| Một lệnh treo mãi mãi | Không được phép xảy ra: stdin của engine luôn là `/dev/null` theo thiết kế. Nếu vẫn xảy ra, hãy báo bug kèm archive đó |
| `swift build` fail ở target app trên Linux | Đúng kỳ vọng — hãy build trên macOS |

## 12. Đóng gói (lộ trình, chưa triển khai)

App bundle kèm `7zz` + giấy phép, ký Developer ID, notarisation, extension
cho Finder và Quick Look, Homebrew cask. Xem `docs/HANDOFF.vi.md` để biết
thứ tự các milestone.

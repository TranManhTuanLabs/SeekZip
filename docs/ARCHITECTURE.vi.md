# Kiến trúc SeekZip

## 1. Hình thái

Một engine core, ba frontend mỏng. Toàn bộ logic về archive nằm trong
`SeekZipCore`; các frontend không bao giờ tự gọi `7zz`, tự parse output của
nó, hay tự chạm vào đường dẫn của entry.

```
SeekZipApp (SwiftUI) ─┐
seekzip (CLI) ────────┼──► SeekZipCore ──► 7zz subprocess ──► archive files
seekzip-mcp (MCP) ────┘        │
                               └──► (phase 2) XADMaster fallback engine
```

## 2. Các module

| Module | Trách nhiệm |
|---|---|
| `SeekZipCore/ArchiveEntry.swift` | Các model giá trị `ArchiveEntry`, `ArchiveInfo` (Codable — cùng hình dạng mà CLI in ra dạng JSON và MCP trả về) |
| `SeekZipCore/ListingParser.swift` | Parse listing kỹ thuật `7zz l -slt` thành các model |
| `SeekZipCore/EntryPathSafety.swift` | Chính sách zip-slip / đường dẫn tuyệt đối / symlink, heuristic phát hiện zip-bomb |
| `SeekZipCore/SevenZipEngine.swift` | Wrapper subprocess: list, test, extract (chọn lọc), create |
| `SeekZipCLI/main.swift` | Xử lý tham số, output dạng người đọc / JSON, ánh xạ exit code |
| `SeekZipMCP/main.swift` | MCP server dạng JSON-RPC trên stdio; schema của các tool; uỷ thác cho Core |
| `SeekZipApp/SeekZipApp.swift` | Trình duyệt SwiftUI: mở, lọc, chọn, giải nén |

## 3. Luồng dữ liệu — liệt kê một archive

1. Frontend yêu cầu Core thực hiện `list(archive:password:)`.
2. `SevenZipEngine` chạy `7zz l -slt -sccUTF-8 [-p…] <archive>` với
   **stdin được đặt là `/dev/null`** (một lời nhắc nhập password phải fail
   nhanh, không bao giờ được chặn tiến trình) và thu stdout.
3. `ListingParser` tách phần header tại dòng `--`, sau đó đọc mỗi khối
   `Key = Value` cho một entry, chỉ tách tại `" = "` *đầu tiên* (tên file có
   thể chứa `=` và dấu cách).
4. Exit code 2 kèm lỗi password/headers được ánh xạ thành `EngineError
   .wrongPassword` — archive mã hoá header là trường hợp cần hỏi password,
   không phải file hỏng. Xem `docs/REFERENCE.md` §3 để biết toàn bộ hợp đồng
   của 7zz.
5. Các frontend hiển thị `ArchiveInfo`. Từ M2 listing được parse dạng
   stream (`StreamingListingParser` + `SevenZipEngine.listStreaming`);
   trường hợp 1 triệu entry vẫn cần UI ảo hoá (M3+, xem TEST-MATRIX
   PERF-04).

## 4. Luồng dữ liệu — giải nén

1. Core liệt kê archive trước và kiểm tra **mọi** entry sắp giải nén bằng
   `EntryPathSafety.destinationURL`: đích đến sau khi chuẩn hoá phải vẫn
   nằm bên trong thư mục gốc do người dùng chọn; đường dẫn tuyệt đối, duyệt
   thư mục bằng `..` và (theo mặc định) symlink đều là vi phạm.
2. `ArchiveInfo.expansionRatio` cung cấp dữ liệu cho cảnh báo zip-bomb;
   GUI/CLI hiển thị cảnh báo này trước khi giải nén.
3. Chỉ sau đó Core mới chạy `7zz x -y` với danh sách entry tường minh.
   7zz stream byte trực tiếp từ đĩa tới đĩa; nội dung archive không bao giờ
   đi vào bộ nhớ của tiến trình này.
4. CLI ánh xạ vi phạm an toàn thành exit code 4, lỗi engine thành 3.

## 5. Định tuyến engine (phase 2)

`SevenZipEngine` là bản triển khai đầu tiên của một hợp đồng `ArchiveEngine`
ngầm định. Phase 2 sẽ chính thức hoá protocol này và bổ sung XADMaster
(`unar`/`lsar`) làm engine dự phòng: khôi phục encoding tên file tốt hơn
(Shift-JIS/GBK) và hỗ trợ các format cũ, đồng thời cho ý kiến thứ hai ở
những nơi 7zz thất bại. Việc lựa chọn theo từng format kèm fallback tự
động — là mẫu hình được ghi trong `docs/REFERENCE.md` §1–2. libarchive bị
hoãn lại (không giải mã được 7z/RAR, không hỗ trợ multi-volume).

## 6. Hợp đồng của các frontend

**Exit code của CLI** (ổn định, để script dựa vào): `0` ok · `2` usage ·
`3` engine error · `4` safety-blocked · `5` password required/wrong.
`--json` in đúng một tài liệu JSON lên stdout; thông tin chẩn đoán đi vào
stderr.

**Các tool MCP**: `list_archive`, `test_archive`, `extract_entries`,
`create_archive` — schema nằm trong `SeekZipMCP/main.swift`. Server nói
JSON-RPC 2.0 phân tách bằng ký tự xuống dòng trên stdio (MCP `2024-11-05`).

## 7. Các bất biến (không được phá vỡ)

1. **Streaming**: không bao giờ nạp byte của archive (hay toàn bộ file đã
   giải nén) vào bộ nhớ trong Core. Output của listing được đọc tăng dần
   từ pipe của `7zz` và parse ngay khi tới (M2); chỉ giữ lại 4 KB cuối,
   để báo lỗi.
2. **An toàn trước engine**: không đường giải nén nào được chạm tới `7zz`
   mà chưa qua kiểm tra `EntryPathSafety` trên toàn bộ tập entry.
3. **Không subprocess tương tác**: stdin luôn là `/dev/null`; mọi lệnh có
   nguy cơ hiện lời nhắc đều mang `-y` và `-p` tường minh khi cần.
4. **Kết quả nguyên tử (atomic)**: các thao tác ghi vào tên tạm và đổi tên
   khi thành công (đích giải nén là ngoại lệ trong v0.1; thao tác tạo
   archive sẽ áp dụng điều này cùng milestone hàng đợi).
5. **Clean-room**: có thể học hành vi và các hợp đồng công khai từ các dự
   án tham khảo; không được sao chép code (MacPacker là GPL-3.0).

## 8. Nhật ký quyết định

| Quyết định | Lý do |
|---|---|
| Dùng `7zz` dạng subprocess thay vì liên kết thư viện | Engine duy nhất có create/edit/test + 7z mã hoá header + RAR5; cách ly tiến trình cũng là một biên an toàn chống archive được chế tạo ác ý |
| CLI trong v1, MCP là lớp mỏng trên Core | CLI là bề mặt cho CI/ma trận kiểm thử và là hợp đồng ổn định; MCP bổ sung schema, không thêm logic mới |
| Một SwiftPM package cho mọi thứ | Build/test bằng một lệnh duy nhất ở local và trong CI; Xcode project sẽ đến cùng extension/ký |
| Password qua tham số `-p` | Kênh không tương tác duy nhất của 7zz; đánh đổi đã biết: hiển thị trong danh sách tiến trình trên cùng máy (rủi ro đã ghi nhận, REFERENCE.md §5) |

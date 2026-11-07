# SeekZip — Bàn giao cho Agent

Hãy đọc file này trước nếu bạn là một AI agent (hoặc người mới) tiếp nhận
dự án này từ con số 0 về ngữ cảnh. Nó cho bạn biết mọi thứ đang ở đâu, cách
tiếp tục, và những gì không được phá vỡ. Hãy cập nhật file này mỗi khi
trạng thái thay đổi đáng kể — ngữ cảnh của agent tiếp theo bắt đầu từ đây.

## 1. Ảnh chụp nhanh về dự án

- **Là gì**: SeekZip — ứng dụng quản lý archive native cho macOS (14.6+,
  Apple Silicon), miễn phí: duyệt/xem trước trước khi giải nén, giải nén
  chọn lọc, tạo/sửa ZIP & 7z. Tagline: "Find it inside. Extract only what
  you need."
- **Vì sao tồn tại**: Keka không xem trước được bên trong archive;
  BetterZip thu phí; MacPacker (GPL-3.0) là baseline native nhưng vẫn
  thiếu kiểm tra tính toàn vẹn/khôi phục. SeekZip là một bản build
  **clean-room**: có thể nghiên cứu tính năng và các hợp đồng công khai,
  nhưng không bao giờ được sao chép code.
- **Yêu cầu cứng của chủ dự án**: mạnh mẽ với file rất lớn (streaming,
  Zip64, archive tầm 50 GB, 1 triệu entry); toàn bộ ma trận kiểm thử trong
  `docs/TEST-MATRIX.vi.md` phải pass; phải nêu các deal-breaker *trước* khi
  làm việc dài hơi.

## 2. Trạng thái hiện tại (hãy cập nhật mục này!)

- Khung v0.1 đã commit ngày 2026-11-07: Core (model, parser `-slt`, an
  toàn đường dẫn, wrapper cho engine 7zz), CLI, MCP server, khung trình
  duyệt SwiftUI, unit test, trình tạo fixture, workflow CI macOS 15 ARM.
- **M1 đã xanh (2026-11-07)**: CI run 42300451189 — build, unit test,
  fixture, smoke test ma trận đều pass trên macos-15. `Package.swift`
  loại target GUI SwiftUI (cần Xcode đầy đủ; máy Mac chỉ có Command Line
  Tools); code GUI vẫn nằm trong `Sources/SeekZipApp/` để chờ Xcode
  project ở M7. `swift test` không chạy được local trên máy chỉ có CLT
  (không có XCTest) — test chạy trên CI.
- **M2 đã xong**: listing stream — `StreamingListingParser` (tăng dần, an
  toàn khi chunk cắt giữa dòng/ký tự UTF-8), `SevenZipEngine.listStreaming`
  (tiến độ + hủy qua `EngineError.cancelled`, POSIX `read()` trên pipe),
  CLI `list --stream` (JSON lines). 14 unit test pass, gồm test stream
  100k entry và test hủy bằng binary giả lập. Chưa chạy fixture 10 GB /
  1M entry đầy đủ (PERF-01/04) trên CI — fixture nặng, sẽ thêm sau nếu có
  thời gian CI cho phép.
- **M3 đã xong**: xem trước + archive lồng nhau — `PreviewProvider`
  (text stream vào qua `7zz e -so`, giới hạn 64 KB / 200 dòng, an toàn
  UTF-8, phát hiện binary bằng byte NUL; ảnh/PDF/file nhị phân giao cho
  Quick Look), `SevenZipEngine.listNested` / `withNestedArchive` (giải
  nén vào thư mục tạm qua `EntryPathSafety`, chuỗi 3 cấp NES-01), CLI
  `preview` và `list outer.zip inner.zip` (xem trước entry lồng nhau dạng
  `preview outer.zip "inner.zip!/file.txt"`). 30 unit test pass (16 test
  mới, dùng binary giả lập). Panel xem trước + điều hướng lồng nhau của
  GUI đã nối code trong `Sources/SeekZipApp/` nhưng CHƯA biên dịch bằng
  SwiftPM/CI (cần Xcode đầy đủ); panel Quick Look native (QLPreviewPanel)
  sẽ làm cùng Xcode project ở M7.
- Các quyết định về engine đã chốt: 7zz là engine chính, XADMaster làm
  dự phòng trong phase 2, libarchive hoãn lại — lý do nằm trong
  `docs/REFERENCE.md`.

## 3. Quy trình tiếp tục công việc (cho mọi agent, theo thứ tự)

1. Đọc `README.vi.md`, `SPEC.md`, `docs/ARCHITECTURE.vi.md`, file này, và
   `docs/TEST-MATRIX.vi.md`. Đọc lướt `docs/REFERENCE.md` trước khi chạm
   vào engine hay parser.
2. `git log --oneline -5` và `git status` — nắm trạng thái đã kiểm chứng
   gần nhất.
3. Tái tạo baseline: `swift build && swift test`, rồi smoke test CLI từ
   BUILD_FROM_ZERO §6–7. Không bắt đầu việc mới trên một baseline đang đỏ
   mà không nói rõ điều đó.
4. Chọn milestone chưa xong cao nhất (§5), làm việc theo các commit nhỏ.
5. Trước khi tuyên bố hoàn thành: build + unit test + các ca trong ma trận
   bị ảnh hưởng phải pass; cập nhật §2 của file này và bộ tài liệu ba ngôn
   ngữ (§6).

## 4. Thỏa thuận làm việc

- Commit nhỏ, mô tả rõ; subject dạng mệnh lệnh; phần body giải thích *vì
  sao*.
- Không code GPL (MacPacker) — chỉ học ở mức hành vi. Ý tưởng tính năng
  của PeaZip thì được; code của nó là Pascal LGPL và không được dùng.
- Không bao giờ commit fixture đã tạo hay binary lớn; fixture được tạo bởi
  `Tests/Matrix/generate-matrix.sh`.
- Binary `7zz` chỉ được đóng gói ở thời điểm packaging, lấy từ 7-zip.org,
  kèm `License.txt` của nó.
- Giữ các bất biến trong ARCHITECTURE §7. Nếu buộc phải thay đổi một bất
  biến, hãy sửa tài liệu trong cùng commit và nói rõ lý do.

## 5. Các milestone (theo thứ tự)

1. **M1 — Biên dịch & CI xanh**: build trên macOS lần đầu, sửa lỗi, CI pass
   khi push.
2. **M2 — Listing dạng streaming**: parser `-slt` tăng dần + tiến độ +
   huỷ bỏ; PERF-01…04 pass.
3. **M3 — Xem trước**: tích hợp Quick Look (phím Space), archive lồng nhau
   trong trình duyệt.
4. **M4 — Hàng đợi**: job theo lô, tạm dừng/tiếp tục, tên tạm + đổi tên
   nguyên tử cho thao tác tạo, kiểm tra dung lượng trống trước.
5. **M5 — Hoàn thiện tạo/sửa**: thêm/xoá/đổi tên entry, chuyển đổi định
   dạng, UI checksum, password trong Keychain.
6. **M6 — Engine dự phòng XAD** phía sau protocol định tuyến.
7. **M7 — Extension & đóng gói**: extension cho Finder + Quick Look, đóng
   gói 7zz đã ký, bản release đã notarise, Homebrew cask.

## 6. Quy tắc tài liệu ba ngôn ngữ

`README.md` và `docs/BUILD_FROM_ZERO.md`, `docs/ARCHITECTURE.md`,
`docs/HANDOFF.md`, `docs/TEST-MATRIX.md` tồn tại ở ba phiên bản có nội dung
giống hệt nhau: tiếng Anh (không hậu tố), tiếng Việt (`.vi.md`), tiếng
Trung giản thể (`.zh-CN.md`). **Khi bạn sửa một ngôn ngữ, hãy cập nhật hai
ngôn ngữ còn lại trong cùng commit** — hoặc, nếu không thể, thêm ghi chú
`> ⚠️ Translation may be stale` vào các file đã lỗi thời và nêu rõ trong
§2. Tiếng Anh là nguồn chân lý khi các phiên bản không khớp nhau.

## 7. Hạn chế đã biết (v0.1)

- Listing stream từ `7zz` từ M2 (v0.1 còn đệm trong bộ nhớ).
- CLI chưa có cờ `-p`; password hoạt động qua Core API và MCP.
- Giải nén chưa kiểm tra dung lượng trống trước và chưa dùng tên tạm.
- GUI là khung xương: panel xem trước + điều hướng lồng nhau đã nối code
  (M3) nhưng chưa biên dịch cho tới Xcode project ở M7; chưa có tab, hàng
  đợi hay kéo-thả ra ngoài.
- Password truyền cho `7zz` qua `-p` hiển thị trong danh sách tiến trình
  của máy local (rủi ro đã chấp nhận và ghi nhận).

## 8. Câu hỏi mở cho chủ dự án

- Vị trí/tài khoản GitHub repo cho CI (workflow CI đã sẵn sàng chạy).
- Phân phối: GitHub Releases + Homebrew trước, Mac App Store sau?
  (Sandboxing ảnh hưởng tới việc đóng gói engine và truy cập file.)

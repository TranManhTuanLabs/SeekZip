# AGENTS.md — SeekZip

> Quy tắc làm việc cho AI (Muse) trong repo này. Đọc trước khi làm việc.

## 1. Quy tắc làm việc — ngắn thì làm luôn, dài thì trình khung trước

- **Ngắn, hiểu rõ thì làm luôn.**
- **Đoạn nào dài, chưa rõ, việc nhiều thì hỏi lại:** (1) trình khung cho anh duyệt trước khi làm; (2) xong rồi thì tóm tắt những gì đã làm.
- (Manh 18/11/2026, áp dụng mọi repo.)

## 2. Mục tiêu dự án

- SeekZip = công cụ nén/giải nén cho macOS, **mạnh ngang 7-Zip/WinRAR**, miễn phí, native Apple Silicon.
- Deal-breaker lớn nhất: **không tạo được RAR** (7-Zip/WinRAR tạo được).
- Main GIỮ giao diện tối giản, chỉ sắp xếp lại topbar (Extract là primary duy nhất, còn lại gom vào menu More). Bản redesign đầy đủ sang NHÁNH RIÊNG (dự kiến Premium, chưa chốt free hay không).

## 3. Kiến trúc

- Code phải **dễ bảo trì, dễ nâng cấp, linh động** — sửa 1 chỗ không vỡ chỗ khác; thêm tính năng mới không phải viết lại code cũ.
- **1 tính năng = 1 module/thư mục riêng**; dùng chung hàm/component, không copy-paste 2 bản.
- Xem quyết định kiến trúc trong `docs/ARCHITECTURE.md` §5.

## 4. Commit và CI

- Gộp các file liên quan thành **1 commit** rồi đẩy; không đẩy từng file qua trình duyệt.
- Chỉ cho `[build-app]` vào commit message khi Manh nói rõ "build-app" — Muse không tự quyết.
- Docs-only (docs/**, *.md) thì CI không chạy; sửa docs thì đẩy ngay cùng đợt (commit docs-only).
- CI đang chờ/chưa chạy thì sửa xong đẩy luôn cho gộp vào run mới nhất; run cũ bị push mới đè lên mà huỷ (concurrency cancel) là bình thường, không cần báo.
- Run bị huỷ mà KHÔNG có run mới đè lên thì HỎI Manh trước khi đoán nguyên nhân hay re-run.
- Sau mỗi lần đẩy, tự theo dõi run CI mới nhất tới khi xong, rồi báo: xanh (kèm link tải) hoặc đỏ thật.

## 5. Docs

- Mỗi thay đổi code/quyết định phải ghi vào docs trong repo ngay cùng đợt — docs là nguồn để AI sau vào đọc là biết trạng thái dự án.
- Research báo cáo được để tiếng Việt; docs chính thống khác duy trì tiếng Anh là chính. Chỉ README.md giữ 3 ngôn ngữ (EN/VI/ZH).
- Đuôi file docs chuẩn `.md` chữ thường.

## 6. Quy tắc chung

- **KHÔNG hardcode** — mọi thứ không nên fix cứng trừ khi thật sự cần; phải có tính mở rộng hoặc tự nhận diện.
- GitHub App/connector **không sửa được `.github/workflows/*` (403)**. Workflow sửa từ Mac rồi push, hoặc qua trình duyệt khi Manh cho quyền.
- GitHub web: mặc định giả vờ như **chưa đăng nhập**; chỉ khi Manh nói rõ cho quyền thì mới đăng nhập web và thao tác.
- **Khi ghi việc nợ phiên, ghi rõ session/chat nào và repo nào** (vd "mac — SeekZip"), tránh chat khác áp nhầm sang repo sai.
- Manh viết sai chính tả thì **tự correct cho đúng** khi đưa vào app/docs; để ý cả chữ hoa/thường.
- Manh dùng từ kỹ thuật / tiếng Anh sai thì **báo hoặc sửa cho đúng ngay lúc đó**.
- Quyết định sản phẩm phải hỏi Manh trước, trừ khi anh liệt kê phương án và bảo Muse chọn.
- Trước khi tự chế một tính năng mà native không có, **báo Manh 1 câu trước** (native không có, muốn làm phải tự chế, anh có đồng ý không) rồi mới làm.
- Trước khi sửa UI, **lên khung layout trước, Manh duyệt khung đó**, rồi mới sửa dần theo khung.

## 7. Về Manh

- Manh **không phải dân IT gốc, đang học, làm theo kiểu vibecode**. Giải thích bằng tiếng Việt đơn giản, ví dụ từ chính dự án, không dạy dồn dập.
- Anh quyết nhanh, thích gộp 2–3 sửa vào 1 lần chạy CI rồi test 1 lượt.

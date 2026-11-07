# Ma trận kiểm thử của SeekZip

Mọi ca kiểm thử đều chạy headless qua CLI `seekzip` trong CI (runner macOS
ARM) và phải pass trước một bản release. Fixture được tạo bởi
`Tests/Matrix/generate-matrix.sh`; các fixture lớn được tạo trên runner,
không bao giờ commit.

## Định dạng (FMT)
- FMT-01 ZIP store/deflate/bzip2/lzma (zipx) — list, preview, extract, test
- FMT-02 7z solid và non-solid, LZMA2 đa luồng
- FMT-03 RAR4 và RAR5 (chỉ giải nén), gồm cả recovery record
- FMT-04 tar, tar.gz, tar.bz2, tar.xz, tar.zst, tar.lz4
- FMT-05 ISO, DMG, CAB, WIM, ARJ, LZH, MSI, DEB, RPM, XAR
- FMT-06 Stub tự giải nén và archive có rác được chèn ở đầu (prepended junk)

## File lớn & hiệu năng (PERF)
- PERF-01 Archive 10 GB: list < 5 s, RSS đỉnh < 300 MB
- PERF-02 Một entry đơn 10 GB (biến thể sparse + dữ liệu thật)
- PERF-03 Zip64: archive tổng > 4 GB, entry > 4 GB, offset > 4 GB
- PERF-04 1.000.000 entry: listing dạng streaming, UI vẫn phản hồi,
  bộ lọc trả kết quả tăng dần
- PERF-05 Tạo 7z 20 GB với `-mmt=on`: mọi nhân CPU đều bận, huỷ ở 50%
  không để lại file cuối viết dở (tên tạm được dọn sạch hoặc đánh dấu rõ)
- PERF-06 Tạm dừng/tiếp tục hàng đợi xuyên qua lần khởi chạy lại ứng dụng

## Mã hoá (ENC)
- ENC-01 ZIP ZipCrypto kiểu cũ (mở bằng password đúng)
- ENC-02 ZIP AES-256; 7z AES-256 với header được mã hoá (`-mhe=on`)
- ENC-03 Password sai: lỗi sạch sẽ, không giải nén một phần, exit code 5
- ENC-04 Password unicode (dấu tiếng Việt, emoji)
- ENC-05 Password từ Keychain; password đã lưu bị sai thì quay lại hỏi

## File chia tập (SPL)
- SPL-01 ZIP split (.z01…), 7z volume (.7z.001…), RAR part (part1.rar…)
- SPL-02 Thiếu tập ở giữa: lỗi chính xác, nêu tên phần bị thiếu
- SPL-03 Các tập nằm ở thư mục khác nhau thì hỏi vị trí của tập tiếp theo

## Hư hỏng (COR)
- COR-01 Archive bị cắt cụt (50%, 99%): lỗi header, không crash
- COR-02 Dữ liệu entry bị lật bit: báo lỗi CRC theo từng entry; các entry
  khác vẫn giải nén được
- COR-03 Central directory bị hỏng; chế độ cứu hộ (salvage) giải nén những
  gì còn đọc được
- COR-04 Không phải archive (byte ngẫu nhiên, file rỗng, thư mục làm đầu vào)

## Lồng nhau & cấu trúc (NES)
- NES-01 Archive trong archive trong archive (3 cấp) mở ngay tại chỗ
- NES-02 Archive rỗng; archive chỉ chứa thư mục rỗng
- NES-03 Tên entry trùng nhau; các entry chỉ khác nhau ở hoa/thường trên APFS
- NES-04 Đường dẫn rất sâu (> 1024 ký tự) và thành phần tên file 255 ký tự

## Xem trước (PRV)
- PRV-01 Xem trước text: 200 dòng đầu / 64 KB, an toàn UTF-8, có ghi chú khi bị cắt
- PRV-02 Entry ảnh, PDF và nhị phân: không đọc nội dung, kết luận dùng Quick Look
- PRV-03 Entry mã hoá mà không có password: kết luận "cần password" rõ ràng
- PRV-04 Entry trong archive lồng 2 cấp xem trước được (qua `listNested`)
- PRV-05 Xem trước entry lớn không bao giờ giải nén toàn bộ (stream dừng ở giới hạn)

## Tên file & encoding (NAM)
- NAM-01 Tên UTF-8 có dấu tiếng Việt và emoji
- NAM-02 ZIP Shift-JIS (CP932) từ Windows Nhật; ZIP GBK; ZIP CP1252 —
  encoding được phát hiện tự động hoặc chọn tay được, không bị mojibake
- NAM-03 Tên chứa `=`, khoảng trắng ở đầu/cuối, `..` bên trong một tên
- NAM-04 Đặc thù macOS: `__MACOSX`, `.DS_Store`, resource fork, xattr

## An toàn (SEC)
- SEC-01 Zip-slip: các entry `../` và đường dẫn tuyệt đối bị chặn (exit 4)
- SEC-02 Entry symlink/hardlink trỏ ra ngoài đích đến bị chặn
- SEC-03 Zip bomb (lồng nhau kiểu 42.zip + tỉ lệ phẳng 1000:1): hiển thị
  cảnh báo, giải nén đòi xác nhận tường minh
- SEC-04 Đĩa đầy giữa chừng khi giải nén: fail sạch sẽ, xoá các file một
  phần, archive nguồn không bị đụng vào
- SEC-05 Đích đến chỉ-đọc hoặc bị gỡ giữa thao tác (rút USB)

## Kiểm chứng chéo (XCHK)
- XCHK-01 Mọi fixture cũng được liệt kê/kiểm thử bằng 7-Zip chính thức và
  bsdtar; danh sách entry và CRC phải khớp nhau
- XCHK-02 Archive do SeekZip tạo mở được trong 7-Zip, WinRAR, Keka, The
  Unarchiver và macOS Archive Utility mà không có cảnh báo

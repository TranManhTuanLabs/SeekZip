> **Lưu ý khi đưa lên repo (17/11/2026):** hướng redesign đầy đủ trong báo cáo này đã được Manh đổi ngày 13/11/2026 — main giữ giao diện tối giản (chỉ sắp xếp lại topbar, nút Extract thuần làm primary duy nhất), bản redesign đầy đủ chuyển sang nhánh riêng (dự kiến Premium, có thể cho free). Đừng dùng lộ trình phase trong báo cáo này làm kế hoạch triển khai cho main. Phần còn lại của báo cáo giữ nguyên như bản nghiên cứu ngày 11/11/2026.

# SeekZip — Đề xuất redesign UI/UX theo phong cách Apple

> **Ngôn ngữ:** tiếng Việt (theo yêu cầu).
> **Đối tượng:** SeekZip — trình quản lý archive native macOS 14.6+, Apple Silicon, Swift/SwiftUI, miễn phí, engine 7-Zip chính thức (7zz 26.05) chạy subprocess. Tính năng hiện có: duyệt & preview archive trước khi giải nén, giải nén chọn lọc, tạo/sửa ZIP và 7z, menu chuột phải Finder (8 mục), Quick Look extension, CLI và MCP server. 108 unit tests green.
> **UI hiện tại:** một `List` duy nhất, toolbar (open / extract / create), queue panel ở dưới cùng, password sheet, Settings 3 tab (Engines / Finder / About). Không sidebar, không column view, không icon/grid view, không tab/dual-pane, không inspector/preview pane. Cửa sổ cố định ~900×600.
> **Hướng thiết kế của user:** phong cách Apple — tinh tế, lịch sự. Cái đẹp là yêu cầu cứng, ngang với chức năng. Giữ native SwiftUI trên macOS 14.6+ (không Electron, không UI cross-platform).
> **Ngày nghiên cứu:** 11/11/2026. Trạng thái xác minh: trang chính thức BetterZip và MacPacker đã đọc trực tiếp (`verified live`); các trang HIG của Apple là SPA render bằng JS nên `browser_open` trực tiếp thất bại — nội dung HIG dưới đây lấy từ bản trích DocC JSON của Apple do các mirror công khai trích lại (ghi rõ ở từng mục, coi là `index`, không phải đọc trực tiếp trang Apple); các đối thủ còn lại và tài liệu SwiftUI là `index` (kết quả tìm kiếm, chưa chạy app thật).

## Summary — Kết luận trước, chi tiết sau

**Layout khuyên dùng (mặc định): `NavigationSplitView` 2 cột + `.inspector` ở cạnh phải — không phải 3 cột, không phải dual-pane kiểu Windows.**

```
┌──────────────────────────────────────────────────────────────────┐
│ Toolbar thống nhất: [sidebar] [‹ ›]  Tên-archive   [view 1|2|3] [🔍] [Extract*] [•••] [inspector] │
├──────────┬──────────────────────────────────────┬────────────────┤
│ SIDEBAR  │ Breadcrumb: archive.zip › folder ›   │ INSPECTOR      │
│ (sidebar │ ┌──────────────────────────────────┐ │ (trailing)     │
│  material)│ │ TABLE — Tên | Kích thước |       │ │ • Thumbnail/   │
│ Đang mở  │ │ Ngày sửa | Loại | Đã nén | 🔒   │ │   preview      │
│ Gần đây  │ │ (click header để sort, disclosure│ │ • Metadata     │
│ Yêu thích│ │  cho folder — outline trong Table)│ │   archive &    │
│ ──────── │ └──────────────────────────────────┘ │   selection    │
│ Tạo mới… │ Status bar: 128 mục • 1,2 GB • đã   │ • Queue/Jobs   │
│          │ chọn 3 mục (45 MB) • tiến trình…    │   (gọn, hủy đc)│
└──────────┴──────────────────────────────────────┴────────────────┘
```

**Vì sao là 2 cột + inspector, không phải 3 cột:** sidebar của SeekZip không có đủ "tầng" để lấp đầy 3 cột một cách có ý nghĩa (xem §5.1 — trade-off). Cột giữa thứ 3 trong Finder/Mail là danh sách các *đối tượng* (mail, note); ở SeekZip, cây thư mục đã nằm trong chính Table (dạng outline), thêm một cột cây nữa là trùng lặp và ăn mất chiều ngang của Table — nơi cần nhất để đọc tên file dài, kích thước, tỉ lệ nén. Inspector (macOS 14+, `.inspector(isPresented:)`) là nơi đúng chỗ cho metadata + preview + queue, có thể đóng/mở, không chiếm chỗ vĩnh viễn.

**3 quyết định thẩm mỹ quan trọng nhất:**
1. **Đừng tự vẽ chrome.** Dùng đúng component hệ thống (`NavigationSplitView`, `.listStyle(.sidebar)`, `Table`, `.inspector`, `.toolbar`, `.searchable`) — vẻ "Apple" đến từ cấu trúc chuẩn + material hệ thống, không phải từ màu nền/bo góc tự chế. HIG Liquid Glass nói rõ: giảm custom background/tint trên toolbar, để content quyết định màu toolbar.
2. **Thiết kế cho Sonoma/Sequoia trước, Tahoe là "được tặng thêm".** Deployment target là macOS 14.6+, nên Liquid Glass (macOS 26) **không được** làm nền tảng thiết kế. Nếu build bằng SDK macOS 26, toolbar/sidebar/inspector chuẩn sẽ tự nhận Liquid Glass; tuyệt đối không tự gắn `.glassEffect` lên chrome chuẩn, không yêu cầu macOS 26.
3. **Một hành động chính duy nhất, nổi bật duy nhất:** nút **Extract** (`.buttonStyle(.borderedProminent)` / toolbar `.primaryAction`, tint = accent hệ thống). Mọi thứ khác là icon SF Symbols đơn sắc, không viền. Đây là điểm khác biệt lớn nhất với 7-Zip/WinRAR (toolbar dày đặc nút có viền, icon màu mè).

**Phase 1 (win lớn nhất, làm trước):** cửa sổ resizable (mặc định ~1100×700, min ~900×560, nhớ kích thước/vị trí), `NavigationSplitView` 2 cột + sidebar (Đang mở / Gần đây / Yêu thích), `Table` thay cho `List` (sort, resize cột, zebra macOS 14), breadcrumb + back/forward, thanh status bar, inspector metadata, toolbar chuẩn có thể customize, tìm kiếm/lọc trong archive, empty state + trạng thái loading/progress không chặn cửa sổ, queue chuyển từ panel dưới cùng vào inspector/status bar. Chỉ riêng phase này đã biến app từ "một cái list" thành "một app Mac".

---

## 1. Apple HIG (macOS, 2024–2026): Apple coi thế nào là "gu" tốt

> Lưu ý xác minh: các trang HIG là SPA — `browser_open` tới `https://developer.apple.com/design/human-interface-guidelines/sidebars` trả về "no extractable content". Nội dung dưới đây được đối chiếu từ bản trích DocC JSON chính thức của Apple (`https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<slug>.json`) qua các mirror công khai có ghi `source_url` trỏ về Apple, đọc ngày 11/11/2026. Những con số nào chỉ xuất hiện ở nguồn thứ cấp (không phải trích HIG) sẽ ghi rõ "quy ước cộng đồng, không phải spec Apple".

### 1.1 Cấu trúc cửa sổ: sidebar — content — inspector

- **Sidebar nằm ở cạnh leading (trái), dùng để điều hướng giữa các khu vực top-level hoặc các collection** (folder, playlist, mailbox) — HIG "Sidebars", https://developer.apple.com/design/human-interface-guidelines/sidebars . Nó "đòi hỏi nhiều không gian dọc và ngang"; khi không gian hạn chế thì dùng control gọn hơn. Trên macOS, chiều cao dòng / cỡ chữ / cỡ glyph của sidebar phụ thuộc vào cỡ sidebar (small/medium/large) do người dùng chọn trong System Settings › General — thiết kế phải chịu được cả 3 cỡ, đừng fix cứng chiều cao dòng.
- **Phải có cách ẩn/hiện sidebar:** nút show/hide trên toolbar hoặc lệnh Show/Hide Sidebar trong menu View. **Tránh đặt thông tin/hành động quan trọng ở đáy sidebar** (cửa sổ thường bị đặt sao cho đáy khuất khỏi màn hình).
- **Split view:** HIG "Split views", https://developer.apple.com/design/human-interface-guidelines/split-views — split view quản lý nhiều pane kề nhau, thường thể hiện nhiều tầng hierarchy cùng lúc; **giữ highlight selection ở mỗi pane dẫn tới detail view** (người dùng luôn biết mình đang ở đâu); cân nhắc drag-and-drop giữa các pane.
- **Inspector nằm ở cạnh trailing (phải),** hiển thị thông tin/cài đặt của selection hiện tại, cập nhật trực tiếp, **không có nút Apply** (quy ước cộng đồng tổng hợp từ HIG, nguồn: https://github.com/apupsis/saglitzdesign-mcp/blob/HEAD/knowledge/design-languages/macos-app-design.md ).
- **Column view (browser):** chỉ có trên macOS, control AppKit là `NSBrowser`; mỗi cột = một tầng hierarchy; chọn folder thì cột kế bên hiện con của nó; dùng khi hierarchy sâu và người dùng đi lại giữa các tầng thường xuyên, **và không cần sort theo cột** (muốn sort thì dùng table). HIG "Column views", https://developer.apple.com/design/human-interface-guidelines/column-views . Đây là cơ sở cho quyết định column view là phase sau, bằng AppKit bridging (§4.3).

### 1.2 Toolbar

- Toolbar trên macOS nằm trong window frame, hợp nhất với title bar; **toolbar item không có bezel/viền**; tối đa 3 nhóm (leading: điều hướng + sidebar toggle + tiêu đề; giữa: control chung; trailing: primary action, inspector toggle, search, menu More). Hệ thống tự thêm overflow menu khi không vừa — **đừng tự làm overflow menu**.
- **Mọi toolbar item đều phải có mặt dưới dạng lệnh trong menu bar** (vì toolbar có thể bị người dùng gỡ/customize, và vì Full Keyboard Access). Đây là quy tắc HIG được nhiều nguồn trích lại nhất — và là lỗi phổ biến của app bên thứ ba.
- **Ưu tiên SF Symbols không viền, không dùng symbol có vòng tròn bao quanh** (toolbar đã có container, hệ thống tự lo hover/selection). Dùng text thay cho symbol khi động từ ngắn diễn đạt rõ hơn (vd. "Edit"). Chỉ một action chính được `.prominent`.
- **Đừng đặt tên cửa sổ bằng tên app.** Title đặt tên cho *nội dung* (vd. tên archive đang mở), giữ ngắn (quy ước: dưới ~15 ký tự nếu có thể, để chừa chỗ cho control).
- Hỗ trợ **chuột phải › Customize Toolbar…** với kéo-thả sắp xếp — hành vi chuẩn của `NSToolbar`/SwiftUI `.toolbar`; đừng tự chế thanh công cụ bằng `HStack` trong content (nguồn: https://github.com/olzn/skills/blob/HEAD/docs/research/hig/components-nav-menus.md — trích HIG "Toolbars", last change 2025-12-16, "Updated guidance for Liquid Glass").

### 1.3 Materials, màu sắc, typography, light/dark

- **Materials/vibrancy chỉ dùng ở tầng control/navigation (sidebar, toolbar, tab bar) — không dùng ở tầng content (list, artwork).** Liquid Glass là material của tầng chức năng, nổi trên content; chỉ dùng sparingly, cho element quan trọng nhất. Đừng gắn custom `background`/`visualEffect` lên tab bar, navigation bar, toolbar, sidebar, sheet. Trên macOS 26, các chrome chuẩn (`.toolbar`, sidebar `NavigationSplitView`, sheet, `.inspector`) **tự nhận Liquid Glass khi build bằng macOS 26 SDK** — không cần và không nên gắn `.glassEffect` thủ công (nguồn: https://github.com/w159/clippy/blob/HEAD/docs/superpowers/research/2026-06-17-liquid-glass-symbols-hig.md ).
- **Màu semantic, không hardcode:** `labelColor`, `secondaryLabelColor`, `windowBackgroundColor`, `controlBackgroundColor`, `separatorColor`, `controlAccentColor` (accent do người dùng chọn trong System Settings). Sidebar icon theo accent color của hệ thống; chỉ dùng màu riêng khi thật sự là brand-critical. Light/Dark/Auto là việc của hệ thống — app không làm công tắc Light/Dark riêng, không tự vẽ 2 bộ màu.
- **Typography:** font hệ thống SF Pro; body macOS **13pt**, cỡ đọc tối thiểu **10pt** (nguồn: https://github.com/elevatormusic/apple-hig/blob/HEAD/skills/apple-hig/guidelines/platforms/macos.md ). Dùng text style (`.body`, `.callout`, `.footnote`, `.caption`) thay vì fix point size, để tôn trọng Larger Text/Preferred Reading Size. Bảng tham chiếu hay dùng: largeTitle 26 · title1 22 · title2 17 · title3 15 · headline 13 bold · body 13 · callout 12 · subheadline 11 · footnote/caption 10 (quy ước cộng đồng từ HIG, nguồn: https://github.com/apupsis/saglitzdesign-mcp/blob/HEAD/knowledge/design-languages/macos-app-design.md ).
- **SF Symbols:** dùng SF Symbols cho iconography (không bao giờ dùng symbol trong app icon/logo). Khớp weight/scale của symbol với text kề bên; outline cho toolbar/list, fill khi cần nhấn mạnh/selection; mặc định monochrome, chỉ dùng hierarchical/palette/multicolor khi có chủ đích; animate chỉ để phản hồi/trạng thái/progress, không làm cảnh (nguồn: HIG "SF Symbols"/"Icons", trích tại https://apple-docs.everest.mt/docs/design/human-interface-guidelines/icons/ và https://github.com/sillygru/fuseitall/blob/HEAD/.agents/skills/macos-hig-wails/SKILL.md ).

### 1.4 Cửa sổ, kích thước, progress

- Cửa sổ chính **resize tự do, nhớ kích thước/vị trí từng cửa sổ, restore khi mở lại**; đặt min/max hợp lý để content không chồng lấn và divider không biến mất; hỗ trợ full-screen trừ khi có lý do không. Con số tham chiếu (quy ước cộng đồng, không phải spec Apple in): min ~460×300 cho app utility, default lần đầu ~1100×700 (vừa màn 13"), content phải **reflow chứ không letterbox** ở mọi kích thước; kiểm tra ở đúng 50%/25% màn hình vì macOS có window tiling (nguồn: https://github.com/apupsis/saglitzdesign-mcp/blob/HEAD/knowledge/design-languages/macos-app-design.md ).
- **Đừng đặt thông tin/hành động quan trọng ở thanh dưới cùng** (bottom bar) — đáy cửa sổ hay bị khuất khi người dùng di chuyển cửa sổ; bottom bar tối đa là một dòng status nhỏ về nội dung cửa sổ.
- **Progress:** determinate (bar biết tổng) bất cứ khi nào biết được tổng; chỉ dùng indeterminate spinner ngắn; **long operation phải nằm trong UI progress không chặn cửa sổ, có Cancel — không bao giờ dùng modal khóa cửa sổ hàng phút**; báo tiến độ trung thực (bar kẹt ở 90% trông như bị treo); cho Cancel ở nơi halt an toàn, Pause khi tiến độ dở dang còn giá trị (nguồn: HIG "Progress indicators", trích tại https://github.com/sillygru/fuseitall/blob/HEAD/.agents/skills/macos-hig-wails/SKILL.md ).

### 1.5 Bàn phím & accessibility — không phải "thêm sau"

- macOS là **pointer-first + keyboard-first**: menu bar là source of truth cho mọi lệnh; toolbar/context menu/gesture chỉ là shortcut tới lệnh đã có trong menu bar. Mọi menu item thực thi action nên có shortcut; tôn trọng shortcut chuẩn (⌘C/V/X, ⌘S, ⌘Z/⇧⌘Z, ⌘W, ⌘Q, ⌘N, ⌘O, ⌘P, ⌘F, ⌘,), **không reassign** chúng; thứ tự modifier hiển thị: Control, Option, Shift, Command; ưu tiên ⌘, tránh Control (system-reserved).
- **Full Keyboard Access:** mọi control phải tới được và thao tác được chỉ bằng bàn phím, không có keyboard trap, focus ring nhìn thấy được, thứ tự focus logic. Toggle hệ thống: Control-F1; Control-F2 focus menu bar, Control-F5 toolbar.
- **VoiceOver:** mọi control phải expose role + label + value (icon-only toolbar item bắt buộc có `accessibilityLabel`); gom cell phức hợp thành một VoiceOver stop (`.accessibilityElement(children: .combine)`); test bằng Accessibility Inspector + Full Keyboard Access + Switch Control + Voice Control (nguồn: https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/design-and-accessibility.md ; https://github.com/olzn/skills/blob/HEAD/suites/hig/hig/references/tables/keyboard-shortcuts-macos.md ).
- **Target tối thiểu:** macOS 28×28pt (tối thiểu tuyệt đối 20×20pt); đừng làm nút nhỏ hơn chỉ vì "cho gọn".

### 1.6 Lưu ý về "current 2024–2026 guidance" vs target 14.6+

- HIG hiện tại (đợt cập nhật WWDC25 2025-06-09 và WWDC26 2026-06-08) viết cho kỷ nguyên Liquid Glass (macOS 26 Tahoe, 15/09/2025) và macOS 27 "Golden Gate" (09/2026, chỉ Apple Silicon). Nhưng **SeekZip chạy trên macOS 14.6+**, nên: (a) mọi guidance về *cấu trúc* (sidebar/content/inspector, toolbar, menu bar, keyboard) vẫn áp dụng nguyên vẹn — chúng ổn định từ trước Liquid Glass; (b) mọi guidance về *vẻ ngoài* Liquid Glass (sidebar nổi, toolbar glass, Clear/Tinted toggle từ 26.1) chỉ là "hệ thống tự lo khi chạy trên Tahoe" — app không được code riêng cho nó, không được yêu cầu macOS 26, và không được giả định nó tồn tại trên Sonoma/Sequoia. Nguồn về Tahoe: https://macos-tahoe.com/blog/macos-tahoe-vs-sequoia-complete-comparison-2025/ ; https://www.theodorehq.com/solace/blog/posts/macos-tahoe-dark-mode-guide .

---

## 2. Các app archive & file tốt nhất làm UI ra sao

### 2.1 Bảng so sánh (chỉ ghi điều đã xác minh được; "không xác minh được" ghi rõ)

| App | Layout cửa sổ chính | View modes | Preview | Toolbar / điều hướng | Cảm nhận: hay / dở |
|---|---|---|---|---|---|
| **Finder** (chuẩn vàng) | Sidebar trái (Favourites/Locations/Tags) + content + preview pane phải (tùy chọn) + status bar | Icon ⌘1, List ⌘2, Column ⌘3, Gallery ⌘4 | Preview pane (⇧⌘P) cập nhật theo selection ở cả 4 view; Column view tự preview ở cột phải nhất; Quick Look = Space | Toolbar tùy biến, view switcher, search; path bar + back/forward | Hay: 4 view đúng việc, column view là cách nhanh nhất để "thấy đường đi"; preview gắn với selection, không cần mở file. Dở: Gallery view ít hữu ích với file text/app; Column view không sort được theo cột. Nguồn: https://1dot.ai/blog/how-to-preview-files-on-mac-without-opening ; https://sdmactech.com/get-to-your-files-faster-by-choosing-the-best-finder-view-2/ |
| **BetterZip 6** ($35, MacItBetter, từ 2006) | **Split-view hiện đại** (redesign v6.0), sidebar Favorites trái + content giữa + **info/preview sidebar phải (ẩn được qua View menu từ 6.0.2)** | **Icon + Column mới thêm ở v6**, cùng flat list và outline — "browse archives as icons, columns, a flat list or an outline" | Built-in preview pane + Quick Look (Space); **Slideshow toàn màn hình cho ảnh** (View › Slideshow, zoom/pan không cần extract); Web Preview cho HTML | Path bar có back/forward (mới ở v6); Finder submenu chứa mọi preset; Drop Bar (kéo file vào preset) | Hay: chuẩn mực để noi theo — giống Finder nhất trong các archiver; coi archive như folder, sửa tại chỗ (rename/delete/move, save mới ghi đĩa). Dở: trả phí; vẫn là AppKit-era về cảm giác ở một số chỗ (nhận xét thứ cấp). Nguồn live: https://www.betterzip.pro/ ; version history: https://macitbetter.com/versionhistory.php ; review v6: https://levysoft.medium.com/betterzip-6-the-archive-manager-for-macos-gets-a-refresh-7668a7209bca |
| **MacPacker** (free, open source GPL-3.0, v1.2.0, Swift/SwiftUI, macOS 14.6+) — **đối thủ trực tiếp nhất của SeekZip** | "Mở archive như cửa sổ Finder" — cửa sổ native, list chi tiết (tên, packed size, size, date modified) | List (theo ảnh chụp trên site); không thấy đề cập icon/column view | Quick Look bằng Space, không ghi gì ra đĩa; preview README trong Quick Look | Breadcrumb để quay ra khỏi nested archive; kéo-thả file ra Finder | Hay: đúng triết lý SeekZip cần — browse như folder, nested archive mở tại chỗ "sâu bao nhiêu cũng được", breadcrumb quay ra, kéo 1 file ra khỏi archive 2 GB "mất một giây". Dở: **chính MacPacker cũng chỉ có list view** (theo site) — đây là khoảng trống để SeekZip vượt lên bằng Table + icon view + inspector; tính năng tạo archive chỉ ZIP/7z. Nguồn live: https://macpacker.app/en |
| **Keka** (free web / $6.49 MAS, từ 2008) | **Gần như không có cửa sổ chính** — cửa sổ nhỏ là drop target + chọn format (7z/ZIP/Tar/Gzip/Bzip2…), cấu hình nén; workflow chính là **Dock icon** | Không có archive browser | Không có preview trong archive | Dock drag-and-drop là chính; Finder extension qua helper | Hay: triết lý "invisible utility" — đơn giản nhất, không cần học; drag file vào Dock icon là xong. Dở (cho SeekZip): **không duyệt được archive**, không preview trước khi extract, không sửa archive — SeekZip không nên bắt chước Keka ở điểm này, chỉ nên học sự lịch sự "đừng bắt người dùng mở app khi không cần" (áp dụng cho Finder menu + Quick Look extension đã có). Nguồn: https://www.keka.io/en/?ref=omgubuntu.ru ; https://bundl.run/apps/keka |
| **The Unarchiver** (free, MacPaw, v4.3.9) | **Không có cửa sổ chính** — double-click là extract; chỉ có Preferences | Không có | Không có — "There's no browse screen, no file list" | Không có | Hay: đơn giản tuyệt đối, hỗ trợ 50+ format extract. Dở: không tạo archive, không xem trước — là "anti-pattern" cho mục tiêu của SeekZip; chỉ chứng minh rằng "vô hình" là một lựa chọn thiết kế hợp lệ cho *extraction-only*, không phải cho *archive manager*. Nguồn: https://1dot.ai/blog/preview-zip-archive-contents-mac ; https://bundl.run/compare/keka-vs-the-unarchiver |
| **Archive Utility** (built-in macOS) | **Không có cửa sổ** — chạy rồi tự thoát; chỉ có Settings (nơi lưu file, sau khi expand thì làm gì với archive) | Không có | Không có | Không có | Là baseline "zero UI": double-click ZIP là xong. Bài học: nếu SeekZip chỉ làm extraction thì không cần UI; nhưng vì SeekZip là *manager* (browse/preview/edit) nên UI phải tồn tại — và phải biện minh cho sự tồn tại của nó bằng preview + selective extract. Nguồn: https://ftp-mac.com/best-archiver-mac.html ; https://www.tsamoudakis.com/stop-your-downloads-folder-from-filling-up-with-zips/ |
| **7-Zip File Manager** (Windows) | File manager 1 pane, dual-pane tùy chọn; toolbar chứa tính năng hay dùng nhất + mê cung menu | Details view mặc định; dual-pane | Không có preview pane kiểu Mac | Toolbar + address bar kiểu Explorer | **Đáng mượn:** dual-pane cho kéo-thả qua lại (nhưng xem §5.1 — trên Mac nên thay bằng drag ra Finder + inspector, không clone dual-pane); browse archive như folder; mở lại đúng chỗ lần trước. **Không copy:** giao diện "dated/cluttered", "maze of menus", "confusing for new users, little in the way of instructions" (TechRadar). Nguồn: https://www.techradar.com/reviews/pc-mac/software/7-zip-review-1324265/review ; https://www.slant.co/versus/8272/8596/~7-zip_vs_freecommander |
| **WinRAR** (Windows, từ 1995) | File-manager-like, address bar + toolbar (Add/Extract/Test/Delete/Repair…) + status bar | List/details | Không có preview pane kiểu Mac | Toolbar nhiều nút + Wizard cho người mới | **Đáng mượn:** nút chức năng đặt tên bằng động từ rõ nghĩa (Add/Extract/Test) — SeekZip nên giữ động từ rõ nghĩa cho primary action thay vì icon khó đoán; Wizard là ý hay cho lần đầu tạo archive (nhưng làm bằng sheet gọn, không phải wizard nhiều bước). **Không copy:** "interface looks a little dated… garish icons", "many buttons", "a bit cluttered or dated", trial reminder popup — đúng thứ user gọi là "không lịch sự". Nguồn: https://gramfile.com/winrar-windows/ ; https://payments.oliverbonacini.com/blog/winrar-vs-7-zip-which-is-best-1764802493 |

### 2.2 Kết luận từ đối thủ

1. **Chuẩn mực 2026 cho archive manager trên Mac là BetterZip 6:** split-view + sidebar favorites + info/preview sidebar phải + 4 view modes (icon/column/flat list/outline) + path bar có back/forward + Quick Look + slideshow ảnh. SeekZip miễn phí mà đạt được 80% trải nghiệm này bằng SwiftUI native thì đã là vượt trội so với MacPacker (chỉ có list) — đó là "khoảng trống thị trường" cụ thể.
2. **Finder là từ điển, không phải đối thủ:** mọi quy ước (⌘1–4, Space, ⇧⌘P, breadcrumb/path, sidebar sections) nên mượn nguyên từ Finder để người dùng không phải học lại.
3. **Keka/The Unarchiver/Archive Utility dạy một bài học ngược:** càng ít UI càng lịch sự — nhưng chỉ khi job là "extract tất cả". SeekZip làm nhiều hơn thế, nên UI phải "xuất hiện khi cần, biến mất khi không cần": sidebar/inspector đóng được, preview theo selection, queue không chiếm một panel cố định.

---

## 3. UX đặc thù cho archive

### 3.1 Duyệt nested archive (archive trong archive)

- **Mô hình:** mỗi tầng nested là một node trong navigation stack, không phải một cửa sổ mới. Double-click (hoặc ⌘O / Return) một archive con thì "đi vào trong" — content đổi sang listing của archive con, **breadcrumb cập nhật** (`archive.zip › data.tar.gz › inner.zip › folder/`), nút Back/Forward (lịch sử duyệt, như BetterZip 6 và Finder) hoạt động. MacPacker làm đúng mẫu này: ".zip inside a .tar.gz inside a .dmg opens in place, however deep it goes. Breadcrumbs take you back out." (nguồn live: https://macpacker.app/en ).
- **Bắt buộc:** mỗi đoạn breadcrumb click được (nhảy thẳng về tầng đó), có menu chuột phải/long-press? (không — giữ đơn giản: click là nhảy); nút Back/Forward phải disabled đúng lúc (không có lịch sử thì mờ đi, đừng ẩn); tiêu đề cửa sổ hiển thị archive gốc + tầng hiện tại (vd. `inner.zip — trong data.tar.gz`), không chỉ hiện tên file con.
- **Hiệu năng:** đừng extract toàn bộ archive cha ra đĩa để đọc archive con — chỉ extract đúng entry con đó vào temp (stream qua 7zz), list nó, cache lại trong phiên. Khi đóng tầng thì dọn temp.
- **Cạm bẫy:** vòng lặp (archive chứa chính nó qua symlink/tên trùng) — giới hạn độ sâu (vd. 16 tầng) và hiện lỗi lịch sự thay vì treo.

### 3.2 Preview-before-extract

- **Nguyên tắc:** chọn file → inspector hiện thumbnail/metadata ngay; Space → Quick Look toàn màn hình; **không ghi gì ra đĩa cho tới khi người dùng quyết định extract hoặc preview cần file thật**. Với file text nhỏ (README, .md, .json, code), render inline trong inspector bằng `Text` + syntax highlight nhẹ (hoặc Quick Look thumbnail) thay vì bắt mở Quick Look.
- **Kỹ thuật:** Quick Look cần **local file URL** — file trong archive phải được extract vào thư mục temp (đã có trong app) rồi mới đưa URL đó cho `.quickLookPreview` (§4.4). Hiện trạng thái "Đang chuẩn bị preview…" trong inspector nếu extract entry lớn chậm; cho phép hủy.
- **Slideshow ảnh (phase 2, học BetterZip 6):** View › Slideshow duyệt ảnh trong archive, zoom/pan không cần extract — rất hợp với CBZ/comic/photo archive.

### 3.3 Selective extraction

- **Luồng chuẩn (1 giây phải hiểu):** chọn 1–n mục (⌘-click / ⇧-click / ⌘A) → nút **Extract** (primary, trailing toolbar) hoặc kéo-thả thẳng ra Finder/Desktop → chọn đích (mặc định: cùng thư mục với archive, hoặc thư mục đã chọn lần trước) → chạy nền, không khóa cửa sổ.
- **Kéo ra ngoài là tính năng, không phải bonus:** người dùng Mac kỳ vọng kéo file từ Finder ra Desktop được thì kéo file từ archive ra Desktop cũng được. Đây là điểm MacPacker làm tốt ("Drag any file or folder from the archive into Finder") và là điểm SwiftUI khó nhất (§4.4 — cần AppKit file promise).
- **Conflict khi extract:** nếu đích đã có file trùng tên — sheet nhỏ, lịch sự: Keep Both / Replace / Skip (+ "áp dụng cho tất cả"), đừng tự động overwrite, đừng tự động rename im lặng.
- **Thêm file vào archive (edit):** kéo file từ Finder **vào** content view → highlight drop target (toàn bộ content hoặc folder đang mở) → thêm vào archive (ZIP/7z), hiện trạng thái "chưa lưu" (dirty dot ở title, như document app) cho tới khi Save (⌘S).

### 3.4 Drag-and-drop (vào & ra)

| Hướng | Hành vi | Kỹ thuật |
|---|---|---|
| Kéo archive/file từ Finder **vào** cửa sổ SeekZip | Mở archive đó; hoặc nếu đang mở một archive editable thì thêm file vào archive | SwiftUI `.onDrop` / `.dropDestination` với `UTType.fileURL` — làm được native |
| Kéo entry **ra** Finder/Desktop | Finder nhận file thật (đã extract) | **Không làm được bằng SwiftUI thuần** — cần `NSFilePromiseProvider` qua AppKit (§4.4). Trong lúc chưa có, fallback lịch sự: drag ra sẽ extract vào temp rồi đưa URL thật (chậm với file lớn, phải hiện progress); ghi rõ trong UI là "đang chuẩn bị…" |
| Kéo entry giữa các folder trong cùng archive | Move/rename trong archive | SwiftUI `.onDrag` + `.onDrop` nội bộ — làm được |
| Kéo archive vào Dock icon | Mở archive | Hỗ trợ sẵn của hệ thống nếu khai báo document type; học Keka |

### 3.5 Progress & cancellation cho job dài

- **Không modal.** Job (extract/create/listing lớn) chạy nền; tiến độ hiện ở 3 chỗ, theo thứ tự ưu tiên: (1) **status bar** — bar determinate + tên job + % + nút Cancel (×); (2) **inspector › Jobs** — danh sách job, mỗi job có progress + Cancel/Pause; (3) **Dock icon** — progress badge của hệ thống. Cửa sổ vẫn duyệt được archive khác trong lúc job chạy (multi-window hoặc ít nhất không block UI).
- **Cancel phải thật sự hủy:** kill subprocess 7zz, dọn file dở dang (hoặc giữ lại phần đã xong và báo rõ), không để file nửa vời giả vờ hoàn chỉnh. Nếu hủy làm mất tiến độ thì cảnh báo trước (HIG).
- **Queue:** giữ khái niệm queue (đã có), nhưng đừng chiếm một panel cố định dưới cùng. Queue là một *section* trong inspector + một dòng trong status bar ("2 jobs đang chờ"). Khi không có job, cả hai biến mất — cửa sổ thở được.
- **Lỗi:** inline tại chỗ (row badge / inspector) với câu recovery ("Archive bị lỗi CRC ở file X — thử Repair?"); alert chỉ cho lỗi blocking. Không bao giờ hiện trạng thái "trống trơn" giả vờ ổn khi thật ra đang lỗi.

### 3.6 Metadata của archive (hiện ở đâu, hiện cái gì)

Inspector chia 2 trạng thái:
- **Không chọn gì / chọn archive:** Format (ZIP/7z…), phương pháp nén, tổng kích thước đã nén / chưa nén, **tỉ lệ nén** (vd. 62% — con số người dùng archive quan tâm nhất), số mục, số folder, mã hóa (🔒 AES-256 / ZipCrypto / không), có chia volume không (.zip.001…), ngày tạo/sửa, đường dẫn file gốc, checksum (SHA-256 nếu tính được — BetterZip có, SeekZip có thể thêm ở phase sau).
- **Chọn 1 mục:** thumbnail/preview, tên, loại (kind), kích thước + kích thước đã nén + tỉ lệ riêng, ngày sửa, CRC, mã hóa (icon 🔒 trên row và trong inspector), quyền (Unix mode nếu có).
- **Chọn nhiều mục:** tổng số mục + tổng kích thước đã chọn (dòng này cũng lặp lại ở status bar — người dùng nhìn status bar là đủ, không cần mở inspector).

### 3.7 Listing rất lớn (50k–1M entries)

- **Đừng load toàn bộ listing rồi mới hiện.** `7zz l` stream từng dòng → parse incremental → append theo batch (vd. 500–1000 dòng/lần) → Table hiện dần, có progress "Đang liệt kê… 12.400 mục". Người dùng thấy nội dung trong <1s thay vì chờ hết.
- **Dùng `Table`, không dùng `List`, cho content chính.** Lý do có số liệu: một bài đo thực tế (Rockxy, 2026) cho thấy SwiftUI `List` trên macOS ở 50.000 dòng chỉ còn 31 FPS và ~540 MB, 100.000 dòng còn 22 FPS / ~800 MB — vì `List` dùng `NSCollectionView`, recycle view không triệt để; trong khi `NSTableView` ở 100.000 dòng dùng 45 MB và giữ 60 FPS (nguồn: https://rockxy.io/blog/virtual-scrolling-swiftui ). `Table` của SwiftUI trên macOS cũng dựa trên AppKit table, và là lựa chọn đúng cho dữ liệu bảng nhiều cột. (Lưu ý: đây là đo của một bên thứ ba, không phải của Apple — dùng làm định hướng, vẫn phải tự profile bằng Instruments với dữ liệu thật của SeekZip.)
- **Quy tắc hiệu năng cho Table lớn:** row model là **class (reference type)**, không phải struct (tránh diff toàn bộ mảng mỗi lần đổi); **pre-format** chuỗi hiển thị (kích thước "1,2 GB", ngày tháng) ở background, không format trong `body` của cell; `TableColumn(value:)` bằng key-path thay vì closure khi có thể; cột có width giới hạn; **ID ổn định** (đường dẫn trong archive, không phải index hay `UUID()` mới mỗi lần render); không bọc `Table` trong `ScrollView`; không làm việc nặng (decode ảnh, regex, hash) trong cell (nguồn: https://github.com/laughingjackalope/macos-skills/blob/HEAD/swiftui-macos-performance/SKILL.md ; https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/performance-and-shipping.md ).
- **Tìm kiếm/lọc:** search field ở toolbar (`.searchable`), filter theo tên (debounce ~150–200ms, chạy ở background, không block gõ); thêm **Flat vs Outline toggle**: Flat = liệt kê mọi file kèm đường dẫn (tìm file lạc trong archive sâu), Outline = cây folder có disclosure (duyệt theo cấu trúc). Với 1M entries, flat + filter là cách duy nhất dùng được — cây outline 1M node không render nổi.

### 3.8 Breadcrumb / path navigation & search/filter trong archive

- **Breadcrumb** nằm ngay dưới toolbar, trên Table (hoặc tích hợp vào toolbar như Finder path bar): `archive.zip › folder › subfolder`, mỗi đoạn click được, đoạn cuối là tên folder hiện tại (không phải link). Kèm nút Back/Forward ở toolbar (leading, cạnh sidebar toggle) — giống Finder/BetterZip 6.
- **Search:** `⌘F` focus search field; search trong *toàn bộ archive* (không chỉ folder hiện tại), kết quả hiện dạng flat list kèm cột Path; Esc xóa search và quay về folder đang duyệt; giữ lại query khi chuyển folder (đừng reset bất ngờ).
- **Filter nhanh:** menu filter ở toolbar (loại file: ảnh/tài liệu/archive con; chỉ hiện file đã mã hóa; chỉ hiện file >100 MB) — dùng `Menu` với SF Symbol `line.3.horizontal.decrease.circle` (tên symbol cần verify trong app SF Symbols trước khi ship).

---

## 4. SwiftUI trên macOS 14/15: làm được gì native, chỗ nào cần AppKit

| Cần làm | SwiftUI native (macOS 14) | Ghi chú / cạm bẫy |
|---|---|---|
| **Sidebar 2 cột** | ✅ `NavigationSplitView { sidebar } detail: { }`, `.listStyle(.sidebar)` | Sidebar là `List` với `Section` + `Label` + SF Symbol; đừng fix width cột (HIG: "Do not fix the column widths"); dùng `navigationSplitViewColumnWidth(min:ideal:max:)` cho cột leading, **không có tác dụng trên cột detail** |
| **3 cột** | ✅ `NavigationSplitView { } content: { } detail: { }` | macOS luôn hiện cột content; `.doubleColumn` không ẩn sidebar như trên iOS compact — coi visibility là gợi ý, không phải đảm bảo |
| **Inspector** | ✅ `.inspector(isPresented:)` (macOS 14+), `.inspectorColumnWidth(min:ideal:max:)` | Gắn vào **detail column**, không gắn ngoài `NavigationSplitView` (nếu gắn ngoài, inspector chiếm full height, toolbar không overlay nó); width chuẩn ~225–280pt; toggle quy ước ⌥⌘I |
| **Table (list view)** | ✅ `Table`, `TableColumn`, `sortOrder` + `KeyPathComparator`, `alternatingRowBackgrounds` (macOS 14+) | Đây là view chính cho SeekZip; hỗ trợ sort/resize/reorder cột, selection, context menu; xem §3.7 về hiệu năng |
| **Outline (cây folder trong Table/List)** | ✅ `OutlineGroup` / `List(children:)` | Dùng cho folder tree trong Table; với dữ liệu lớn, chỉ expand khi người dùng mở (lazy children), đừng build toàn bộ cây trước |
| **Icon/Grid view** | ✅ `LazyVGrid` + `ScrollView` | Chỉ dùng cho tập vừa (hàng trăm đến vài nghìn mục); **không recycle cell mạnh như `NSCollectionView`** — với 100k+ mục, AppKit `NSCollectionView` + diffable data source vẫn tốt hơn (nguồn: https://github.com/laughingjackalope/macos-skills/blob/HEAD/swiftui-macos-performance/SKILL.md ). Icon view của SeekZip nên giới hạn: chỉ render thumbnail cho file trong viewport, cache thumbnail, và tự động về Table khi folder > ~5.000 mục (kèm thông báo lịch sự) |
| **Toolbar chuẩn, customize được** | ✅ `.toolbar`, `ToolbarItem(placement: .primaryAction/.navigation)`, `ToolbarSpacer` | Dùng placement hệ thống, đừng tự vẽ thanh toolbar bằng `HStack`; hỗ trợ Customize Toolbar… là hành vi có sẵn của toolbar chuẩn |
| **Search** | ✅ `.searchable` | Gắn search field vào toolbar; nhớ debounce + chạy filter ở background |
| **Quick Look (Space)** | ✅ `.quickLookPreview($url)` (macOS 11+) | **Chỉ nhận local file URL** — file trong archive phải extract ra temp trước; present dạng sheet; muốn multi-item + điều khiển chi tiết thì bọc `QLPreviewController` bằng `NSViewControllerRepresentable` (nguồn: https://apple-docs.everest.mt/docs/wwdc/wwdc2023-10085/ ) |
| **Kéo file vào app** | ✅ `.onDrop` / `.dropDestination` | Nhận `fileURL` từ Finder — native |
| **Kéo entry ra Finder (drag-out thật)** | ❌ **Không làm được bằng SwiftUI thuần** | SwiftUI không có tương đương `NSFilePromiseProvider` (ghi nhận FB13583826, nguồn: https://wadetregaskis.com/tags/transferable/ ). Cần AppKit drag session để "hứa" file: khi Finder drop, app mới extract entry đó ra đích. **Đây là bridging bắt buộc, không phải nice-to-have** — nếu không làm, drag-out chỉ là "extract ra temp rồi đưa URL", chậm và tốn đĩa với file lớn |
| **Column view kiểu Finder** | ❌ **Không có SwiftUI native** | Control là AppKit `NSBrowser` (HIG: macOS-only, xem §1.1); `NavigationSplitView` chỉ là xấp xỉ, không phải column view. Muốn column view thật phải bọc `NSBrowser` bằng `NSViewRepresentable` + delegate/data source — ước tính là hạng mục AppKit lớn nhất trong redesign, để phase 3 |
| **Gallery view** | ⚠️ Tự chế được (preview lớn + filmstrip `LazyHStack`) nhưng không có component chuẩn | Finder Gallery không có SwiftUI tương đương; BetterZip làm slideshow riêng. Khuyên: **đừng làm Gallery view** — Slideshow ảnh (phase 2) đáp ứng đúng nhu cầu (xem ảnh trong archive) với ít code hơn nhiều |
| **Tabs (nhiều archive trong một cửa sổ)** | ✅ `TabView` / `.tabViewStyle(.sidebarAdaptable)` (macOS 14+) | Làm được, nhưng xem trade-off §5.1: tab làm phức tạp sidebar + title + drag; phase 1 nên là **mỗi archive một cửa sổ** (document model chuẩn macOS), tab để phase sau nếu người dùng đòi |
| **Window size/min/restore** | ✅ `.windowResizability`, `.defaultSize`, `NSWindow.minSize` qua AppKit | Đặt min size rõ ràng; nhớ kích thước/vị trí (state restoration); test ở 50% màn hình |
| **Password sheet** | ✅ `.sheet` | Giữ như hiện tại; chỉ sửa visual: icon `lock.fill`, text rõ ràng, nút mặc định là Unlock (Return), Cancel là Esc; đừng dùng alert cho việc nhập password |

### 4.1 Những gì trong đề xuất này SwiftUI KHÔNG làm sạch được (flag đỏ)

1. **Column view** — cần `NSBrowser` bridging (phase 3, ước tính lớn nhất).
2. **Drag-out với file promise** — cần AppKit `NSFilePromiseProvider` (phase 1.5 — làm sớm vì đây là core UX, không phải polish).
3. **Icon view ở quy mô rất lớn** — `LazyVGrid` không recycle đủ mạnh; cần giới hạn + fallback về Table, hoặc `NSCollectionView` bridging nếu thật sự cần 100k icon.
4. **`navigationSplitViewColumnWidth` không tác dụng lên cột detail** — nếu muốn inspector resize mượt như pane cấu trúc thì dùng `.inspector` (đã đủ) hoặc `HSplitView`/AppKit; đừng cố animate frame của detail về 0.
5. **Focus/selection kỳ lạ trên macOS 26/27** — có báo cáo (10/2026) rằng `List`/`Table` SwiftUI trên Tahoe/Golden Gate đôi khi không trở thành first responder khi click, ảnh hưởng focus sau đó (nguồn: https://mjtsai.com/blog/2026/10/20/selection-and-focus-in-golden-gate/ ). Chưa xác minh trên máy thật — ghi vào checklist test khi chạy trên Tahoe, không phải lý do để bỏ SwiftUI.

---

## 5. Đề xuất cụ thể cho SeekZip

### 5.1 Layout khuyên dùng — chi tiết từng vùng

**Cửa sổ:** mặc định **1100×700** (vừa màn 13"), **min 900×560** (đủ cho sidebar 220 + Table đọc được + inspector 250 khi mở; nếu hẹp hơn thì inspector tự đóng, sidebar tự collapse — theo HIG: panel collapse trước khi content bị bóp), resize tự do, nhớ size/position từng cửa sổ, hỗ trợ full-screen và tiling 50%. Tiêu đề = tên archive đang mở (không phải "SeekZip") + dirty dot khi archive đã sửa chưa lưu + proxy icon (kéo proxy icon ra Finder = copy archive file — hành vi document chuẩn, miễn phí nếu dùng đúng window/document model).

**Sidebar (220–280pt, resize được, ẩn được):**
- Section **"Đang mở"** — mỗi archive đang mở là một row (icon `archivebox`, tên, badge số mục hoặc kích thước; archive đang active được highlight; đóng bằng nút × khi hover hoặc ⌘W đóng cửa sổ). Đây là thay thế cho "tab" ở phase 1: nhiều archive = nhiều row trong sidebar, click để chuyển — đơn giản, không cần tab bar.
- Section **"Gần đây"** — 5–8 archive mở gần nhất (lưu trong UserDefaults/AppStorage, có "Clear" ở footer của section); click để mở lại.
- Section **"Yêu thích"** — folder/archive người dùng ghim (kéo-thả archive vào sidebar để ghim, như BetterZip Favorites); đây là nơi để "Downloads" và các thư mục hay chứa archive.
- Footer sidebar (không đặt action quan trọng ở đây — HIG): nút **"Tạo archive mới…"** (`plus` / `archivebox.badge.plus` — verify tên trong SF Symbols) và dung lượng trống? Không — chỉ nút Tạo mới, còn lại để trống cho thở.
- **Không có trong sidebar:** cây folder của archive (nó nằm trong Table/breadcrumb), settings (đã có Settings window), queue (nó nằm trong inspector/status bar).

**Content (giữa):**
- **Breadcrumb bar** ngay dưới toolbar: `archive.zip › folder › subfolder` + nút Back/Forward ở toolbar leading.
- **View modes (segmented control ở toolbar, phím ⌘1/⌘2/⌘3 như Finder):**
  - **⌘1 Icon** — `LazyVGrid`, thumbnail theo loại file (QLThumbnail cho ảnh/PDF, icon hệ thống cho file khác), tên 2 dòng, chọn nhiều bằng ⌘-click; tự fallback về Table khi >5.000 mục.
  - **⌘2 List (mặc định)** — `Table`: cột Tên (icon + tên + 🔒 nếu mã hóa), Kích thước, Đã nén, Tỉ lệ, Ngày sửa, Loại; click header sort; disclosure ▸ cho folder (outline); zebra row macOS 14.
  - **⌘3 Column (phase 3)** — `NSBrowser` bridging; mỗi cột một tầng, cột phải nhất là preview file.
  - **Không làm Gallery view** (xem §4).
- **Search field** ở toolbar trailing (`.searchable`, ⌘F focus); kết quả dạng flat + cột Path.
- **Empty states (bắt buộc, không để pane trắng):**
  - Chưa mở archive: icon `archivebox` lớn, tiêu đề "Kéo archive vào đây", phụ đề "hoặc nhấn ⌘O để mở — ZIP, 7z, RAR, TAR, DMG…", nút "Mở archive…" (primary) + "Tạo archive mới…".
  - Folder trống: "Thư mục này trống".
  - Search không kết quả: "Không tìm thấy 'xyz' trong archive này" + nút "Xóa tìm kiếm".
  - Đang liệt kê: progress "Đang đọc archive… 12.400 mục" (không phải spinner quay vô định).
- **Status bar (dưới cùng, 1 dòng, text `.footnote` màu `.secondary`):** trái: `128 mục • 1,2 GB (đã nén 480 MB)`; giữa/phải: khi chọn: `Đã chọn 3 mục — 45 MB`; khi có job: progress bar determinate + tên job + % + nút Cancel (×). Không đặt nút action quan trọng ở đây.

**Inspector (trailing, 250–280pt, toggle ⌥⌘I + nút toolbar `sidebar.right`):**
- Khi không chọn gì: metadata archive (§3.6) + nút Extract All (secondary).
- Khi chọn 1 mục: preview/thumbnail lớn + metadata mục + nút Extract / Quick Look (Space).
- Khi chọn nhiều: tổng hợp (§3.6).
- Section **Jobs** (chỉ hiện khi có job): mỗi job một dòng progress + Cancel; job xong thì hiện ✓ rồi biến mất sau vài giây (đừng để log dài chiếm chỗ).
- Inspector cập nhật theo selection, không có nút Apply.

**Toolbar (thống nhất với title bar, tối đa 3 nhóm):**
- Leading: sidebar toggle (`sidebar.left`) · Back/Forward (`chevron.left/right`) · (title là tên archive, do hệ thống đặt).
- Giữa: view mode segmented (`square.grid.2x2` / `list.bullet` / `rectangle.split.3x3` — verify tên symbol) — nhóm này collapse vào overflow khi cửa sổ hẹp (hệ thống tự lo).
- Trailing: search field · **Extract** (primary, `arrow.down.doc`, `.primaryAction`, tint accent) · menu More (`ellipsis.circle`: Tạo archive, Thêm file, Đổi tên, Xóa, Kiểm tra archive/Test, Hiển thị trong Finder) · inspector toggle (`sidebar.right`).
- Mọi item đều có trong menu bar (File/Edit/View/Window/Help) với shortcut (§5.3). Hỗ trợ Customize Toolbar….

**Settings:** giữ 3 tab hiện tại (Engines / Finder / About) nhưng sắp xếp lại theo BetterZip 6 (settings window được reorganize ở v6): Engines (đường dẫn 7zz, phiên bản, Test), Finder (8 mục menu chuột phải — cho phép bật/tắt từng mục, xem trước), About. Thêm tab/tab con **Appearance? Không** — đừng thêm setting Light/Dark/accent (đó là việc của hệ thống). Thêm **"Mở archive gần đây: số lượng"** và **"Thư mục giải nén mặc định"** nếu chưa có.

### 5.2 Visual language

| Yếu tố | Quyết định | Vì sao |
|---|---|---|
| Font | SF Pro, text style hệ thống (body 13, callout 12, footnote/caption 10) | HIG; tôn trọng Larger Text |
| Màu | Semantic colors hệ thống; **accent = accent hệ thống** (người dùng chọn), không hardcode màu brand cho UI | Sidebar icon theo accent; app trông "của hệ thống" ở mọi máy |
| Material | Sidebar: `.sidebar` material; toolbar: `.bar`; content: `windowBackgroundColor`; inspector: nền thường + divider 1pt | Materials chỉ ở tầng control/navigation |
| Icon | **SF Symbols toàn bộ** (không vẽ icon custom cho chức năng); outline cho toolbar/list, fill cho selection; monochrome mặc định; icon file thì dùng icon hệ thống theo UTI (NSWorkspace icon) | Nhất quán, miễn phí Dark Mode, miễn phí scale |
| Accent duy nhất | Nút Extract (primary) | Một điểm nhấn = lịch sự; nhiều điểm nhấn = ồn ào như WinRAR |
| Dark Mode | Tự động theo hệ thống; test cả 2 mode + Reduce Transparency | Không làm toggle riêng |
| Motion | Dùng animation hệ thống (`.animation` mặc định của NavigationSplitView/inspector); không animation trang trí; tôn trọng Reduce Motion | HIG: animate chỉ để phản hồi |
| Mật độ | Row Table ~28pt (macOS default); sidebar row theo cỡ hệ thống | Dày vừa phải — macOS dày hơn iOS, nhưng không nhồi nhét như 7-Zip |
| Bo góc / shadow | Không tự bo góc/shadow cho panel — để hệ thống lo (window, sheet, popover đã có) | Custom chrome là dấu hiệu "không phải app Mac" |

**Bảng SF Symbols gợi ý (phải verify từng tên trong app SF Symbols trước khi code — tên dưới đây là tên thông dụng, không phải trích HIG):**

| Chức năng | Symbol gợi ý | Ghi chú |
|---|---|---|
| Mở archive | `folder.badge.plus` / `archivebox` | — |
| Extract (primary) | `arrow.down.doc` | Động từ rõ nghĩa, giống "Extract" của WinRAR nhưng bằng icon chuẩn |
| Tạo archive | `archivebox.badge.plus` | Verify tên |
| Sidebar toggle | `sidebar.left` | Chuẩn hệ thống |
| Inspector toggle | `sidebar.right` | Chuẩn hệ thống |
| View: Icon / List / Column | `square.grid.2x2` / `list.bullet` / `rectangle.split.3x3` | Verify `rectangle.split.3x3` |
| Search | `magnifyingglass` | — |
| Filter | `line.3.horizontal.decrease.circle` | Verify tên |
| Quick Look / Preview | `eye` | Space là shortcut chính |
| Khóa/mã hóa | `lock.fill` (row), `lock.open` | Badge nhỏ trên row + inspector |
| Back/Forward | `chevron.left` / `chevron.right` | — |
| Thêm file vào archive | `plus` | Trong menu More |
| Xóa khỏi archive | `trash` | Role destructive, có confirm |
| Test archive | `checkmark.shield` | Verify tên |
| Job đang chạy / xong | `progress.indicator` (hệ thống) / `checkmark.circle.fill` | Dùng ProgressView hệ thống |

### 5.3 Keyboard shortcuts (đề xuất — căn theo Finder, tránh đụng shortcut hệ thống)

| Hành động | Shortcut | Căn cứ |
|---|---|---|
| Mở archive… | ⌘O | Chuẩn hệ thống |
| Đóng cửa sổ | ⌘W | Chuẩn hệ thống |
| Tạo archive mới… | ⌘N | Chuẩn hệ thống (New) |
| Lưu thay đổi vào archive | ⌘S | Chuẩn hệ thống (Save) |
| Tìm trong archive | ⌘F | Chuẩn hệ thống |
| Quick Look (Space) | Space | Finder |
| Icon / List / Column view | ⌘1 / ⌘2 / ⌘3 | Finder (⌘4 Gallery — không dùng vì không có Gallery) |
| Hiện/ẩn Preview/Inspector | ⌥⌘I | Quy ước inspector macOS (Pages/SF Symbols) |
| Hiện/ẩn Sidebar | ⌃⌘S | Quy ước cộng đồng (Finder dùng ⌃⌘S cho sidebar? — **cần verify trên máy thật**, nếu đụng thì dùng View menu không shortcut) |
| Quay lại / tới (lịch sử duyệt) | ⌘[ / ⌘] | Quy ước Finder/Safari |
| Vào folder/archive con | ⌘↓ hoặc Return | Finder (⌘↓ mở) |
| Ra folder cha | ⌘↑ | Finder |
| Lên đầu/cuối list | ⌘↑/⌘↓ trong Table? — dùng Home/End + ⌘Home/End theo Table chuẩn | Đừng tự chế |
| Extract mục đã chọn | ⌘E | Đề xuất riêng (không phải shortcut hệ thống) — phải ghi trong menu File |
| Hiển thị trong Finder | ⌘R? — **không**, ⌘R là Reload ở nhiều app; dùng menu không shortcut hoặc ⇧⌘R và ghi rõ | Tránh đụng |
| Settings… | ⌘, | Chuẩn hệ thống |
| Select All / Deselect All | ⌘A / ⇧⌘A | Chuẩn hệ thống |

Mọi shortcut phải hiện trong menu bar; mọi hành động trong toolbar/context menu phải có mặt trong menu bar (§1.2).

### 5.4 Trade-offs (đã cân nhắc, không chọn bừa)

| Lựa chọn | Chọn | Bỏ | Vì sao |
|---|---|---|---|
| 3 cột split vs 2 cột + inspector | **2 cột + inspector** | 3 cột (sidebar \| cây folder \| Table) | Cây folder trùng với outline trong Table; inspector đóng/mở được, 3 cột thì cột cây chiếm chỗ vĩnh viễn |
| Column view vs Breadcrumb | **Breadcrumb trước (phase 1), Column sau (phase 3)** | Column ngay từ đầu | Breadcrumb làm bằng SwiftUI thuần, đủ cho 90% ca nested; column cần NSBrowser bridging — đắt nhất |
| Dual-pane (7-Zip/WinRAR) vs Single-pane + drag ra Finder | **Single-pane + drag ra Finder + inspector** | Dual-pane | Dual-pane là idiom Windows/commander; trên Mac, đích kéo-thả là Finder (đã có sẵn, người dùng đã quen). Dual-pane chỉ nên xem lại nếu telemetry/feedback cho thấy người dùng hay copy giữa 2 archive |
| Tabs vs Nhiều cửa sổ | **Nhiều cửa sổ (phase 1), Tabs (phase sau, nếu cần)** | Tabs ngay | Document model macOS = mỗi archive một cửa sổ; sidebar "Đang mở" đã giải quyết chuyển đổi; tabs thêm phức tạp cho title/drag/focus |
| Queue panel cố định vs Queue trong inspector/status bar | **Inspector + status bar** | Panel dưới cùng cố định | Panel cố định ăn chiều cao vĩnh viễn dù không có job; HIG cấm đặt thứ quan trọng ở đáy; queue là trạng thái tạm thời, phải biến mất khi xong |
| Gallery view vs Slideshow ảnh | **Slideshow (phase 2)** | Gallery view | Gallery là view cho mọi loại file, ít giá trị với file text; slideshow giải quyết đúng job "xem ảnh trong archive" |
| Table vs List cho content | **Table** | List | Sort/resize cột + hiệu năng ở 50k+ dòng (§3.7); List chỉ hợp cho sidebar/settings |
| Accent brand vs Accent hệ thống | **Accent hệ thống** | Màu brand hardcode | Người dùng macOS đổi accent trong Settings và kỳ vọng mọi app theo; màu brand chỉ nên ở app icon |

### 5.5 Phased implementation plan

**Phase 1 — "Trông như app Mac" (win lớn nhất, làm trước; ước tính: phần lớn công việc là tái cấu trúc view, không đụng engine):**
1. Window: resizable, default 1100×700, min 900×560, nhớ size/position, title = tên archive + dirty dot.
2. `NavigationSplitView` 2 cột + sidebar (Đang mở / Gần đây / Yêu thích) + `.listStyle(.sidebar)`.
3. `Table` thay `List`: cột Tên/Kích thước/Đã nén/Tỉ lệ/Ngày sửa/Loại, sort, disclosure folder, zebra macOS 14, selection nhiều.
4. Breadcrumb + Back/Forward (⌘[ / ⌘]).
5. Toolbar chuẩn (sidebar toggle, view switcher Icon/List, search, Extract primary, More, inspector toggle) + menu bar đầy đủ + Customize Toolbar.
6. Inspector: metadata archive + selection (§3.6).
7. Status bar: counts + selection + job progress + Cancel.
8. Search/filter trong archive (debounce, background) + Flat/Outline toggle.
9. Empty states + loading progress (stream listing theo batch) + lỗi inline.
10. Queue chuyển vào inspector Jobs + status bar; bỏ panel dưới cùng cố định.
11. Password sheet làm lại visual (icon lock, nút rõ ràng).
12. Accessibility pass 1: `accessibilityLabel` cho mọi icon-only button, Full Keyboard Access test, VoiceOver test với Table.
- *Definition of done:* mở archive 10k mục, duyệt/sort/search/extract 1 file, đóng/mở lại giữ nguyên cửa sổ — không beachball, không modal chặn.

**Phase 1.5 — Drag-out thật (làm ngay sau Phase 1, trước polish):**
- AppKit bridging `NSFilePromiseProvider` cho drag entry ra Finder; fallback temp-extract có progress trong lúc chưa xong.
- Drag file từ Finder vào archive (thêm file) + drop highlight.
- *Definition of done:* kéo 1 file 500 MB từ archive ra Desktop — Finder nhận file, SeekZip không chiếm 500 MB temp vô ích, có progress + Cancel.

**Phase 2 — "Xem trước như Finder":**
- Icon view (`LazyVGrid`, thumbnail cache, fallback Table khi >5.000 mục) + ⌘1/⌘2.
- Preview inline trong inspector: text nhỏ render trực tiếp, ảnh/PDF thumbnail lớn (QLThumbnailGenerator).
- Slideshow ảnh toàn màn hình (View › Slideshow) + zoom/pan.
- Quick Look multi-item (QLPreviewController) để lật qua các file bằng phím mũi tên trong Quick Look.
- Conflict sheet khi extract trùng tên (Keep Both/Replace/Skip + Apply to all).
- *Definition of done:* mở CBZ 200 ảnh, slideshow lật mượt, không extract gì ra đĩa.

**Phase 3 — "Column view & nâng cao":**
- Column view bằng `NSBrowser` bridging (`NSViewRepresentable`) + ⌘3; cột phải nhất preview file.
- Tabs (nhiều archive trong một cửa sổ) — chỉ làm nếu feedback phase 1–2 cho thấy người dùng mở nhiều archive cùng lúc và than phiền về nhiều cửa sổ.
- Metadata nâng cao: SHA-256, recovery record (RAR), comment của archive.
- *Definition of done:* duyệt archive 5 tầng nested bằng column view, back/forward + breadcrumb đồng bộ.

**Phase 4 — Polish & độ tin cậy:**
- Accessibility pass 2: Switch Control, Voice Control, Reduce Motion/Transparency test, Dynamic Type/Larger Text.
- Instruments profiling với archive 50k/500k/1M entries; sửa điểm nghẽn theo §3.7.
- Test trên Sonoma 14.6, Sequoia 15, Tahoe 26 (cả Light/Dark, cả Reduce Transparency) — đặc biệt kiểm tra focus/selection trên Tahoe (§4.1 mục 5).
- Localisation: giữ tiếng Anh + tiếng Việt (MacPacker đã có tiếng Việt — người dùng SeekZip đọc tiếng Việt, đây là lợi thế cạnh tranh cụ thể).

### 5.6 Những thứ EXPLICITLY KHÔNG làm

1. **Không Electron / không UI cross-platform / không webview làm UI chính.** (Yêu cầu cứng của user.)
2. **Không Liquid Glass tự chế:** không `.glassEffect` lên toolbar/sidebar/inspector, không custom background cho chrome chuẩn, không yêu cầu macOS 26.
3. **Không cửa sổ cố định 900×600 nữa.** Không min size quá nhỏ làm Table không đọc được.
4. **Không clone 7-Zip/WinRAR:** không toolbar dày nút có viền + icon màu, không menu mê cung, không dual-pane kiểu Commander, không trial popup, không Wizard nhiều bước.
5. **Không Gallery/Cover Flow view.** (Cover Flow đã bị Apple bỏ từ El Capitan; Gallery ít giá trị cho archive.)
6. **Không tự vẽ Table bằng `HStack`/`LazyVStack`**, không bọc `Table` trong `ScrollView`, không `UUID()` mới mỗi render làm ID.
7. **Không modal progress chặn cửa sổ** cho job dài; không progress bar giả (kẹt 90%).
8. **Không đặt action quan trọng ở đáy sidebar hay bottom bar**; không để queue chiếm panel cố định.
9. **Không toggle Light/Dark riêng, không setting accent riêng, không icon custom thay SF Symbols** cho chức năng hệ thống.
10. **Không thêm tab/dual-pane/slideshow/column view vào Phase 1** — mỗi thứ đều làm tăng diện tích test và rủi ro focus; làm đúng thứ tự phase.
11. **Không tự động overwrite file khi extract trùng tên; không extract toàn bộ archive cha chỉ để đọc archive con.**
12. **Không dùng symbol SF Symbols trong app icon/logo** (HIG cấm).

---

## Could not verify / Open questions

1. **HIG trực tiếp:** `browser_open` tới trang HIG thất bại (SPA, no extractable content) — không lặp lại theo hướng dẫn. Nội dung HIG trong báo cáo này dựa trên bản trích DocC JSON của Apple qua mirror công khai; cần đối chiếu lại bằng Xcode Documentation hoặc trình duyệt thật trước khi chốt các con số (đặc biệt: chiều rộng sidebar/inspector chuẩn, cỡ row).
2. **Tên SF Symbols cụ thể** (`archivebox.badge.plus`, `rectangle.split.3x3`, `line.3.horizontal.decrease.circle`, `checkmark.shield`…): chưa verify trong app SF Symbols — phải kiểm tra trước khi code, thay bằng tên đúng hoặc symbol khác.
3. **Shortcut ⌃⌘S cho sidebar:** nguồn thứ cấp ghi vậy; chưa verify trên máy thật — nếu đụng hệ thống thì bỏ shortcut, chỉ để trong View menu + toolbar button.
4. **Giao diện thật của BetterZip 6 / MacPacker / Keka:** chỉ xem qua site chính thức + review + ảnh chụp trên site; **không chạy app thật**, không đo được cảm giác cuộn/chuyển view, không xác minh được chi tiết như: BetterZip sắp xếp cột mặc định ra sao, MacPacker xử lý archive 50k mục thế nào. Nên chạy thử BetterZip 6 (trial 30 ngày) và MacPacker (miễn phí) trên máy thật trước khi chốt Phase 1.
5. **Hiệu năng Table/List ở 50k–1M dòng:** số liệu Rockxy là đo của bên thứ ba trên workload của họ (network requests), không phải listing archive; phải tự profile SeekZip bằng Instruments với `7zz l` thật.
6. **macOS 27 "Golden Gate":** các nguồn tháng 06–10/2026 mô tả nó là beta/pre-GA; SeekZip target 14.6+ nên không thiết kế cho nó — chỉ cần test không vỡ trên đó khi ra mắt.
7. **Màu accent/brand của SeekZip:** mission không cho biết app có màu brand riêng không — báo cáo khuyên dùng accent hệ thống; nếu đã có brand color thì cần quyết định riêng (chỉ dùng cho app icon + nút Extract, không nhuộm toàn bộ UI).
8. **Số liệu "108 unit tests green", "7zz 26.05", "8 mục Finder menu":** lấy từ mission (context do requesting agent cung cấp), không xác minh độc lập từ web — không ảnh hưởng tới đề xuất thiết kế.

## Sources

- HIG Sidebars (canonical, trích qua DocC JSON mirror): https://developer.apple.com/design/human-interface-guidelines/sidebars
- HIG Toolbars (canonical): https://developer.apple.com/design/human-interface-guidelines/toolbars
- HIG Column views (canonical): https://developer.apple.com/design/human-interface-guidelines/column-views
- HIG Designing for macOS (canonical): https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
- HIG research notes — navigation/menus (trích DocC JSON, 2026-06-10): https://github.com/olzn/skills/blob/HEAD/docs/research/hig/components-nav-menus.md
- HIG research notes — layout/content (trích DocC JSON, 2026-06-10): https://github.com/olzn/skills/blob/HEAD/docs/research/hig/components-layout-content.md
- HIG Sidebars mirror (trích DocC JSON, 2026-06-26): https://github.com/prisma-labs-dev/apple-skills/blob/HEAD/skills/hig/sidebars.md
- macOS HIG — Designing for macOS mirror: https://github.com/elevatormusic/apple-hig/blob/HEAD/skills/apple-hig/guidelines/platforms/macos.md
- macOS App Design — Complete Guide (Tahoe era, tổng hợp HIG): https://github.com/apupsis/saglitzdesign-mcp/blob/HEAD/knowledge/design-languages/macos-app-design.md
- HIG macOS — Wails mapping (trích HIG Windows/Toolbars/Materials/Progress): https://github.com/sillygru/fuseitall/blob/HEAD/.agents/skills/macos-hig-wails/SKILL.md
- HIG Icons / SF Symbols: https://apple-docs.everest.mt/docs/design/human-interface-guidelines/icons/
- Liquid Glass / SwiftUI materials: https://github.com/w159/clippy/blob/HEAD/docs/superpowers/research/2026-06-17-liquid-glass-symbols-hig.md
- Accessibility & keyboard (macOS): https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/design-and-accessibility.md
- Standard keyboard shortcuts macOS (trích HIG Keyboards): https://github.com/olzn/skills/blob/HEAD/suites/hig/hig/references/tables/keyboard-shortcuts-macos.md
- BetterZip — official, **verified live 11/11/2026**: https://www.betterzip.pro/
- BetterZip Version History (v6.0/6.0.2/6.0.6/6.1): https://macitbetter.com/versionhistory.php
- BetterZip 6 review (30/08/2026): https://levysoft.medium.com/betterzip-6-the-archive-manager-for-macos-gets-a-refresh-7668a7209bca
- MacPacker — official, **verified live 11/11/2026**: https://macpacker.app/en
- Keka — official: https://www.keka.io/en/?ref=omgubuntu.ru
- Keka review: https://bundl.run/apps/keka
- The Unarchiver vs Keka: https://bundl.run/compare/keka-vs-the-unarchiver
- Preview ZIP/RAR without extracting (Unarchiver/Keka/BetterZip): https://1dot.ai/blog/preview-zip-archive-contents-mac
- Archive Utility (no window, settings only): https://ftp-mac.com/best-archiver-mac.html ; https://www.tsamoudakis.com/stop-your-downloads-folder-from-filling-up-with-zips/
- Finder views & preview pane: https://1dot.ai/blog/how-to-preview-files-on-mac-without-opening ; https://sdmactech.com/get-to-your-files-faster-by-choosing-the-best-finder-view-2/
- Finder vs Tursora (NSBrowser column view, ⌘1–4, ⇧⌘P): https://github.com/zerolfx/tursora/blob/HEAD/docs/gaps/GAP-vs-FINDER.md
- 7-Zip File Manager review: https://www.techradar.com/reviews/pc-mac/software/7-zip-review-1324265/review
- 7-Zip vs FreeCommander (dated/cluttered UI): https://www.slant.co/versus/8272/8596/~7-zip_vs_freecommander
- WinRAR vs 7-Zip (dated/cluttered): https://payments.oliverbonacini.com/blog/winrar-vs-7-zip-which-is-best-1764802493
- WinRAR interface: https://gramfile.com/winrar-windows/
- SwiftUI NavigationSplitView/Table/Inspector (macOS 14): https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/views-and-layout.md
- SwiftUI Inspector guide: https://www.createwithswift.com/presenting-an-inspector-with-swiftui/
- NavigationSplitView caveats (detail column width no-op, HSplitView/AppKit): https://github.com/yigitkonur/skill-swiftui/blob/HEAD/skills/build-macos-swiftui/references/navigation-and-toolbars.md
- SwiftUI performance — Table 10k+/50k+, LazyVGrid limits: https://github.com/laughingjackalope/macos-skills/blob/HEAD/swiftui-macos-performance/SKILL.md
- SwiftUI performance — Table/List virtualization: https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/performance-and-shipping.md
- Virtual scrolling 100k rows — List vs NSTableView measurements: https://rockxy.io/blog/virtual-scrolling-swiftui
- Column view / NSBrowser (no SwiftUI equivalent): https://namethatui.com/macos/column-view
- QuickLook in SwiftUI (`.quickLookPreview`, QLPreviewController): https://apple-docs.everest.mt/docs/wwdc/wwdc2023-10085/
- SwiftUI drag & drop has no file promises (FB13583826): https://wadetregaskis.com/tags/transferable/
- macOS Tahoe vs Sequoia (Liquid Glass, Clear/Tinted 26.1): https://macos-tahoe.com/blog/macos-tahoe-vs-sequoia-complete-comparison-2025/ ; https://www.theodorehq.com/solace/blog/posts/macos-tahoe-dark-mode-guide
- Selection/focus bug reports on macOS 26/27 (SwiftUI List/Table): https://mjtsai.com/blog/2026/10/20/selection-and-focus-in-golden-gate/

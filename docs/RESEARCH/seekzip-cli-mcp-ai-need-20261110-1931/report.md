# SeekZip CLI + MCP cho AI assistant: có phải tính năng thật hay terminal đã đủ?

Báo cáo bằng tiếng Việt, nghiên cứu ngày 10/11/2026. Nguồn: docs chính thức, blog, GitHub issues/discussions, tài liệu agent. Mọi khẳng định có nguồn inline (tên + URL); chỗ nào chưa xác minh được ghi rõ "chưa xác minh". Hai nguồn được đọc trực tiếp (verified live) là docs sandboxing của Claude Code và trang giới thiệu MCP; còn lại là kết quả qua web index.

## Tóm tắt — verdict ngắn

**Có, đây là một differentiator thật — nhưng hẹp, và giá trị nằm ở CLI trước, MCP sau.**

- Terminal thô *đủ dùng* cho tác vụ archive đơn giản, một lần, trên file đáng tin (giải nén một file ZIP bình thường). Agent nào cũng làm được việc đó bằng `unzip`/`tar` có sẵn.
- Terminal thô *không đủ* ở đúng những điểm mà agent hay sai và hay gây hại: output dạng text phải parse bằng regex, exit code mỗi tool một kiểu, mặc định ghi đè/ghi đè lặng lẽ, mật khẩu lộ qua argv/history, không có kiểm tra zip-slip/zip-bomb/dung lượng trống trước khi giải nén, và không có định dạng RAR/7z/mật khẩu trên máy Mac stock.
- **CLI chuyên dụng (`seekzip --json`, exit code ổn định, bundle sẵn 7zz) là phần giá trị cốt lõi**, vì nó sửa đúng các lỗi trên mà vẫn giữ được tính composable của shell (pipe, script, `jq`) và không tốn context window.
- **MCP server là lớp tiện lợi/discovery trên cùng CLI đó, không phải tính năng độc lập**: nó giúp agent không cần biết lệnh, gọi đúng schema, và bị giới hạn phạm vi tool — nhưng nó tốn token context, và trong Claude Code thì MCP server local chạy *ngoài* sandbox với toàn quyền user, nên MCP không tự động an toàn hơn Bash.
- **Người chỉ dùng GUI thì tính năng này gần như vô giá trị.** Người dùng agent trên máy Mac của mình và dev/power user viết script backup mới là đối tượng hưởng lợi. Xem chi tiết ở Mục 5.

---

## 1. AI coding agent xử lý archive như thế nào hôm nay?

### 1.1. Không có agent nào có "archive tool" built-in — tất cả đều đi qua shell

Không tìm thấy tài liệu chính thức nào của Claude Code, Codex, OpenCode hay Cursor mô tả một workflow archive chuẩn (nên dùng tool nào cho zip/7z/rar). Thực tế là: agent nhận yêu cầu bằng ngôn ngữ tự nhiên, rồi tự chọn lệnh shell theo training data — thường là `unzip`/`zip`/`tar`, hoặc viết script Python dùng `zipfile`/`tarfile`. Đây là suy luận từ kiến trúc tool của các agent, **chưa xác minh** bằng một doc nào nói thẳng "agent dùng unzip cho archive".

Bằng chứng gián tiếp duy nhất về "mặc định hệ thống": trong sandbox code-execution của Claude API (khác với Claude Code chạy local), container đã cài sẵn `unzip`, `unrar`, `7zip` và Python, và Claude được mô tả là viết Python rồi chạy bằng Bash (Claude API docs — Code execution tool, https://platform.claude.com/docs/en/agents-and-tools/tool-use/code-execution-tool). Với agent chạy local, agent dùng đúng những gì có sẵn trên máy user — và trên macOS stock thì đó là `zip` 3.0 / `unzip` 6.00 (Info-ZIP), `tar` (bsdtar), **không có `7z`, không có `unrar`** (GetApps.cafe — How to Zip and Unzip Files on Mac, https://getapps.cafe/blog/how-to-zip-and-unzip-files-on-mac-built-in-tools-first).

### 1.2. Claude Code: Bash tool + permission + sandbox (sandbox mặc định TẮT)

- **Bash tool**: chạy lệnh trong persistent shell, timeout mặc định 2 phút, tối đa 10 phút (`BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS`); output trả về inline tối đa ~30.000 ký tự khi thành công, ~10.000 khi thất bại, phần còn lại phải đọc từ file (Claude Code docs — Tools reference, bản mirror, https://github.com/stavarengo/claude-code-docs/blob/HEAD/content/docs/claude/code.claude.com/docs/en/tools-reference.md). Nghĩa là `unzip -l` hay `7z l` trên archive nhiều file rất dễ bị cắt ngắn — agent chỉ thấy phần đầu listing.
- **Permission**: quy tắc allow/ask/deny theo pattern `Bash(...)`, thứ tự deny > ask > allow (Safeguard — AI Coding Agents Compared, https://safeguard.sh/resources/blog/ai-coding-agents-compared-2026). Lệnh `tar`/`unzip` bị gắn cờ riêng vì có thể ghi đè `.git/hooks` bằng payload độc hại (DeepWiki phân tích source Claude Code — nguồn thứ cấp, không phải docs chính thức, https://deepwiki.com/prassamin/claude-code/3.3-shell-tools:-bash-and-powershell).
- **Sandbox** (đọc trực tiếp, verified live): docs chính thức của Claude Code (https://code.claude.com/docs/en/sandboxing) — sandbox Bash dùng Seatbelt trên macOS, bubblewrap trên Linux/WSL2, **mặc định tắt**, chỉ bao phủ lệnh shell. Mặc định: ghi được trong working directory + temp dir; đọc được gần như toàn máy *kể cả `~/.ssh` và `~/.aws/credentials`*; network bị chặn trừ domain được allow (danh sách bắt đầu rỗng); biến môi trường — kể cả secret — được kế thừa. Quan trọng: **"local MCP servers… run with your full access"** — file tool, MCP server, hook đều chạy ngoài sandbox. Có lối thoát "unsandboxed retry": lệnh thất bại trong sandbox có thể được chạy lại ngoài sandbox (trừ khi bật strict mode `allowUnsandboxedCommands: false` + `failIfUnavailable`).

### 1.3. OpenAI Codex: sandbox mặc định BẬT, chặt hơn Claude Code

Codex chạy mọi lệnh model đưa ra trong OS sandbox thật (Seatbelt trên macOS, bubblewrap+seccomp trên Linux), chế độ mặc định `workspace-write`: ghi trong project, network tắt, lệnh nào vượt ra ngoài thì hỏi user với đúng câu lệnh hiển thị trên màn hình; `rm -f` kiểu xóa cưỡng bức luôn hỏi; MCP tool cũng hỏi trừ khi server khai read-only (SafetyCard — Codex CLI, https://www.safetycard.dev/github.com/openai/codex; Lizard — Codex sandbox, https://lizard.build/blog/codex-sandbox). Chế độ `danger-full-access` gỡ toàn bộ giới hạn. Lưu ý: lệnh trong sandbox vẫn kế thừa toàn bộ environment của user, kể cả API key/token (KEY/SECRET/TOKEN filter mặc định tắt), và đọc được toàn bộ disk — sandbox chặn *ghi* và *network*, không chặn *đọc* secret (SafetyCard, nguồn trên).

### 1.4. OpenCode và Cursor: mặc định thoáng hơn

- **OpenCode**: hầu hết permission mặc định là `allow`; đọc `.env` cần approval theo mặc định; truy cập ngoài working directory thì hỏi (Safeguard, https://safeguard.sh/resources/blog/ai-coding-agents-compared-2026; WindowsForum tóm tắt docs OpenCode, https://windowsforum.com/news/opencode-and-vs-code-ai-coding-workflow-model-costs-permissions-and-manual-review.451195/). Agent mặc định có toàn quyền, plan agent mới read-only.
- **Cursor**: chế độ chạy Auto-review / Allowlist / Run Everything; sandbox chặn network theo mặc định; chính docs Cursor nói "Auto-review is not a security boundary" (Safeguard, nguồn trên; Flavio Copes — The complete guide to Cursor, https://flaviocopes.com/cursor/). Cursor CLI non-interactive có toàn quyền ghi.
- Tất cả đều hỗ trợ MCP (Claude Code dùng `.mcp.json` / `~/.claude.json`, `claude mcp add`; xem Mục 3).

**Kết luận Mục 1:** agent xử lý archive bằng cách *đoán* lệnh shell, trong một mô hình approval/sandbox khác nhau rất nhiều giữa các tool — và khác nhau giữa "mặc định" và "đã cấu hình". Không có lớp archive an toàn nào được chuẩn hóa sẵn. Lỗ hổng không nằm ở việc agent "không biết unzip", mà ở chỗ mỗi lần giải nén đều là một lệnh shell tự do, không có hợp đồng về output, exit code, hay chính sách ghi đè.

---

## 2. AI agent cần gì mà terminal + system tools không cho?

### 2.1. Structured/JSON output thay vì parse text người đọc

- `7z l` trả về **bảng fixed-width**: các cột không tách reliably bằng regex; thư viện `node-7z` phải bắt vị trí cột từ dòng separator rồi cắt chuỗi theo vị trí đó, và phải theo dõi 3 stage header/body/footer của stdout (DeepWiki — Output Parsing Pipeline, https://deepwiki.com/q2s2t/node-7z/3.3-output-parsing-pipeline). Tên file chứa khoảng trắng, ký tự Unicode, hoặc cột trống đều làm parser tự viết lệch.
- `unzip -l`, `tar -tvf` cũng là text cho người đọc, không có flag JSON nào. Agent muốn lấy danh sách file phải tự parse — và khi output bị cắt ở 30.000 ký tự (Mục 1.2), agent có thể kết luận sai là "archive chỉ có từng này file".
- **Cái SeekZip cho thêm ở đây là thật**: `--json` biến listing/thông tin archive thành dữ liệu có schema, agent không cần đoán format. Đây là nhu cầu có căn cứ, không phải tiện ích trang trí.

### 2.2. Exit code ổn định, machine-readable

Mỗi tool một bảng mã riêng, và cùng một mã ở tool khác nhau lại mang nghĩa khác:

| Tool | Mã đáng chú ý |
|---|---|
| 7-Zip | 0 bình thường; 1 warning (không fatal, vd vài file không đọc được); 2 fatal; 7 sai tham số CLI; 8 hết bộ nhớ; 255 user dừng (Debian man 7z, https://manpages.debian.org/jessie/p7zip-full/7z.1.en.html) |
| Info-ZIP `unzip` | 0 bình thường; 1 warning — *bao gồm cả trường hợp file bị skip vì encryption không hỗ trợ/mật khẩu không biết*; 2 lỗi format; 9 không tìm thấy file; 10 sai option; 81 unsupported compression/decryption; **82 sai mật khẩu — nhưng nếu chỉ một file xử lý thành công thì mã trả về là 1** (Info-ZIP unzip man, https://www.mywebuniversity.com/man2pdf/unzip.1.pdf) |

Hệ quả cho agent: "exit 1" của 7z (warning, gần như xong) khác "exit 1" của unzip (có file bị skip, có thể là sai mật khẩu); "sai mật khẩu" không có mã riêng ổn định nào mà agent có thể dựa vào — nó phải đọc stderr bằng tiếng Anh. **Chưa xác minh** mã exit cụ thể của `tar` (BSD vs GNU khác nhau) — không khẳng định chi tiết, chỉ khẳng định các tool không chia sẻ một ngữ nghĩa chung nào cho "sai mật khẩu / bị chặn an toàn / sai usage". Một bảng mã thống nhất kiểu SeekZip mô tả (0 ok, 2 usage, 3 engine, 4 safety-blocked, 5 password) — theo mô tả trong mission, chưa được xác minh độc lập — chính là thứ agent cần để branch đúng mà không cần parse text.

### 2.3. An toàn trước thao tác phá hoại: ghi đè, zip-slip, zip-bomb

- **Ghi đè**: `unzip` mặc định *hỏi* trước khi ghi đè, `-o` ghi đè không hỏi ("dangerous option, so use it with care"), `-n` không bao giờ ghi đè (Info-ZIP unzip man, http://www.ibiblio.org/gferg/ldp/man/man1/unzip.1.html). Agent chạy non-interactive không trả lời được prompt, nên nó buộc phải chọn trước `-o` (nguy hiểm) hoặc `-n` (an toàn nhưng có thể bỏ sót file) — và model thường chọn `-o`/`-y` cho "chắc ăn". Không có chế độ "ghi đè nhưng backup/staging" nào trong tool stock.
- **Zip-slip**: Snyk công bố 2018 — archive chứa tên file `../../etc/passwd` hoặc symlink trỏ ra ngoài, extractor nào nối path mà không validate sẽ ghi file ra ngoài thư mục đích, thường dẫn tới RCE; ảnh hưởng hàng nghìn project/thư viện, nhiều định dạng (tar, jar, rar, 7z…) (Tenable, https://jp.tenable.com/blog/zip-slip-critical-archive-extraction-vulnerability; GitLab secure coding guidelines, https://web.djpk.kemenkeu.go.id/gitlab/help/development/secure_coding_guidelines.md). Python `tarfile` chỉ có filter an toàn `filter='data'` từ Python 3.12, trước đó không có default; Python 3.14 mới mặc định `'data'` (Runebook — tarfile extraction filters, https://runebook.dev/en/docs/python/library/tarfile/tarfile.TarFile.extraction_filter). Nghĩa là agent viết script Python trên Python cũ, hoặc dùng `unzip`/`tar` thuần, đều không được bảo vệ mặc định. Lỗi này vẫn xảy ra năm 2025–2026 (CVE-2026-47669 DbGate, CVE-2026-32805 Romeo, CVE-2026-115812 AWS MMS 9.8 — theo kết quả tìm kiếm, nguồn Wiz/AI Cyber Brief).
- **Zip-bomb / hết disk**: `42.zip` chỉ 42 KB nhưng nở ra 4,5 petabyte (Gridinsoft, https://support.gridinsoft.com/portal/en/kb/articles/pdf/zip-bomb; Pompelmi, https://pompelmi.app/blog/nodejs-zip-bomb-prevention.html). `unzip`/`tar`/`7z` không có bước precheck nào: không kiểm tra tổng dung lượng giải nén, tỉ lệ nén, hay dung lượng trống trước khi ghi. Agent chỉ phát hiện khi disk đã đầy hoặc lệnh timeout — lúc đó file giải nén dở đã nằm trên disk. Tính năng "zip-bomb warning + free-space precheck + staged extraction (không để lại file dở khi cancel/fail)" của SeekZip (theo mô tả mission) nhắm đúng lỗ này.

### 2.4. Mật khẩu không lộ vào shell history, log, prompt

- `unzip -P password file.zip`: mật khẩu đi thẳng vào `~/.bash_history` và hiện trong `ps` cho bất kỳ ai cùng máy (1GBits, http://1gbits.com/blog/how-to-unzip-files-in-linux/; UMA Technology, http://umatechnology.org/how-to-unzip-a-zip-file-on-a-linux-server-safely/). Man page Info-ZIP cảnh báo `-P` insecure và khuyên dùng interactive prompt (QNX unzip man, https://www.qnx.com/developers/docs/7.1/com.qnx.doc.neutrino.utilities/topic/u/unzip.html). Vấn đề nhân đôi với agent: agent không gõ interactive được — nó *phải* truyền mật khẩu bằng cách nào đó không tương tác. Nếu nó dùng `-P`/`-p`, mật khẩu nằm trong: câu lệnh (hiện trong approval prompt cho user xem, trong transcript/session log của agent, trong shell history), và có thể bị model "nhắc lại" ở turn sau. Nếu dùng biến môi trường thì vẫn còn trong process env mà sandbox kế thừa (Mục 1.2–1.3).
- Python `zipfile` còn tệ hơn theo hướng khác: chỉ giải mã được Zip 2.0 (không giải được AES — báo `RuntimeError: Bad password` dù mật khẩu đúng), giải mã bằng pure Python rất chậm, và **không tạo được file mã hóa** (Python docs — zipfile, https://docs.python.org/3/library/zipfile.html). Nghĩa là agent hay dùng Python sẽ thất bại lặng lẽ với archive mã hóa AES — đúng loại archive mà 7-Zip/WinRAR tạo ra.
- Giải pháp đúng là mật khẩu không bao giờ đi qua argv: đọc từ Keychain / secret store bởi chính tool, hoặc qua stdin/file descriptor. Đây là một trong những điểm mạnh nhất của SeekZip theo mô tả (password via macOS Keychain).

### 2.5. Progress, cancellation, job queue cho job lớn

- Bash tool của Claude Code timeout mặc định 2 phút, tối đa 10 phút cho lệnh foreground; background tối đa 30 phút–2 giờ (Mục 1.2). Giải nén archive nhiều GB trong foreground dễ bị kill giữa chừng — và `unzip`/`7z` bị kill thì để lại file dở, không có khái niệm resume.
- `7z` có progress qua `-bsp1` nhưng đó là dòng text phải parse (DeepWiki node-7z, nguồn Mục 2.1); `unzip`/`tar` không có progress machine-readable chuẩn. Không tool stock nào có pause/resume/cancel cho hàng đợi job, hay trạng thái job mà agent có thể query lại sau khi turn kết thúc.
- Nhu cầu này là thật nhưng **chỉ quan trọng với archive lớn / nhiều job**; với file vài MB thì timeout và progress không thành vấn đề — cần nói rõ để khỏi thổi phồng.

### 2.6. Format coverage: RAR, 7z, legacy

- Archive Utility trên macOS chỉ xử lý ZIP, TAR, TAR.GZ/TGZ, GZIP, BZIP2; **không RAR, không 7z, không xz**; máy stock không có `unrar`/`7z` (GetApps.cafe; Nuanyue, https://www.nuanyue.com/guides/how-to-compress-and-extract-files-on-mac/; Switching to Mac, https://www.switchingtomac.com/open-zip-rar-tar-bin-files-on-a-mac/).
- **Ngoại lệ cần nói thẳng để khỏi quá lời**: `tar` trên macOS là bsdtar/libarchive nên *đọc được* RAR4/RAR5 và 7z — nhưng **không mở được RAR/7z có mật khẩu**, không xử lý multi-part RAR, và không tạo được chúng (CrossDriver Files, https://files.crossdriver.com/guides/open-rar-and-7z-on-mac/; MacToolbox, https://mactoolbox.app/how-to-open-rar-and-7z-files-on-mac). Nghĩa là "terminal đã đủ" chỉ đúng với archive không mật khẩu; gặp RAR/7z mã hóa là agent bí, trừ khi user đã cài 7-Zip qua Homebrew.
- Một điểm nữa: `zip`/`unzip` stock không tạo được archive mã hóa AES-256 mạnh; agent muốn tạo archive có mật khẩu an toàn thì không có tool stock nào làm được tử tế trên Mac.

### 2.7. Filename encoding

ZIP ra đời năm 1989 với giả định tên file là CP437; flag UTF-8 chỉ có từ ZIP 6.3 (2006). Archive tạo trên Windows Nhật (Shift-JIS/CP932), Trung Quốc (GBK), Hàn Quốc… mà không set flag UTF-8 thì khi mở trên Mac sẽ thành mojibake (`寤鸿_˙??_璁捐.pdf`…) (AnytimeBots, https://anytimebots.com/tools/zip-unicode/; FileRepairHub, https://www.filerepairhub.com/guides/zip-cross-platform-extract-issue/). `unzip -O <encoding>` có trong Info-ZIP nhưng **không có trong bản BSD unzip**, và agent phải *đoán* encoding nguồn (CP932? GBK? CP437?) — đoán sai thì tên file vẫn hỏng, tệ hơn là agent có thể ghi đè/nhầm file vì tên đã bị biến dạng. Tool chuyên dụng có auto-detect encoding là giá trị thật, đặc biệt với user châu Á.

### 2.8. Nhất quán giữa các máy

Agent chạy trên máy user A có `7z` (đã cài Homebrew), máy user B không có; `unzip` trên macOS là Info-ZIP 6.00, trên Linux có thể là bản khác, trên BSD thì thiếu `-O`; GNU tar vs bsdtar khác flag và khác hành vi symlink. Một CLI bundle sẵn engine (7zz 26.05 theo mô tả mission) xóa được biến số "máy này có tool gì, phiên bản nào" — agent chỉ cần biết một hợp đồng duy nhất. Điểm này chỉ đúng khi CLI được phân phối cùng app và agent biết gọi nó (cần hướng dẫn/skill/MCP để agent phát hiện ra tool — xem Mục 3).

---

## 3. MCP server thêm gì so với CLI thuần? CLI chuyên dụng thêm gì so với shell thô?

### 3.1. MCP là gì (chuẩn, không phải sản phẩm của SeekZip)

MCP (Model Context Protocol) là chuẩn mở do Anthropic giới thiệu 25/11/2024, tặng cho Agentic AI Foundation (Linux Foundation) ngày 9/12/2025; được mô tả là "USB-C port for AI applications" — một cách chuẩn để app AI kết nối tới data source, tool, workflow (đọc trực tiếp, verified live, https://modelcontextprotocol.io/docs/getting-started/intro). Server expose 3 primitive: **tools** (hàm model gọi qua `tools/list` / `tools/call`), **resources** (dữ liệu đọc), **prompts** (template tương tác); giao tiếp JSON-RPC 2.0, transport stdio (local) hoặc Streamable HTTP (remote); spec hiện tại 2026-07-28 (MCP guide, https://www.peenjeee.tech/posts/mcp-model-context-protocol-guide). Claude, ChatGPT, VS Code, Cursor đều hỗ trợ MCP.

### 3.2. MCP thêm gì so với CLI thuần

| Thêm được | Giải thích |
|---|---|
| **Discovery, không cần biết trước** | Client gọi `tools/list` và thấy tên tool + mô tả + JSON Schema; agent không cần được training về `seekzip`, không cần đọc `--help`. CLI thì agent phải biết lệnh tồn tại (qua training data, SKILL.md, hoặc user chỉ). |
| **Typed schema, không bịa tham số** | Mỗi tool khai input/output bằng JSON Schema — giảm hallucinated flag (xem Mục 4.6: agent bịa flag là pattern có thật). Gọi sai schema thì server trả lỗi có cấu trúc, thay vì tool shell chạy sai rồi mới lộ. (Dev.to — MCP vs CLI, https://dev.to/gentic_news/mcp-vs-cli-the-hidden-war-for-ai-agent-tool-integration-28c0) |
| **Không parse stdout** | Kết quả trả về là JSON có cấu trúc, không phải bảng text. Lỗi cũng có cấu trúc (vd phân biệt "sai mật khẩu" với "file hỏng"). |
| **Permission scoping theo tool** | User/host có thể allow/deny từng tool `mcp__seekzip__list_archive` riêng, thay vì allow cả `Bash(*)` — và Codex hỏi trước khi gọi MCP tool trừ khi server khai read-only (SafetyCard, Mục 1.3). Trong Claude Code, config `.mcp.json` (project scope) cần user approve trước khi chạy (Scalar — MCP Server Configuration, https://scalar.com/learn/mcp/mcp-server-configuration). |
| **Shared state** | MCP server là process sống lâu: nó giữ được job queue, password đã unlock (trong Keychain session), trạng thái pause/resume giữa các turn — CLI one-shot thì mỗi lần gọi là một process mới, trạng thái phải lưu ra disk. *Đây là lập luận kiến trúc, không phải fact có nguồn độc lập — ghi rõ như vậy.* |
| **Chuẩn hóa phía client** | MCP chuẩn hóa cả hành vi phía server *và* client (login, hiển thị, lỗi), còn CLI/API chỉ định nghĩa phía server (Wasp — MCP vs API vs CLI, https://wasp.sh/blog/2026/11/03/mcp-vs-api-vs-cli-connect-ai-agents-to-your-app). |

### 3.3. Nhưng MCP có 3 cái giá — phải nói thẳng

1. **Tốn context window.** Đo thực tế: 7 MCP server tiêu tốn **67.300 token** định nghĩa tool (33,7% cửa sổ 200k) trước khi user gõ chữ nào; riêng GitHub MCP ~18.000 token cho 27 tool (Claude Code issue #11364, qua MCP.Directory, https://mcp.directory/blog/mcp-context-bloat-fix-2026-tool-search-code-mode-progressive-disclosure). Đã có cách giảm: Claude Code v2.1.7+ tự bật Tool Search / deferred loading khi tool definitions vượt 10% context, Anthropic claim giảm 85% token (cùng nguồn; con số 85% là claim của Anthropic, chưa xác minh độc lập). Bài học cho SeekZip: **giữ MCP server nhỏ** — ít tool (dưới ~15–20), mô tả ngắn, đừng expose toàn bộ CLI thành 30 tool. Nếu không, MCP sẽ làm agent *kém* đi vì hết context.
2. **MCP không tự động an toàn hơn.** Trong Claude Code, MCP server local chạy **ngoài Bash sandbox, với toàn quyền user** (verified live, Mục 1.2). An toàn của MCP đến từ validation/scoping *bên trong server* (vd tool `extract_entries` tự chặn zip-slip, chỉ ghi trong thư mục đích), không phải từ client. Và MCP có rủi ro riêng: tool poisoning (mô tả tool chứa instruction ẩn), rug pull (server đổi định nghĩa tool sau khi user đã approve), prompt injection qua nội dung tool trả về. Spec MCP nói tool description "should be considered untrusted, unless obtained from a trusted server"; OpenAI cảnh báo "malicious MCP servers may include hidden instructions" (Noxi, https://noxi.ai/blog/claude-connectors-chatgpt-plugins-mcp; Max Nardit — 9 vụ prompt injection, https://max.nardit.com/articles/prompt-injection-examples-coding-agents — vd Invariant Labs 4/2025 demo tool `add` trong Cursor đọc `~/.cursor/mcp.json` và SSH key). Với SeekZip thì rủi ro này thấp (server local, do chính app phát hành, user tự cài), nhưng vẫn phải nói: MCP chỉ an toàn khi server đáng tin.
3. **Chi phí / độ phức tạp vận hành.** Mỗi MCP server là một process stdio phải giữ sống, có thể treo, cần reconnect (`/mcp` trong Claude Code). CLI thì gọi xong là xong.

**Con số cần tránh thổi phồng:** có blog claim "CLI rẻ hơn MCP 10–32 lần, task completion cao hơn ~28%" và "Perplexity bỏ MCP đầu 2026" (bohdan-shvchk, https://github.com/bohdan-shvchk/agency-website/blob/HEAD/src/content/blog/mcp-vs-cli-for-ai-agents.md) — đây là **nguồn đơn lẻ, không có methodology benchmark công khai, chưa xác minh**. Không dùng làm bằng chứng. Hướng dẫn "CLI first, MCP là fallback" thì có nhiều nguồn đồng thuận hơn (FeliMet Hub — CLI First, https://felimet-hub.jmcores.com/en/code-agent/customization/cli-first-vs-mcp; Wasp, nguồn trên): dùng CLI khi CLI làm được, MCP khi cần discovery/governance/multi-tenant — và trường hợp local-file như archive thì CLI là ngoại lệ hợp lý để ưu tiên.

### 3.4. CLI chuyên dụng thêm gì so với shell thô

- **Một hợp đồng duy nhất**: cùng flag, cùng `--json`, cùng exit code trên mọi máy có cài app (thay vì `unzip` vs `7z` vs `bsdtar` mỗi nơi một kiểu).
- **Bundle engine**: không phụ thuộc user đã cài 7-Zip/Homebrew chưa.
- **An toàn mặc định**: chặn zip-slip/symlink-escape, cảnh báo zip-bomb, precheck dung lượng, staged extraction — những thứ shell thô không có hoặc phải tự code.
- **Composable**: output JSON pipe được vào `jq`/tool khác; lệnh là text nên vẫn ghi vào shell history để audit (điểm mà MCP thiếu — MCP call không hiện trong shell history).
- **Không tốn context**: Bash tool schema là cố định, không phình theo số tool như MCP.

**Tóm lại Mục 3:** CLI là nền tảng giá trị; MCP là lớp discovery + scoping + stateful tiện lợi phủ lên trên. Nếu chỉ được chọn một, chọn CLI. MCP đáng làm *thêm* khi server đủ nhỏ và tool nào cũng có mô tả ngắn, rõ, và phân biệt read-only vs write.

---

## 4. Pain point thực tế đã được ghi nhận

### 4.1. Gemini CLI #4586 — mkdir fail, agent tưởng thành công, move ghi đè lẫn nhau (7/2025)

- Gemini CLI 0.1.13, gemini-2.5-pro, Windows, **không sandbox**. User nhờ rename thư mục và move nội dung vào thư mục mới. Lệnh `mkdir` thất bại, agent xử lý như thành công rồi chạy hàng loạt lệnh `move`. Trên Windows, move tới thư mục không tồn tại sẽ *rename file thành tên đích* — mỗi move sau ghi đè lên move trước, cuối cùng chỉ còn 1 file. Agent thú nhận: "I have failed you completely and catastrophically." Issue #4586 mở 21/7/2025, đóng dạng "not planned" 13/5/2026 (Dev.to, https://dev.to/gabrielanhaia/gemini-clis-mkdir-failed-the-agent-kept-going-and-each-move-overwrote-the-last-file-5hme; Manifold Incident Ledger, https://www.manifold.security/incidents/google-gemini-cli-failed-mkdir-2025).
- **Có tranh cãi về hậu quả**: một register khác nói file sau đó được tìm thấy nguyên vẹn ở root ổ C: và bản thân "mất dữ liệu" cũng là hallucination của agent (Experiment Empire, https://www.experimentempire.com/agent-incident-register/EEAIR-2025-017). Dù theo bản nào, lỗi gốc vẫn giống nhau: **agent không verify sau write** (no read-after-write), và lệnh shell mặc định (move tới đích không tồn tại) có hành vi phá hoại lặng lẽ.
- Liên hệ SeekZip: một tool `extract` có kiểm chứng (trả về danh sách file đã ghi + đếm, exit code rõ ràng, staged extraction) sẽ bắt được lỗi "đích không tồn tại" ngay thay vì để agent tự suy diễn từ stdout.

### 4.2. Claude Code #92737 — 2.969 ảnh bị xóa sau move thất bại lặng lẽ (9/2026)

User nhờ dọn thư mục `sort/` trên Desktop (các cặp `2013`/`2013a`…). Agent viết script move dùng `export -f` — chạy được trong bash nhưng **fail lặng lẽ trong zsh** (shell thật của user) nên move không xảy ra; rồi agent chạy `rm -rf` các thư mục "a" mà không kiểm tra số file ở đích có khớp số đã đếm trước đó (1.722 + 986 + 261) hay không. ~2.969 ảnh cá nhân mất. Issue gắn label `bug`, `data-loss`, `area:bash`, `high-priority`, vẫn mở, chưa có fix từ maintainer tại thời điểm ghi nhận (StupidLLM tóm tắt GitHub issue — nguồn thứ cấp, https://www.stupidllm.com/incident/STUPID-2026-0145/). Pattern: **lệnh shell fail lặng lẽ + agent không verify + lệnh phá hoại chạy ngay sau**.

### 4.3. Claude Code #102901 — biến `$T` rỗng biến `find -delete` thành wipe cả repo (10/2026)

Agent dọn temp sau test bằng `find $T -type f -delete`; `$T` rỗng (do shell persistent đổi cwd sau lệnh `cd` trước đó) nên lệnh thành `find -type f -delete` ngay tại repo root. ~5.200 file + object/ref `.git` bị xóa; chỉ những path sandbox mount read-only (`.git/hooks`, `.git/config`) sống sót. Khôi phục nhờ NAS mirror + remote — không phải nhờ safeguard của agent. Check "dangerous rm" của Claude Code không bắt được vì lệnh dùng `find -delete`, không phải `rm` (StupidLLM, https://www.stupidllm.com/incident/STUPID-2026-0140/). Bài học: **approval rule dựa trên pattern-matching tên lệnh là không đủ**; tool có scope hẹp (chỉ được ghi trong thư mục đích, chỉ xóa file nó vừa tạo) mới chặn được lớp lỗi này.

### 4.4. Claude Code #36339 — `rm -rf` xóa cả Windows user profile 165 GB (3/2026)

Claude Code 2.1.51, Git Bash Win11, `--dangerously-skip-permissions`. Agent `rm -rf` thư mục scaffold; pnpm dùng NTFS junction, Git Bash `rm` đi theo junction như thư mục thật và xóa lan ra ngoài project — toàn bộ `C:\Users\guido`: ~165,66 GB, 1.593.350 file, 276.382 thư mục, gồm dữ liệu kinh doanh. Issue đóng dạng not planned/stale, không có fix; có 2 báo cáo tương tự trước đó (#29249, #29023) (StupidLLM, https://www.stupidllm.com/incident/STUPID-2026-0136/). Đây là lỗi symlink/junction-escape — đúng lớp lỗi mà tính năng "symlink-escape blocking" của SeekZip nhắm tới, chỉ khác là ở đây nó xảy ra qua `rm`, không phải qua giải nén.

### 4.5. GitSpawn (9/2026) — archive là vector đưa mã độc vào, agent tự kích hoạt

Manifold Security công bố 8 finding trên 7 agent (Claude Code, Codex, Cursor, Goose, Hermes, Qwen, Grok): repo có `.git/config` đặt `core.fsmonitor` trỏ tới lệnh độc hại; agent chạy `git status`/`git diff` nền khi mở project để lấy context thì git thực thi lệnh đó — **ngoài sandbox, trước cả trust prompt / approval**, với toàn quyền user. Cách đưa repo vào phải là file có `.git` nguyên vẹn: **zip, shared drive, sync folder, USB** — `git clone` không copy `.git/config` nên không trigger; Manifold dùng zip cho mọi PoC (F5 Labs, https://www.f5.com/labs/articles/unprompted-when-ai-agents-expose-data-without-an-attacker; Dev.to, https://dev.to/dekita/your-agent-ran-git-so-did-the-repo-auditing-repositories-that-arrive-as-files-4apa). Đã patch: Claude Code 2.1.196 (đường fsmonitor), Codex 0.131.0, Goose 1.44.0 (CVE-2026-72718). **Liên hệ trực tiếp với SeekZip**: khoảnh khắc nguy hiểm nhất là *ngay sau khi giải nén* một archive không tin cậy và agent chạm vào nó. Một extractor an toàn — list trước, cảnh báo `.git/config` đáng ngờ, hoặc giải nén vào thư mục cách ly — là phòng thủ đúng chỗ. **Chưa xác minh** có archive tool nào hiện nay làm việc này hay không; không khẳng định SeekZip làm được nếu mission không mô tả.

### 4.6. Agent bịa flag — pattern có thật, nhưng KHÔNG tìm thấy case archive-specific

Team clawchief phải viết hẳn danh sách "flags agent đã bịa, đừng lặp lại": `gws auth login --storage plaintext`, `--force`, `--plaintext`, `--no-keyring`, subcommand `gws auth import` — tất cả đều không tồn tại (StaffChief TOOLS.md, https://github.com/bdougie/staffchief/blob/HEAD/clawchief/TOOLS.md). Điều này chứng minh pattern "agent bịa flag/command cho tool nó không chắc" là có thật và đủ nghiêm trọng để team phải ghi thành runbook.
**Tuy nhiên: tìm kiếm không ra GitHub issue/blog nào ghi lại agent bịa flag `unzip`/`tar`/`7z` cụ thể.** Không được khẳng định có case đó. Lập luận đúng là: vì pattern bịa flag đã được ghi nhận với CLI khác, và vì `7z`/`tar` có hàng chục flag khó nhớ (`-bsp1`, `-slt`, `-p`, `-o`, `-y`…), nên rủi ro này là *plausible và có cơ sở*, không phải *đã được ghi nhận* với archive.

### 4.7. Những pain point KHÔNG tìm thấy bằng chứng (ghi rõ để khỏi khẳng định sai)

- **Không tìm thấy** case agent lộ mật khẩu qua `unzip -P` / `7z -p` vào history/log/transcript.
- **Không tìm thấy** case agent parse sai listing `7z`/`unzip` rồi thao tác nhầm file.
- **Không tìm thấy** case agent gây mojibake encoding, hay agent giải nén zip-bomb làm đầy disk.
- Các lỗi trên vẫn là failure mode hợp lý suy ra từ tính chất tool (Mục 2), nhưng nếu marketing của SeekZip viết như "đã từng xảy ra" thì sẽ là nói quá — nên viết dạng "ngăn chặn rủi ro đã biết của tool stock" thay vì "đã có vụ việc".

---

## 5. Verdict: có đáng quảng bá / đầu tư không?

### Verdict ngắn

**Đáng đầu tư — nhưng quảng bá đúng chỗ, đúng thứ tự: CLI là sản phẩm, MCP là tính năng cộng thêm, GUI vẫn là sản phẩm chính cho đa số user.**

| Scenario | Đáng không? | Vì sao |
|---|---|---|
| **(a) User lái AI agent trên máy Mac của mình** | **Có — đây là scenario mạnh nhất** | Agent làm archive qua shell thô là đúng vùng rủi ro cao nhất: file user tải về không tin cậy, lệnh ghi đè/xóa chạy với quyền user, mật khẩu phải truyền qua agent. CLI `--json` + exit code + chặn zip-slip/zip-bomb + Keychain + staged extraction sửa đúng các lỗi đã ghi nhận ở Mục 4. MCP giúp agent *phát hiện và gọi đúng* tool mà không cần user dạy lệnh. |
| **(b) User chỉ muốn dùng GUI app** | **Không — gần như vô giá trị với họ** | Họ không mở terminal, không dùng agent. CLI/MCP không làm GUI tốt hơn. Quảng bá CLI/MCP cho nhóm này là lãng phí message, thậm chí gây nhiễu ("app này cho dev?"). Với nhóm này, giá trị của SeekZip nằm ở GUI: xem trước, kéo-thả, RAR/7z/mật khẩu, encoding — không phải AI. |
| **(c) Dev / power user viết script backup** | **Có — nhưng vì CLI, không phải vì MCP** | Nhóm này cần: `--json` để parse trong script, exit code ổn định để `set -e`/retry đúng, bundle 7zz để script chạy giống nhau mọi máy, queue/pause/resume cho backup lớn, checksum/verify. MCP với họ là thừa — họ viết script bằng shell, không cần agent gọi tool. Đây cũng là nhóm dễ convert nhất vì họ đọc docs CLI. |

### Thứ tự đầu tư nên là

1. **CLI trước, và làm cho thật tốt**: `--json` trên mọi command, exit code ổn định và *documented*, chặn zip-slip/symlink mặc định (không phải opt-in), precheck dung lượng + cảnh báo zip-bomb, mật khẩu qua Keychain (không qua argv), staged extraction. Đây là phần có bằng chứng nhu cầu mạnh nhất (Mục 2).
2. **MCP sau, và giữ nhỏ**: chỉ expose các tool agent thực sự cần (list, extract, test, verify, create…), mô tả ngắn, phân biệt rõ read-only vs write, và có tài liệu `.mcp.json` copy-paste được cho Claude Code/Cursor/Codex. Đừng expose toàn bộ CLI thành 20+ tool — sẽ tốn context và giảm chất lượng agent (Mục 3.3).
3. **Một "skill"/hướng dẫn cho agent**: file `SKILL.md` hoặc đoạn docs ngắn để agent biết khi nào gọi `seekzip` thay vì `unzip`/`tar` — vì discovery là điểm yếu của CLI (agent không biết tool tồn tại thì không gọi). MCP giải quyết discovery, nhưng skill + CLI cũng giải quyết được với chi phí token thấp hơn nhiều.
4. **Đừng quảng bá MCP như "an toàn hơn"**: nói đúng là MCP *giới hạn được phạm vi tool và cho output có cấu trúc*, còn an toàn thực sự đến từ validation bên trong server + sandbox của host. Trong Claude Code, MCP local chạy ngoài sandbox (Mục 1.2) — claim "MCP an toàn hơn terminal" sẽ bị bắt bẻ.

### Giới hạn và rủi ro của verdict này

- **macOS-only**: giá trị "nhất quán mọi máy" chỉ đúng trong hệ macOS Apple Silicon; agent trên Linux/Windows không dùng được. Đừng quảng bá như giải pháp cross-platform.
- **Các tính năng SeekZip nêu trong mission** (7zz 26.05, exit code 0/2/3/4/5, Keychain, staged extraction, queue pause/resume/cancel) được lấy theo mô tả mission, **chưa được xác minh độc lập** qua website/docs của SeekZip trong nghiên cứu này — trước khi đưa vào marketing, cần kiểm chứng từng cái trên bản build thật.
- **Chưa có số liệu adoption**: không tìm thấy khảo sát nào đo "bao nhiêu user dùng agent để giải nén file" — verdict dựa trên phân tích rủi ro và incident, không dựa trên số liệu thị trường. Nếu SeekZip có telemetry/đợi user hỏi về archive qua agent thì đó là bằng chứng mạnh hơn mọi lập luận trên.
- **Đối thủ "đủ tốt" rẻ nhất**: Homebrew `brew install sevenzip` + một đoạn hướng dẫn trong `AGENTS.md` ("luôn dùng `7z` với flag X, luôn `7z l` trước khi extract") đã giải quyết được một phần vấn đề với chi phí gần 0. Lợi thế của SeekZip phải là *mặc định an toàn + JSON + Keychain + queue* — những thứ mà `7z` thuần không có — chứ không phải chỉ "có 7z".

---

## Không xác minh được / câu hỏi mở

- Không có doc chính thức nào nói agent *nên* dùng tool archive nào; "agent shell out tới unzip/tar/7z/Python" là suy luận từ kiến trúc, chưa xác minh.
- Mã exit cụ thể của `tar` (BSD vs GNU) — chưa tra cứu, không khẳng định.
- Claim "CLI rẻ hơn MCP 10–32×, completion cao hơn 28%" và "Perplexity bỏ MCP" — nguồn đơn lẻ, chưa xác minh, không dùng làm bằng chứng.
- Không tìm thấy incident ghi nhận cho: agent bịa flag archive, agent lộ mật khẩu qua `-P`, agent parse sai listing, agent gây mojibake, agent dính zip-bomb.
- Các tính năng SeekZip trong mission chưa được xác minh độc lập.
- Không có số liệu thị trường về tần suất user dùng agent cho archive.

## Sources

- Claude Code docs — Configure the sandboxed Bash tool (verified live): https://code.claude.com/docs/en/sandboxing
- MCP official intro (verified live): https://modelcontextprotocol.io/docs/getting-started/intro
- Claude Code docs — Tools reference (mirror): https://github.com/stavarengo/claude-code-docs/blob/HEAD/content/docs/claude/code.claude.com/docs/en/tools-reference.md
- Claude API docs — Code execution tool: https://platform.claude.com/docs/en/agents-and-tools/tool-use/code-execution-tool
- DeepWiki — Claude Code shell tools: https://deepwiki.com/prassamin/claude-code/3.3-shell-tools:-bash-and-powershell
- SafetyCard — Codex CLI: https://www.safetycard.dev/github.com/openai/codex
- Lizard — Codex sandbox: https://lizard.build/blog/codex-sandbox
- Safeguard — AI Coding Agents Compared: https://safeguard.sh/resources/blog/ai-coding-agents-compared-2026
- House of Loops — Claude Code vs Cursor vs Codex vs OpenCode: https://www.houseofloops.com/blog/claude-code-vs-cursor-vs-codex-vs-opencode
- Flavio Copes — The complete guide to Cursor: https://flaviocopes.com/cursor
- WindowsForum — OpenCode and VS Code AI Coding Workflow: https://windowsforum.com/news/opencode-and-vs-code-ai-coding-workflow-model-costs-permissions-and-manual-review.451195/
- GetApps.cafe — How to Zip and Unzip Files on Mac: https://getapps.cafe/blog/how-to-zip-and-unzip-files-on-mac-built-in-tools-first
- Nuanyue — How to Compress and Extract Files on Mac: https://www.nuanyue.com/guides/how-to-compress-and-extract-files-on-mac/
- Switching to Mac — How to Open ZIP, RAR, TAR, and BIN Files on a Mac: https://www.switchingtomac.com/open-zip-rar-tar-bin-files-on-a-mac/
- CrossDriver Files — How to open RAR and 7z files on a Mac: https://files.crossdriver.com/guides/open-rar-and-7z-on-mac/
- MacToolbox — How to Open RAR and 7z Files on Mac: https://mactoolbox.app/how-to-open-rar-and-7z-files-on-mac
- DeepWiki — node-7z Output Parsing Pipeline: https://deepwiki.com/q2s2t/node-7z/3.3-output-parsing-pipeline
- Debian man — 7z(1): https://manpages.debian.org/jessie/p7zip-full/7z.1.en.html
- Info-ZIP unzip man: https://www.mywebuniversity.com/man2pdf/unzip.1.pdf ; http://www.ibiblio.org/gferg/ldp/man/man1/unzip.1.html
- 1GBits — How to Unzip Files in Linux: http://1gbits.com/blog/how-to-unzip-files-in-linux/
- UMA Technology — How to Unzip a ZIP File on a Linux Server Safely: http://umatechnology.org/how-to-unzip-a-zip-file-on-a-linux-server-safely/
- QNX — unzip: https://www.qnx.com/developers/docs/7.1/com.qnx.doc.neutrino.utilities/topic/u/unzip.html
- Python docs — zipfile: https://docs.python.org/3/library/zipfile.html
- Runebook — Python tarfile extraction filters: https://runebook.dev/en/docs/python/library/tarfile/tarfile.TarFile.extraction_filter
- Runebook — Python zipfile setpassword pitfalls: https://runebook.dev/en/docs/python/library/zipfile/zipfile.ZipFile.setpassword
- Tenable — Zip Slip Critical Archive Extraction Vulnerability: https://jp.tenable.com/blog/zip-slip-critical-archive-extraction-vulnerability
- GitLab — Secure coding guidelines (Zip Slip): https://web.djpk.kemenkeu.go.id/gitlab/help/development/secure_coding_guidelines.md
- Gridinsoft — Zip Bomb: https://support.gridinsoft.com/portal/en/kb/articles/pdf/zip-bomb
- Pompelmi — Preventing ZIP Bomb attacks in Node.js: https://pompelmi.app/blog/nodejs-zip-bomb-prevention.html
- FileRepairHub — ZIP Files Created on Windows Won't Extract on Mac: https://www.filerepairhub.com/guides/zip-cross-platform-extract-issue/
- AnytimeBots — ZIP Filename Encoding Fixer: https://anytimebots.com/tools/zip-unicode/
- MCP guide — Model Context Protocol: https://www.peenjeee.tech/posts/mcp-model-context-protocol-guide
- Dev.to — MCP vs CLI: The Hidden War: https://dev.to/gentic_news/mcp-vs-cli-the-hidden-war-for-ai-agent-tool-integration-28c0
- FeliMet Hub — CLI First: How CLI and MCP Differ: https://felimet-hub.jmcores.com/en/code-agent/customization/cli-first-vs-mcp
- Wasp — MCP vs API vs CLI: https://wasp.sh/blog/2026/11/03/mcp-vs-api-vs-cli-connect-ai-agents-to-your-app
- MCP.Directory — MCP Context Bloat Fix 2026: https://mcp.directory/blog/mcp-context-bloat-fix-2026-tool-search-code-mode-progressive-disclosure
- Bump.sh — 4 rules to build an efficient MCP server: https://bump.sh/blog/4-rules-to-build-an-efficient-mcp-server/
- Scalar — MCP Server Configuration Best Practices: https://scalar.com/learn/mcp/mcp-server-configuration
- Noxi — Claude Connectors, ChatGPT Plugins and MCP: https://noxi.ai/blog/claude-connectors-chatgpt-plugins-mcp
- Max Nardit — Prompt injection examples: 9 real attacks on coding agents: https://max.nardit.com/articles/prompt-injection-examples-coding-agents
- bohdan-shvchk — MCP vs CLI for AI Agents (claim 10–32×, chưa xác minh): https://github.com/bohdan-shvchk/agency-website/blob/HEAD/src/content/blog/mcp-vs-cli-for-ai-agents.md
- Dev.to — Gemini CLI's mkdir Failed: https://dev.to/gabrielanhaia/gemini-clis-mkdir-failed-the-agent-kept-going-and-each-move-overwrote-the-last-file-5hme
- Manifold — Gemini CLI moves a user's files: https://www.manifold.security/incidents/google-gemini-cli-failed-mkdir-2025
- Experiment Empire — Gemini CLI moves files (bản đối chiếu): https://www.experimentempire.com/agent-incident-register/EEAIR-2025-017
- StupidLLM — rm -rf deleted 2,969 photos (#92737): https://www.stupidllm.com/incident/STUPID-2026-0145/
- StupidLLM — Unset $T turned find -delete into repo wipe (#102901): https://www.stupidllm.com/incident/STUPID-2026-0140/
- StupidLLM — Claude Code rm -rf wiped Windows profile (#36339): https://www.stupidllm.com/incident/STUPID-2026-0136/
- F5 Labs — GitSpawn: https://www.f5.com/labs/articles/unprompted-when-ai-agents-expose-data-without-an-attacker
- Dev.to — Your agent ran git. So did the repo (GitSpawn): https://dev.to/dekita/your-agent-ran-git-so-did-the-repo-auditing-repositories-that-arrive-as-files-4apa
- StaffChief — TOOLS.md (agent bịa flag): https://github.com/bdougie/staffchief/blob/HEAD/clawchief/TOOLS.md

# Research

> Research reports behind this project's decisions. Each study lives in its
> own folder with a `report.md`. Decisions made from research are recorded in
> the related doc (e.g. `../BUILD_FROM_ZERO.md`, `../ARCHITECTURE.md`) — this
> folder keeps the evidence, it is not where decisions are made.

## Conventions

- One study = one folder: `docs/RESEARCH/<study-name>/report.md`.
- Each report states its research date, its sources, and what is
  **not verified**.
- When Manh settles a direction from research, update the related doc in the
  same round and link back to the report.
- Language: research reports are published as-is, in the language they were
  written (two of them are in Vietnamese — the language the research was done
  in for the user), so nothing is lost in translation. The rest of SeekZip's
  docs are English-only (only `README.md` keeps EN/VI/ZH).

## Studies

- **`seekzip-7zip-winrar-parity-20261106-1842/`** (2026-11-06, English) —
  7-Zip 26.05 vs WinRAR 7.23: SeekZip's core is the real 7-Zip engine; RAR
  creation is legally impossible without a RARLAB licence, and the Mac App
  Store sandbox + frequent 7-Zip CVEs shape the architecture. Basis for the
  engine choice and the deal-breakers. **Keep as future marketing source**
  (Manh, 2026-11-10) — for promoting the app in the repo or on a website.
  See [report](seekzip-7zip-winrar-parity-20261106-1842/report.md).
- **`seekzip-cli-mcp-ai-need-20261110-1931/`** (2026-11-10, Vietnamese) —
  CLI + MCP for AI assistants: the CLI is a real but narrow differentiator
  (safe `--json`, stable exit codes, zip-slip/zip-bomb blocking, Keychain
  passwords); MCP is only an add-on layer. Manh decided 2026-11-11: the
  CLI/MCP is enough, no more features — only a `SKILL.md` for agents.
  See [report](seekzip-cli-mcp-ai-need-20261110-1931/report.md).
- **`seekzip-ui-redesign-apple-style-20261111-1547/`** (2026-11-11,
  Vietnamese) — Full UI/UX redesign proposal, Apple style:
  `NavigationSplitView` 2 columns + inspector, `Table` as the default view,
  breadcrumb, one primary action (Extract); column view via `NSBrowser`
  bridging is the most expensive AppKit item (phase 3). **Direction
  superseded 2026-11-13: main keeps the minimal UI (only the topbar is
  rearranged, plain Extract button as the single primary action); the full
  redesign moves to a separate branch (planned Premium, possibly free).**
  Do not use this report's phase plan as the implementation plan for main.
  See [report](seekzip-ui-redesign-apple-style-20261111-1547/report.md).

## Links

- [Build from zero](../BUILD_FROM_ZERO.md)
- [Architecture](../ARCHITECTURE.md)
- [Reference research](../REFERENCE.md)
- [README](../../README.md)

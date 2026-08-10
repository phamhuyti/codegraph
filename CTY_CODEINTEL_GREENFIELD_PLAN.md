# Plan: Xây `@cty/codeintel` từ zero (greenfield)

> Tài liệu này dành cho **AI nội bộ** làm việc trên máy công ty.
> Mục tiêu: tự dựng hệ thống code-intelligence local (ý tưởng tương đương CodeGraph) **không fork, không copy, không phụ thuộc** repo `codegraph` bên ngoài.
> Policy: **không dùng nguồn ngoài** khi build/chạy (không GitHub, npmjs công khai, telemetry, CDN). Chỉ Git nội bộ + npm registry/mirror nội bộ + Node đã approve.

---

## 1. Định nghĩa sản phẩm (Definition of Done)

Tạo package CLI + MCP server tên **`@cty/codeintel`** (đổi scope cho đúng org nội bộ nếu cần) sao cho:

1. `codeintel init` — tạo `.codeintel/` và index toàn bộ repo vào SQLite local.
2. `codeintel serve --mcp` — MCP stdio; AI nội bộ gọi được tool.
3. Tool chính **`explore`** — trả source verbatim + call path + blast radius ngắn.
4. `codeintel install` — ghi config MCP cho agent nội bộ (bắt đầu với **một** client, ví dụ Cursor).
5. `codeintel sync` / watcher — cập nhật index khi file đổi (MVP có thể chỉ sync tay + git hook).
6. **Zero outbound network** lúc runtime: không telemetry, không update-check, không download grammar lúc chạy.
7. MVP ngôn ngữ: **TypeScript/JavaScript** trước. Thêm ngôn ngữ khác sau khi pilot OK.

### Không làm trong MVP

- 20+ ngôn ngữ cùng lúc
- Synthesizer dynamic-dispatch (React setState→render, callback heuristic phức tạp)
- Rust native kernel
- Telemetry / waitlist / upgrade từ GitHub
- Installer đủ mọi IDE (chỉ 1 agent trước)

---

## 2. Ràng buộc policy (bắt buộc)

| Hạng mục | Quy tắc |
|---|---|
| Source | Chỉ Git nội bộ |
| npm | Chỉ registry/mirror nội bộ; hoặc `npm ci --offline` với `node_modules` đã vendor |
| Node | Version công ty approve — **khuyến nghị Node 22.x** (cần `node:sqlite`, tốt nhất ≥ 22.5) |
| Runtime network | Cấm `fetch`/HTTP ra ngoài; CI phải fail nếu phát hiện URL ngoài allowlist |
| Secrets | Không index / không trả nội dung `.env`, key material; chặn root nhạy cảm |
| Path safety | Mọi đọc file phải nằm trong project root (chống `../` và symlink escape) |

---

## 3. Kiến trúc mục tiêu

```
files on disk
    → Walker (.gitignore + default excludes)
    → Extractor (TypeScript compiler API ở MVP)
    → SQLite (.codeintel/graph.db): files / nodes / edges
    → Resolver (imports → cross-file calls)
    → Graph queries (search, callers, callees, impact BFS)
    → MCP tool `explore` (budgeted verbatim source + flow)
    → AI nội bộ (Cursor / agent MCP)
```

### Schema SQLite tối thiểu

```sql
-- Điều chỉnh tên cột cho nhất quán trong code; đây là contract MVP.

CREATE TABLE files (
  path        TEXT PRIMARY KEY,
  language    TEXT NOT NULL,
  hash        TEXT NOT NULL,
  mtime_ms    INTEGER NOT NULL,
  size        INTEGER NOT NULL
);

CREATE TABLE nodes (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL,      -- file|class|function|method|interface|variable|import|...
  name        TEXT NOT NULL,
  file_path   TEXT NOT NULL,
  start_line  INTEGER NOT NULL,
  end_line    INTEGER NOT NULL,
  signature   TEXT,
  FOREIGN KEY (file_path) REFERENCES files(path)
);

CREATE TABLE edges (
  src_id      TEXT NOT NULL,
  dst_id      TEXT NOT NULL,
  kind        TEXT NOT NULL,      -- contains|calls|imports|extends|implements|references
  PRIMARY KEY (src_id, dst_id, kind)
);

CREATE INDEX idx_nodes_name ON nodes(name);
CREATE INDEX idx_nodes_file ON nodes(file_path);
CREATE INDEX idx_edges_src ON edges(src_id);
CREATE INDEX idx_edges_dst ON edges(dst_id);
```

Optional sau MVP: FTS5 trên `name` + `signature`.

---

## 4. Cấu trúc repo (tạo mới trên Git nội bộ)

```
codeintel/
  package.json                 # name: @cty/codeintel, bin: codeintel
  tsconfig.json
  .npmrc                       # registry=https://npm.cty.local/  (điền đúng URL nội bộ)
  .nvmrc                       # 22
  README.md
  docs/INTERNAL_INSTALL.md
  src/
    bin/codeintel.ts           # CLI entry
    db/
      schema.sql
      connection.ts
    index/
      walker.ts
      hasher.ts
      orchestrator.ts          # init / index / sync
    extract/
      types.ts
      typescript.ts            # MVP
    resolve/
      imports.ts
      calls.ts
    graph/
      search.ts
      callers.ts
      impact.ts
      pathfind.ts
    mcp/
      server.ts
      transport-stdio.ts
      tools.ts                 # explore + status
      instructions.ts          # text hướng dẫn agent lúc initialize
    installer/
      cursor.ts                # MVP: chỉ Cursor (hoặc đúng client cty dùng)
    security/
      paths.ts                 # validatePathWithinRoot, deny sensitive roots
    util/
      ignore.ts
  fixtures/
    tiny-ts/                   # repo giả lập để test end-to-end
  __tests__/
  scripts/
    ci-no-outbound.sh          # fail nếu có URL ngoài allowlist
```

---

## 5. Lộ trình triển khai theo phase

Làm **đúng thứ tự**. Mỗi phase phải có test xanh trước khi sang phase sau.

---

### Phase 0 — Bootstrap repo (0.5 ngày)

**Việc**

1. Tạo repo trống trên Git nội bộ: `codeintel`.
2. `package.json`: `@cty/codeintel`, `"type"`/`main`/`bin` phù hợp, `engines.node: ">=22.5 <25"`.
3. TypeScript + vitest (hoặc test runner đã có trên mirror).
4. CI nội bộ: `npm ci` → `npm test` → `npm run build` (registry nội bộ).
5. File `.npmrc` trỏ registry nội bộ.
6. `docs/INTERNAL_INSTALL.md` skeleton.

**Done khi:** `npm run build` chạy offline/mirror; CI xanh với test giả `expect(true)`.

---

### Phase 1 — CLI + MCP xương sống (1–2 ngày)

**CLI commands**

- `codeintel --version`
- `codeintel status` (chưa có index → báo rõ)
- `codeintel serve --mcp`

**MCP**

- Handshake `initialize` + `tools/list` + `tools/call`
- Tool `codeintel_status` (hoặc `status`): trả `{ indexed: false }` / stats

**Installer MVP**

- `codeintel install` ghi config MCP cho **một** agent (ví dụ Cursor `~/.cursor/mcp.json`):
  - `command`: `codeintel`
  - `args`: `["serve", "--mcp"]`
- Idempotent (chạy lại không hỏng config user).
- Không hỏi telemetry; không mở URL ngoài.

**Done khi:** Agent nội bộ thấy tool `status` và gọi thành công.

**Test:** spawn server stdio (hoặc unit transport), gọi list/call.

---

### Phase 2 — Index files → SQLite (2–3 ngày)

**Walker**

- Đi từ project root.
- Honor `.gitignore` (root + nested nếu làm được dễ).
- Default exclude: `node_modules`, `dist`, `build`, `.git`, `.codeintel`, coverage, venv, v.v.
- Bỏ file > 1MB.
- Chỉ index extension MVP: `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`.

**DB**

- Tạo `.codeintel/graph.db` (+ schema).
- Bảng `files` với hash nội dung (sha256) + mtime.

**Commands**

- `codeintel init` = tạo dir + full index
- `codeintel index` = full reindex
- `codeintel status` = số file, path db, thời điểm index

**Security**

- `validateProjectPath`: từ chối `/`, `/etc`, `~/.ssh`, `~/.aws`, …
- Mọi đọc file qua `validatePathWithinRoot`.

**Done khi:** Chạy `init` trên `fixtures/tiny-ts` → `files` đủ và `status` đúng.

---

### Phase 3 — Extract symbols TypeScript (3–5 ngày)

**Cách làm (MVP):** dùng package `typescript` từ mirror nội bộ (compiler API), **không** tree-sitter đa ngôn ngữ lúc này.

**Extract**

- `class`, `interface`, `type alias`, `function`, `method`, `enum` (nếu dễ)
- Lưu `start_line` / `end_line` / `signature` ngắn
- Edge `contains` (file→symbol, class→method)

**Same-file calls (best-effort)**

- Trong thân function, tìm call expression → edge `calls` nếu resolve được symbol cùng file

**Test fixtures**

```
fixtures/tiny-ts/
  src/auth/login.ts      # login(), gọi validate()
  src/auth/validate.ts
  src/app.ts             # import login
```

**Done khi:** Search theo tên `login` ra đúng file:line; có edge contains/calls trong cùng file.

---

### Phase 4 — Resolve cross-file (3–5 ngày)

1. Parse `import` / `export`.
2. Resolve specifier → file trong repo (relative path; hỗ trợ `tsconfig` `paths` nếu không quá khó).
3. Edge `imports` (file→file hoặc symbol→file).
4. Cross-file `calls` khi callee là binding import.

**Chưa làm:** dynamic `import()`, re-export phức tạp, monorepo workspace phức tạp (để phase sau).

**Done khi:** “callers của `validate`” gồm `login`; từ `app.ts` truy được path tới `validate`.

---

### Phase 5 — Tool `explore` (3–5 ngày)

**Input**

- `query` (string): tên symbol, file, hoặc câu hỏi ngắn chứa identifier
- Optional: `projectPath` (absolute) để trỏ repo khác trong monorepo

**Thuật toán MVP**

1. Tokenize query → candidate symbol names / file names.
2. Search nodes theo tên (exact rồi fuzzy/prefix).
3. Nếu ≥2 symbol “neo” → tìm path BFS trên edge `calls`/`imports` (giới hạn depth).
4. Tập file liên quan: symbols chọn + neighbors 1 hop.
5. Trả về:
   - Section **Flow** (nếu có path)
   - Section **Source**: mỗi file một block line-numbered (`<n>\t<line>`), chỉ đoạn symbol (hoặc cửa sổ quanh symbol), có **budget** (vd. max 8 files, max N chars/file)
   - Section **Impact**: top callers

**Quy tắc UX cho agent**

- Coi source đã trả = đã Read; **không** bảo agent “hãy dùng Read” cho đúng file đó.
- Chưa index → response success + hướng dẫn `codeintel init` (tránh `isError` làm agent bỏ tool).
- File ngoài root → refuse.

**Done khi:** Trên `fixtures/tiny-ts`, query `"login validate"` trả flow + source đủ để trả lời không cần đọc thêm file.

---

### Phase 6 — Sync (2–3 ngày)

**MVP chấp nhận được (chọn một)**

- **A (đơn giản, dễ security review):** `codeintel sync` + git `post-commit` / `post-merge` hook optional.
- **B:** `fs.watch` debounce 1–2s → rehash → re-extract file đổi/xóa.

Khi serve MCP: trước query có thể chạy sync nhẹ (mtime/hash) cho file sắp trả.

**Done khi:** Sửa `login.ts` → sync → explore thấy dòng mới.

---

### Phase 7 — Policy hardening + đóng gói (2 ngày)

1. Script CI `scripts/ci-no-outbound.sh`:
   - Fail nếu source khớp domain cấm: `github.com`, `npmjs.org`, `nodejs.org`, `getcodegraph.com`, `telemetry.`, v.v. (trừ allowlist comment/`docs` nếu cần).
2. Không module telemetry.
3. `codeintel upgrade` (nếu có) chỉ in: cài lại từ npm nội bộ — không download.
4. `npm pack` → publish `@cty/codeintel` lên registry nội bộ.
5. Hoàn thiện `docs/INTERNAL_INSTALL.md`.

**Done khi:** Máy chỉ LAN nội bộ cài được qua npm nội bộ; khi chạy init/explore không có request ra ngoài.

---

### Phase 8 — Pilot nội bộ (1 tuần)

1. Chọn 2–3 service TypeScript thật của cty.
2. Đo: thời gian index, chất lượng explore trên 5 câu hỏi cố định.
3. Thu feedback agent (có còn Grep/Read nhiều không).
4. Mới xét thêm ngôn ngữ (Python/Go) — lặp Phase 3–4 cho ngôn ngữ đó.

---

## 6. Hợp đồng CLI (MVP)

| Lệnh | Hành vi |
|---|---|
| `codeintel init [path]` | Tạo `.codeintel/` + full index |
| `codeintel index [path]` | Full reindex |
| `codeintel sync [path]` | Incremental theo hash/mtime |
| `codeintel status [path]` | Stats + đường dẫn DB |
| `codeintel serve --mcp` | MCP stdio |
| `codeintel install` | Ghi MCP config agent nội bộ |
| `codeintel uninstall` | Gỡ MCP config đã ghi |

Directory data: `.codeintel/` (gitignore trong project user — document cho team).

---

## 7. Hợp đồng MCP tools (MVP)

### `explore` (primary)

- `query`: string (bắt buộc)
- `projectPath`: string optional

Trả text markdown ổn định, có section rõ: Flow / Source / Impact.

### `status` (secondary)

- Index có/không, số files/nodes/edges, path.

(Có thể giữ `search` nội bộ cho CLI; không cần expose nhiều tool cho agent ở MVP.)

---

## 8. `docs/INTERNAL_INSTALL.md` (nội dung cần viết)

```markdown
# Cài @cty/codeintel (nội bộ)

## Yêu cầu
- Node >= 22.5 (portal phần mềm cty)
- Truy cập npm registry nội bộ

## Cài
npm i -g @cty/codeintel --registry=https://npm.cty.local/

## Gắn AI
codeintel install

## Index một repo
cd /path/to/service
codeintel init

## Dùng
Hỏi AI nội bộ như bình thường (flow, symbol, impact).
Agent sẽ gọi MCP explore.

## Upgrade
npm i -g @cty/codeintel@latest --registry=https://npm.cty.local/
# Không dùng cơ chế download ngoài.

## Gỡ
codeintel uninstall
npm uninstall -g @cty/codeintel
```

---

## 9. Tiêu chí nghiệm thu (UAT)

| # | Test | Pass |
|---|---|---|
| 1 | `npm i -g` từ registry nội bộ trên máy không internet ngoài | OK |
| 2 | `codeintel init` trên service TS | `.codeintel/` + status > 0 nodes |
| 3 | Agent gọi `explore` cho flow 2–3 symbol | Có Flow + Source |
| 4 | Proxy/firewall log lúc init + explore | 0 kết nối ra ngoài |
| 5 | Path traversal / symlink ra ngoài root | Bị từ chối |
| 6 | Chưa `init` | Hướng dẫn init, không crash agent |
| 7 | `install` chạy 2 lần | Idempotent |

---

## 10. Prompt tổng để AI nội bộ bắt đầu

Copy nguyên khối này khi khởi tạo session AI trên repo trống:

```
Bạn đang làm việc trong mạng công ty, policy cấm nguồn ngoài.

Nhiệm vụ: tạo greenfield project `@cty/codeintel` — local code intelligence cho AI agent qua MCP.
Không được clone/fork/copy từ repo codegraph bên ngoài. Tự thiết kế và implement.

Ràng buộc kỹ thuật:
- Node >= 22.5, TypeScript, SQLite qua node:sqlite
- Zero outbound network lúc runtime
- npm chỉ dùng registry nội bộ (xem .npmrc)
- MVP chỉ TypeScript/JavaScript
- Một MCP tool chính: explore
- Installer chỉ hỗ trợ một agent (Cursor mcp.json) trước

Làm theo đúng phase trong file PLAN.md (Phase 0 → 7):
mỗi phase có test, commit riêng, không nhảy cóc.
Bắt đầu Phase 0: scaffold package.json, tsconfig, vitest, CI, README, docs/INTERNAL_INSTALL.md skeleton.
Sau mỗi phase, in checklist Done khi và chờ xác nhận nếu cần.
```

---

## 11. Gợi ý thứ tự commit

1. `chore: scaffold @cty/codeintel`
2. `feat: CLI + MCP status skeleton`
3. `feat: SQLite schema + file indexer`
4. `feat: TypeScript symbol extraction`
5. `feat: import/call resolution`
6. `feat: MCP explore tool`
7. `feat: sync + cursor installer`
8. `chore: outbound CI guard + internal install docs`
9. `release: npm pack publish internal`

---

## 12. Rủi ro & cách tránh

| Rủi ro | Cách tránh |
|---|---|
| Scope phình (đa ngôn ngữ sớm) | Khóa MVP TS; ngôn ngữ 2 chỉ sau pilot |
| Agent bỏ MCP vì lỗi ầm ĩ | “Chưa index” = success + guidance |
| Dính dependency kéo network lúc runtime | Không dùng lib phone-home; CI quét URL |
| Node cũ trên máy user | Document engines; fail fast với message rõ |
| Index chậm repo lớn | Bỏ qua node_modules; incremental sync; đo từ pilot |

---

## 13. Kết quả bàn giao

Khi hoàn thành Phase 7–8, bàn giao:

1. Repo Git nội bộ `@cty/codeintel`
2. Package trên npm registry nội bộ
3. `docs/INTERNAL_INSTALL.md`
4. Bộ câu hỏi UAT + kết quả pilot 2–3 service
5. Backlog ngôn ngữ/framework tiếp theo (có ưu tiên)

---

*Hết plan. AI nội bộ: bắt đầu Phase 0 trên repo trống.*

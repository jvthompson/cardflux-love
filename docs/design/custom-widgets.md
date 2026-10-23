# Custom Lua Widget System — Architecture & Security Design

> Status: design only, not yet scheduled for implementation. See the appendix for a suggested
> phasing if/when this is picked up.

## Context

Cardflux's only "widget" today is a hardcoded `simpleCounter` enum value (`src/core/models.lua`'s closed `ZoneWidgetKind`/`BoardWidgetKind` enums), rendered by `if kind == "simpleCounter"` branches in `src/ui/table/table_view.lua`. There's no extension point, and — more importantly — the project has **never executed third-party code anywhere**: `gamedef.json` and all game content is pure data, verified only by SHA-256 content-addressing.

The goal is standalone Lua files that sit in a `widgets/` folder inside a game definition, authored like any other game-def asset, and runnable both by the authoritative server (a separate Go process embedding **gopher-lua**) and inside a client-hosted (peer-to-peer) game (LÖVE 11.5, confirmed **LuaJIT** via active FFI usage elsewhere in the client). This is a genuine dual-runtime problem: the same widget logic must execute identically on two different Lua implementations.

Three binding decisions were made before designing this (not re-litigated below):

1. **Scope: full logic + visuals.** Widgets can both render custom UI and define rule-affecting behavior that runs authoritatively.
2. **Trust model: peer-shared, no vetting.** Any player can author/distribute widget code with zero review gate — the design must assume active malicious intent from widget authors.
3. **Deliverable: design doc only.** No implementation is being scheduled by this pass; a brief phasing appendix is included but implementation is a separate, later effort.

### Confirmed grounding facts

- **Client runtime is LuaJIT** (`conf.lua` pins LÖVE `11.5`; FFI is used non-optionally in `src/data/fs.lua`, `src/data/pdf_render.lua`, `src/platform/discord.lua`, `src/platform/winhttp.lua`).
- **Server runtime is gopher-lua**, one `*lua.LState` per room (`server/internal/engine/engine.go`), currently opened with **full stdlib, no restriction** (confirmed: no `SkipOpenLibs`/`OpenLibs` calls anywhere in `server/`) — because today it only ever runs trusted, vendored code. A widget sandbox must build its own restriction from scratch; it cannot assume the room VM is already safe.
- **The action-intent dispatch pipeline already exists and is the right seam.** `src/game/host_engine.lua`'s `E:handleMessage` validates ownership and forwards into `src/game/session.lua` → `src/core/table_actions.lua` (pure `TableState -> TableState` functions, e.g. `A.setWidgetValue`, already clamped via `util.clamp` against `boardWidgetCounterMin/Max`). Widget logic must gain **no new mutation power** — only the ability to request these same (or a few new, identically-validated) primitives.
- **State filtering already exists and is the right seam for render-side privacy.** `src/core/state_filter.lua`'s `filterForRecipient` strips hidden/private zone data before a state reaches a given recipient. Widget render code must only ever see this filtered view.
- **A seeded, deterministic RNG convention already exists**: `src/core/util.lua`'s `util.seededRng(seed)` (Park-Miller LCG, pure arithmetic), already used by `table_actions.reshuffle`/`shuffleZone`. Confirmed present via grep. This is the natural primitive to expose to widget logic instead of `math.random`.
- **Content distribution is already SHA-256, per-file, content-addressed, and extension-agnostic.** `server/internal/games/games.go` walks the whole game folder generically; `src/net/asset_sync.lua` diffs against a local manifest and only pulls changed files. Widget `.lua` files need **no new distribution protocol** — they ride the existing pipeline. Zip-slip/path-traversal/size checks already exist both directions.
- **The vendored-engine sync (`server/tools/sync-engine.ps1`) is a separate, narrower mechanism than content distribution.** It copies *trusted framework code* (`src/core/*.lua`, `src/game/{session,host_engine}.lua`) into the Go binary via a closed `require` shim that can't reach arbitrary files. The widget **sandbox/loader module itself** is trusted framework code (belongs under `src/core/`, gets vendored the same way); the widget `.lua` **content** a game definition ships is untrusted data that travels through the content manifest pipeline instead. These must not be conflated.
- **The only existing dynamic-load precedent is dev-only and deliberately not a sandbox.** `src/app.lua`'s test harness uses `load(code, chunkname, "t", setmetatable({App=App}, {__index=_G}))` — the `__index=_G` fallthrough is the opposite of what a real sandbox needs (it hands back every global). It does confirm LuaJIT's 4-arg `load(code, chunkname, mode, env)` form works in this codebase; the policy (no `_G` fallthrough, explicit whitelist) must be built fresh.

---

## 1. Widget packaging & manifest

### File layout

```
game_library/<gameId>/
  gamedef.json
  widgets/
    simple_counter/
      widget.json       -- manifest/metadata
      logic.lua          -- optional; omitted => no custom rule behavior
      render.lua          -- optional; omitted => generic fallback renderer
    tap_tracker/
      widget.json
      logic.lua
      render.lua
```

Each subfolder is a reusable **widget definition** (a type, analogous to a `CardDefinition`), referenced by id from `gamedef.json`'s zone/board-widget entries — the same way content currently references `widgetKind = "counter"`.

### Extending the closed enum into an open registry

Keep `ZoneWidgetKind`/`BoardWidgetKind` exactly as-is for built-ins (zero risk to existing content). Add a parallel, open path:

- `ZoneDefinition.widgetKind` gains an accepted form like `"custom:<widgetDefId>"` (or a sibling `customWidgetId` field), validated not against a static enum but against "does `<gameDef>/widgets/<widgetDefId>/widget.json` exist in this loaded game" — resolved by `game_loader.lua` at load time (not by `models.lua`, which has no filesystem access and shouldn't gain any).
- `BoardWidgetInstance` gets a `customWidgetId` field (nil for built-ins); when set, it bypasses `BoardWidgetKind` validation, checked instead against the loaded `GameDefinition`'s custom-widget registry (`GameDefinition.customWidgetById`, built/cached like `cardById`).

### `widget.json` schema

```json
{
  "id": "tap_tracker",
  "displayName": "Tap Tracker",
  "version": 1,
  "capabilities": {
    "render": true,
    "logic": true,
    "actions": ["setWidgetValue"]
  },
  "params": {
    "startingValue": { "type": "number", "default": 0, "min": 0, "max": 99999 },
    "label": { "type": "string", "default": "", "maxLength": 32 }
  },
  "budget": {
    "logicInstructionsPerCall": 50000,
    "renderInstructionsPerFrame": 20000
  }
}
```

`capabilities.actions` is a declared, closed allow-list — used both for the trust-prompt UX (§8) and as a runtime-enforced check (defense in depth; the dispatcher rejects any action not in this list even if `logic.lua` tries it). `params` are plain data, clamped the same way `counterStartingValue` is today — configurability with no code path.

### Loading

`game_loader.lua` scans `widgets/*/widget.json` after loading `gamedef.json` and builds the registry. **No `.lua` file is executed at load time** — `logic.lua`/`render.lua` are only ever handed to the sandboxed loader (§3) lazily, the first time a session the user has already consented to (§8) actually places/renders that widget type.

---

## 2. Widget contract split: render vs. logic

Two disjoint contracts, enforced structurally by *which process is even capable of loading which file* — not just by convention, since the threat model assumes active malice.

**Render contract (`render.lua`)** — presentation only, runs only inside a LÖVE client:
- Receives exactly the already-`state_filter`-filtered view for the current viewer, plus the specific widget instance and its resolved params. Never the true `TableState`, never another player's hidden data.
- Draws via a small curated API (`drawRect`, `drawText`, `drawImage(assetId, ...)`, `drawLine`) that proxies `love.graphics.*` with validated/clamped arguments and asset ids resolved only through the already-synced, hash-verified asset set (`image_resolver.lua`). **Never raw `love.*`** — that surface includes things like `love.graphics.newShader` (arbitrary GPU shader code) and filesystem-adjacent calls.
- Runs every frame for visible instances (cheap/frequent call class).
- **Cannot call any action primitive.** If a widget needs a "+" button, it draws the button; the existing input/hit-testing layer (already turns clicks into `requestX` messages for the built-in counter) turns the click into a declared action request — render code never holds a reference to the dispatch function at all.

**Logic contract (`logic.lua`)** — rule-affecting, runs only inside whichever party is authoritative for the session (peer-host's client, or the Go server's room VM). A non-host client never executes `logic.lua`.
- Receives the true, unfiltered state slice relevant to the instance plus the incoming action-intent payload. Can only **return a decision/transform** (`logic.onAction(ctx, actionName, payload) -> {accept, patch}`), never mutate state directly.
- A new chokepoint module, `src/core/widget_actions.lua`, is the *only* code holding real `table_actions.lua` mutator references. It consults `logic.lua`'s decision, re-checks it against the manifest's declared `capabilities.actions` allow-list, and feeds the result through the same clamping/ownership validation every built-in action already goes through (`util.clamp`, `allowedWidget`/`movableWidget` in `host_engine.lua`). Widget logic is one more layer of clamping, never a bypass of it.
- Called once per relevant action request (expensive-but-rare call class, larger instruction budget than render).

This split is enforced by construction: the server process never loads `render.lua` at all (no graphics module exists to misuse even if tried); the client's render path's sandbox env contains no reference to `host_engine`/`session`/`table_actions`/any dispatch function; the logic sandbox env contains read-only accessors plus action-*request* functions, never the real mutators.

---

## 3. Sandbox design (both runtimes)

### Client — LuaJIT

Load every widget chunk as:
```lua
local chunk, err = load(sourceCode, "=widget:"..widgetId..":logic", "t", sandboxEnv)
```
`sandboxEnv` is a **fresh plain table with no metatable** — critically *not* `{__index=_G}` (any fallthrough to `_G` hands back every global, defeating the sandbox by construction). It contains only:
- Restricted `math` (full copy, minus `random`/`randomseed` — replaced by the host RNG handle, §5), restricted `string` (full copy minus `string.dump`, which can serialize bytecode and inspect host closures), full `table` (safe since widgets only ever get *copies* of host data, never live references), and the safe base subset: `tostring`, `tonumber`, `type`, `pairs`, `ipairs`, `select`, `unpack`, `error`, `assert`, `pcall`, `xpcall`.
- **Explicitly absent, not merely nil'd:** `io`, `os` (including `time`/`clock` — banned for determinism, §5), `love` (the whole module), `debug` (the single most dangerous library — upvalue/metatable access, `sethook`, stack introspection), `package`/`require`/`dofile`/`loadfile`, `load`/`loadstring` (a widget must never be able to create a new chunk with an attacker-chosen environment), `collectgarbage` (DoS + info-leak side channel — the *host* polices memory, never the widget), `getmetatable`/`setmetatable`/`rawget`/`rawset`/`rawequal`/`rawlen` (metatable-escape vectors), `_G`/`_ENV` (nothing points back to the real global table), `coroutine` (can evade naive per-thread instruction hooks — omitted for v1), `setfenv`/`getfenv`, and LuaJIT-specific `ffi`/`jit.*`/`bit` (FFI is a total sandbox breaker — raw memory access, arbitrary C calls).

**Known Lua sandbox-escape classes and closures:**
1. *String-literal → shared metatable → `string` table → `_G` pivot* (classic Lua escape: `getmetatable("").__index` is the real `string` table process-wide). Closed by never exposing `getmetatable`, plus defense-in-depth: install the host's own restricted table as `getmetatable("").__index` process-wide at startup, so even `s:gsub()` method-call sugar resolves against the restricted table.
2. *Coroutines bypassing instruction hooks* (a hook armed on the main thread doesn't automatically apply to a new coroutine in either LuaJIT or gopher-lua) — closed by omitting `coroutine` entirely for v1.
3. *`rawget`/`rawset` reaching through a read-only proxy* — avoided by never handing widgets proxy objects; they always get plain deep copies of relevant state (small, bounded cost — one instance's fields plus a declared read-set, not the whole table).
4. *Self-recursive `load`* — closed by omitting `load`/`loadstring`/`dofile`/`loadfile` entirely.

### Server — gopher-lua

Today's room VM opens full stdlib with no restriction (confirmed). **Recommended approach:** a dedicated `*lua.LState` per room, built with `SkipOpenLibs: true`, into which only an explicit whitelist is manually registered — hand-built to mirror the client's whitelist function-for-function, so behavior is symmetric by construction rather than hoped-for. (Rejected alternative: sharing the trusted engine's own `LState` with a swapped-in restricted global table — gopher-lua's 5.1-style fenv handling has rough edges, and a successful escape or adversarial-input panic would take down the whole room's trusted state, not just the widget call. Containing blast radius matters more here than client-side, where the "blast radius" is already just that one peer's own machine.)

- One widget-logic `LState` per room, reused across calls, but fully `Close()`'d and rebuilt if a call ever trips the circuit breaker (§4) — a wedged/corrupted state never persists into the next call.
- `installRequire`'s closed-`require`-over-embedded-files pattern is **not** reused for widget code — widget `logic.lua` gets no module system at all, since even a closed `require` pointed at the vendored engine would hand it access to `table_actions.lua`'s real mutators.
- **Open parity items** (flag, don't block): gopher-lua has known historical divergences from LuaJIT in numeric formatting/parsing corner cases (`string.format`, float-to-string) — the conformance suite (§9) must specifically fuzz these. Neither runtime has native bitwise ops in Lua 5.1; if any widget needs them, the host must provide one shared implementation used by both, not assume parity for free.

---

## 4. Resource limiting

| Call class | Frequency | Budget style |
|---|---|---|
| Render | per-frame, per visible instance | small instruction budget, near-zero tolerance for overage (must not threaten 60fps) |
| Logic | per action-intent | larger budget, can tolerate occasional slowness off the render hot path |

- **Client:** `debug.sethook(thread, hookFn, "", instructionCount)` — a count-hook fires every N VM instructions regardless of *how* CPU is being burned (loop, recursion, metamethod storm), which is what makes it robust against clever burn techniques rather than just catching `while true do end`. The hook raises a Lua error, caught by a `pcall`/`xpcall` wrapper that unconditionally surrounds every widget call — never call widget code outside this wrapper. Manifest-declared budgets (`widget.json`'s `budget.*`) are a *ceiling request*, clamped to a host-wide hard maximum, never an unchecked grant.
- **Server:** gopher-lua supports context-deadline cancellation and its own hook mechanism; use **both** — an instruction-count hook for parity with the client's enforcement semantics (so "budget exceeded" means the same thing on both runtimes, needed for §9's conformance testing), plus a wall-clock `context.WithTimeout` backstop so a pathological script can never starve a room's single goroutine indefinitely even if it finds a gap between hook checks.
- **Memory:** periodic `collectgarbage("count")` sampling (host-side only, never exposed to the widget) as a delta around widget call batches; growth past a tunable threshold is treated as a budget violation under the same circuit-breaker path. Server-side, a full `LState.Close()` on circuit-break fully reclaims memory — an advantage over the client, which shares one long-lived `LState` with the whole session and can't be torn down cheaply, so client-side mitigation leans more on tighter caps up front.
- **Circuit breaker:** every call wrapped in `pcall`/`xpcall` unconditionally, funneled through one small dispatcher (`src/core/widget_sandbox.lua`, mirrored server-side) rather than scattered raw calls. N consecutive failures (budget violation, Lua error, non-conforming return shape) within a short window → disable that instance, render a neutral "widget disabled" placeholder (never silently drop it — see §8), no automatic retry (prevents flapping from burning the budget check itself every frame). A quarantined widget's logic failing is treated as "reject this action" — the same path `host_engine.lua` already takes for an ordinary validation failure — never propagated as an exception into `session.lua`.

---

## 5. Determinism requirements

Logic must agree across LuaJIT and gopher-lua (and, for the peer-hosted case, preserve the *existing* single-host-authority trust boundary rather than inventing a new cross-verification requirement):

- **No wall-clock reads** (`os.time`/`os.clock`) — already unreachable (`os` denied), called out since it's the single most common accidental-nondeterminism source.
- **No unseeded RNG** — `math.random`/`randomseed` omitted; replaced by a host-issued `ctx.random(n)` built on the already-existing `util.seededRng(seed)` (pure arithmetic, no stdlib dependency — should be straightforward to keep byte-identical across runtimes, but this must be *tested*, not assumed). The host derives the seed deterministically from already-agreed state (e.g. a state revision counter plus the action's own fields) — never from wall-clock or per-process entropy — so the widget only ever consumes host-issued draws, never seeds its own.
- **No reliance on `pairs()` order** — differs between implementations by design (different hash functions/table layouts). Any host-supplied collection a widget needs to iterate in order (e.g. "cards in this zone") is passed as an **array** (`ipairs`-iterable, host-sorted by a stable key such as `zIndex`/`instanceId`, mirroring `table_actions.lua`'s existing `sortedByZ` pattern), not as a hash table. `pairs` can stay available for a widget's own locally-constructed tables, where order doesn't matter to anything else.
- **No cross-call persistent widget-local state.** Each call gets a *fresh* sandbox env (cheap — small table construction, not a VM rebuild) — there is nothing to persist in a Lua-level closure/upvalue even if an author tried. Anything that needs to persist must be written back through the declared action/patch mechanism into `BoardWidgetInstance` fields, which *are* part of the synchronized, filtered, broadcast `TableState`.

---

## 6. Distribution & integrity (peer-shared, no-vetting model)

No new transport mechanism is needed — the existing SHA-256 content-addressed pipeline already generalizes, since both `games.go`'s manifest builder and `asset_sync.lua`'s diff logic walk/hash files generically with no extension filter. Widget `.lua`/`widget.json` files are just more entries in a list already hashed and synced. The one gap: the **peer-hosted** transport (a joining peer receiving the host's `gameData` push in `host_engine.lua`'s `onRoster`) needs the same per-file hash manifest extended to the widgets folder, so a joining peer can verify it received byte-identical widget files to what the host is running — a small protocol extension to an existing message, not a new system.

**Why hash-pinning matters most for the render contract specifically:** logic authority is already concentrated in one party (the host, or the dedicated server) by existing design — every other participant already just accepts and renders that party's resulting state deltas, widgets or not. What widgets add is a *new* property that must hold across every participant for an unrelated reason: if peer A and peer B somehow loaded different bytes for `render.lua` (a compromised relay, a stale cache), they could render the *same* authoritative state in inconsistent or exploitable ways — e.g. one peer's screen shows a counter's true value while a tampered copy always shows zero, letting that peer bluff with information everyone else's screen contradicts. Hash-pinning render code across all participants before the game is allowed to start closes this code-distribution integrity gap without inventing any new "trust the host more" mechanism. Hash-pinning `logic.lua` is still worth doing (so a reconnecting client can verify nothing changed mid-session) but is secondary, since logic execution is already single-sourced from the authoritative party.

---

## 7. Information-flow / anti-cheat properties

The three required guarantees map onto the structural seams above, not onto new runtime checks:

- **(a) No leak of hidden state:** `render.lua` is only ever invoked with the recipient-specific, already-filtered view — there is no code path where unfiltered data is even constructed for a render call. Same property built-in widgets already have today.
- **(b) No corruption beyond declared action-intents:** `logic.lua` never holds a reference to any `table_actions.lua` mutator — only `widget_actions.lua` does. A widget declaring `actions: ["setWidgetValue"]` cannot cause a card move or another widget's deletion; those aren't in its declared, runtime-rechecked allow-list.
- **(c) No peer desync:** covered by §5, backed by the §9 conformance harness that verifies agreement rather than assuming the ban-list is sufficient.
- **(d) No cross-widget interference:** each call's sandbox env is freshly constructed per call with only that instance's own declared data in scope — no shared mutable table across instances or widget types to use as a covert channel.

---

## 8. User-facing trust signaling

Since there's no vetting step, an explicit per-gamedef consent gate is needed the first time a client is about to *execute* (not just download) widget code it hasn't approved, modeled on a browser-extension permission prompt:

- **Trigger:** first load of any `logic.lua`/`render.lua` for a given `(gameId, manifestHash)` not previously approved — covers installing a game def with a `widgets/` folder, joining a peer-hosted game whose host pushes one, and a dedicated server offering one for download.
- **Prompt content:** a plain-language summary derived from the manifest's declared capabilities ("includes N custom widgets; widget code can: run custom logic for `<zones>`; draw custom visuals"), with a technical-details disclosure showing widget ids/version, the `capabilities.actions` allow-list verbatim, and the SHA-256 of each file — letting a technical user verify/diff without the project needing a signing service. Explicit, unavoidable framing: "Custom widgets are created by other players and are not reviewed. Only install games from people/servers you trust." This is honest informed consent given the actual trust model, not a security control.
- **Decision storage:** per `(gameId, manifestHash)` — **Allow** (re-prompts automatically if the hash ever changes, which is what makes §6's hash-pinning meaningful to the user) or **Deny**. No persistent "ask every time" mode (degrades to allow-fatigue, the well-known failure mode of that pattern) — a changed hash always re-prompts instead.
- **Revisiting:** a settings surface listing every gamedef ever Allowed/Denied, with hash + approval date and one-click revoke.
- **Peer-hosted specifics:** keyed on manifest hash, not display name — a malicious host can't trade on a familiar game name to get an unearned Allow for different code.
- This is consent/transparency, **not** a substitute for the sandbox or resource limits — a user who clicks Allow is still fully protected by containment regardless of what they agreed to; the prompt's job is making sure they know they're running someone else's code, not vetting whether it's safe.

---

## 9. Testing / verification strategy

Two distinct goals:

**Adversarial sandbox-hold tests** — a fixed corpus of hostile widget scripts run against both sandbox constructions, asserting *containment* (no crash, no escape, no hang) rather than any particular output: infinite loops (iterative and recursive, to confirm the hook fires under both), huge allocations (`string.rep` bombs, unbounded table growth), each escape class from §3 (string-metatable pivot, `setfenv` on a passed-in function, `require`/`load`/`dofile`/`debug.*`/`os.execute`/`io.open`/`collectgarbage` attempts — all should fail as plain "attempt to call nil"), malformed `logic.onAction` return shapes, and repeated-failure quarantine behavior. Extends `tests/runner.lua` client-side with a new `tests/widget_sandbox_test.lua`, and a new `server/internal/engine/widget_sandbox_test.go` server-side, both consuming the same shared `.lua` fixture corpus (not reimplemented per-language).

**Cross-runtime conformance** — since `logic.lua` must agree between LuaJIT and gopher-lua, build a shared fixture set (`tests/fixtures/widgets/`: widget script + action-intent sequence + expected output, JSON) consumed by both a client-side runner and a server-side Go test, asserting byte-identical (or documented-equivalent, for the float-formatting edge cases flagged in §3) results. This is the direct Lua-runtime analogue of what `sync-engine.ps1` already does for rules-engine *files* — except the property verified here is *behavioral* agreement between two different implementations, not textual identity. Give the RNG specifically dedicated fixture coverage: a fixed-seed `ctx.random(n)` sequence must match exactly on both runtimes — foundational to §5's determinism story and must be tested, not assumed.

---

## 10. Concrete files to change / add

**Core model & data (client, vendored to server via `sync-engine.ps1`):**
- `src/core/models.lua` — custom-widget-id fields on `ZoneDefinition`/`BoardWidgetInstance`; `GameDefinition.customWidgetById` registry. Built-in enums unchanged.
- `src/core/table_actions.lua` — unchanged behavior; may gain a few new widget-scoped primitives, added the same validated/clamped way as existing ones.
- New `src/core/widget_actions.lua` — the chokepoint dispatcher (§2/§7): holds real `table_actions.lua` references, consults sandboxed `logic.lua` decisions, enforces the `capabilities.actions` allow-list.
- New `src/core/widget_sandbox.lua` — sandbox construction (§3): restricted env table, instruction-count hook, memory-ceiling checks, `pcall`/circuit-breaker wrapper. Structure it so the Go port can mirror it function-for-function.

**Game loading & content (client):**
- `src/data/game_loader.lua` — scan `widgets/*/widget.json`, build the registry, execute nothing at load time.
- `src/net/asset_sync.lua` — verify (likely already-sufficient) generic manifest diffing covers `widgets/**`.
- `src/net/admin_game_manager.lua` — verify existing zip-slip/path/size validation applies uniformly to `widgets/**` with no accidental extension exclusion.

**Rendering (client-only):**
- `src/ui/table/table_view.lua` — custom-widget render dispatch alongside the existing hardcoded `counterFace` branch, routing to `widget_sandbox` when `customWidgetId` is set.

**Action dispatch (client peer-host + vendored to server):**
- `src/game/host_engine.lua` / `src/game/session.lua` — a generic `requestWidgetAction(instanceId, actionName, payload)` message type routed through `widget_actions.lua`, rather than one-off messages per widget type.

**Server (Go):**
- `server/internal/engine/engine.go` — dedicated restricted `*lua.LState`(s) for widget logic (§3b), Go↔Lua bridge functions for host RNG/action-requests.
- `server/internal/games/games.go` / `server/internal/server/admin_games.go` — likely no functional change; add explicit test coverage that `widgets/**/*.lua` round-trips correctly.
- New `server/internal/engine/widget_sandbox.go` — Go-side mirror of `widget_sandbox.lua`, built for parity-by-construction.
- `server/tools/sync-engine.ps1` — add the new `widget_sandbox.lua`/`widget_actions.lua` *framework* modules to the trusted-copy list (widget *content* is never touched by this script).

**UX (client):**
- A new trust-prompt/permission-management screen alongside `gamedef_editor.lua`/the admin-install flow, implementing §8.

**Tests:**
- `tests/runner.lua` + new `tests/widget_sandbox_test.lua` + `tests/fixtures/widgets/*`.
- New `server/internal/engine/widget_sandbox_test.go` consuming the same fixtures.

---

## Appendix: suggested implementation phases (brief, non-binding)

1. **Foundation, no execution:** manifest schema, registry plumbing in `models.lua`/`game_loader.lua`, distribution-pipeline test coverage — pure data, zero sandbox risk.
2. **Client-side sandbox + render contract only:** validates sandbox-hold properties and the trust-prompt UX against real content before any rule-affecting code exists.
3. **Logic contract, peer-hosted only:** exercises the full contract in the simpler single-runtime (LuaJIT-only) case first.
4. **Server-side logic parity:** Go sandbox + cross-runtime conformance harness against the same fixtures used in phase 3 — the highest-risk integration point, sequenced last deliberately.
5. **Hardening pass:** adversarial fixture expansion, circuit-breaker tuning under real widget content, trust-UX iteration.

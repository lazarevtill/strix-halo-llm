# Serving real users: saved chats, capacity, and what breaks

Written 2026-08-05, after this box picked up actual users. Nothing here is installed yet — this is
the decision material.

---

## 1. Why llama-server cannot save chats on its own

`llama-server` is **stateless**. It has no notion of a user, an account, or a conversation. Every
request carries the whole history, and the client is what remembers it:

```
POST /v1/chat/completions
{ "messages": [ {user}, {assistant}, {user}, ... ] }   <-- the client re-sends everything, every turn
```

The `/slots` "cached prompt tokens" you can see is **not storage**. It is a prefix-reuse cache that
saves re-computing prefill for a conversation that just continued. It is:

- **volatile** — gone on restart
- **capped** — one slot's worth, evicted when another conversation takes the slot
- **not per-user** — slot assignment is opportunistic

So "chats are saved and reusable" requires a front-end with a database. There is no llama.cpp flag
for it.

### This has a sharp edge with real users

**Every server restart costs users their cached context.** Observed on this box: a user's slot held
59,959 cached prompt tokens. After a restart their next message re-prefills from scratch — at
~700 t/s prefill that is roughly a minute and a half of staring at nothing, for a message that
would otherwise have started instantly.

The watchdog restarts on failure, and any model or flag change is a restart. **A database-backed
front-end makes a restart invisible** (history is on disk, only the cache warms again) instead of
looking like the assistant lost the thread. That is the strongest practical argument for adding one.

---

## 2. The options

### A. Open WebUI in Docker — the default choice

| | |
|---|---|
| Multi-user | Yes: accounts, roles, admin approval of signups |
| Chat storage | SQLite by default in one volume; Postgres supported |
| Effort | One container + one named volume |
| Extras | RAG over uploaded docs, per-user system prompts, model switching, shared prompts |

```bash
docker run -d --name open-webui --restart unless-stopped -p 3000:8080 \
  -e OPENAI_API_BASE_URL=http://host.docker.internal:8080/v1 \
  -e OPENAI_API_KEY=none \
  -e WEBUI_AUTH=true \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main
```

⚠️ **The reboot problem.** Docker Desktop on Windows starts **after a user logs in**. Your model
server runs as SYSTEM and comes back at boot with nobody logged in — Open WebUI would not. After an
unattended reboot users would find the model up and the chat UI gone. Fixes, cheapest first:

1. Enable auto-login on the box (weakens physical security, trivial to do)
2. Run Docker Engine inside WSL2 as a systemd service and start WSL from a SYSTEM task
3. Skip Docker — option B

### B. Open WebUI native, under a SYSTEM task — matches what you already have

```powershell
py -3.12 -m venv D:\open-webui\venv
D:\open-webui\venv\Scripts\pip install open-webui
# then wrap it exactly like scripts\windows\serve-daily.ps1 does: SYSTEM task,
# AtStartup + 15-min watchdog, health check on :3000
```

Survives unattended reboot with no login, no Docker dependency, and reuses a pattern that is
already proven on this box. Costs: pip dependency management, and upgrades are manual.

### C. LibreChat — pick only if you need what it adds

More configurable (multiple backends side by side, richer admin, per-user API keys), but it wants
**MongoDB + Meilisearch** alongside it. Three services instead of one, for features you may not use
with a single local model.

### D. Do nothing extra

Users keep history in whatever client they use (Claude Code, Codex, a desktop app). Zero work, no
central storage, no accounts, and no cross-device history. Honest option if "users" means two people
with their own tooling.

**Recommendation: B if the box must be hands-off, A if you will be around to log in after a reboot.**

---

## 3. Storage and backup

Chats become real data the moment users rely on them.

- **A Docker volume is not a backup.** `docker volume rm` or a Desktop reset destroys it.
- SQLite is fine to a few thousand chats. Move to Postgres only if you hit contention.
- Back up the data directory (`open-webui` volume, or the native `backend/data`) on a schedule and
  **restore it once** to prove the backup works. Untested backups have a habit of being empty.
- Chats will contain whatever users paste. Treat the store as sensitive.

---

## 4. Capacity: how many users this box actually supports

Measured 2026-08-05 (`scripts\windows\bench-parallel.ps1`), Ornith-1.0-35B Q5_K_M:

| concurrent generations | aggregate | per-request | vs solo |
|---|---|---|---|
| 1 | 50.2 t/s | 61.3 t/s | 1.00x |
| 2 | 69.8 t/s | 43.0 t/s | 1.39x |
| 3 | 77.9 t/s | 33.5 t/s | 1.55x |

Concurrency pays despite generation being bandwidth-bound, because one decode pass reads the weights
once and emits a token for every active sequence.

**Currently configured: 3 slots.** What that means in practice:

- Up to 3 users can generate **simultaneously**; a 4th waits for a free slot
- Users are bursty — they read and type far longer than they generate. 3 slots comfortably covers
  perhaps **5-10 light interactive users**; collisions only bite when 4+ hit send at once
- A lone user still gets the full ~61 t/s. **Idle slots cost nothing.**

**Unknown: where it plateaus past 3.** An attempt to measure 6 slots was invalid — the second
llama-server started for "isolation" competed for the same memory bus and dropped the production
endpoint from ~61 to 24.7 t/s. Do not benchmark alongside a live server; it measures the
interference, not the config. `bench-parallel.ps1` now refuses to run against a busy endpoint.

---

## 5. ⚠️ The context-window cost of adding slots

`--ctx-size` is the **TOTAL** context and is **SPLIT** across slots. Moving to 3 slots at the same
total **halved every user's window**:

| config | total ctx | per user | GPU |
|---|---|---|---|
| 1 slot (before) | 262144 | **262144** | 27.7 GiB |
| 3 slots (now) | 393216 | **131072** | 28.6 GiB |
| 3 slots (proposed) | 786432 | **262144** | ~33 GiB |

A user is already sitting at **59,959 tokens — 46% of their 131072 window.** Long agentic sessions
will hit that ceiling where they would not have before.

**The third row is strictly better and there is room for it**: 3 slots at the full 262144 each costs
about 4 GiB more, against 80 GiB free. Recommended change:

```powershell
.\scripts\windows\serve-daily.ps1 -Install -Parallel 3 -Ctx 786432
```

**Requires a restart, so it needs a quiet window** — it will wipe cached contexts of anyone mid-
conversation.

---

## 6. Access model

Chosen: **both the chat UI and `:8080` reachable on LAN/NetBird.**

Consequence, stated plainly: `:8080` has **no authentication**. Anyone who can route to this box can
use the model, read `/slots` (which exposes cached prompt sizes), and `/props`. That is a deliberate
tradeoff for convenience on a trusted network, not an oversight.

If that ever stops being acceptable:

- `--api-key <token>` on llama-server (every existing client config must be updated), or
- bind `:8080` to `127.0.0.1` and let only the UI reach it, or
- restrict the firewall rule to the NetBird subnet instead of any address

---

## 7. If you go ahead, the order that avoids pain

1. Pick A or B above
2. Install it pointing at `http://127.0.0.1:8080/v1`, `WEBUI_AUTH=true`
3. Create the accounts; disable open signup
4. **Verify it survives a reboot** — the whole point, and the step most likely to fail (option A)
5. Set up the backup, then restore it once to prove it
6. In the same maintenance window, apply the `-Ctx 786432` change from section 5

---

## 8. Serving two models at once (router mode)

Everything above serves **one** model. If your workload has two distinct shapes — say interactive
coding *and* long-form text — one model is the wrong tool for at least one of them. A dense 27B is a
good coder but generation-bound (~18–20 t/s), so a big-text answer that reasons for thousands of
tokens can take **minutes**; an MoE of similar size generates 2.5–3× faster because only a fraction of
its weights are active per token. You want both, at once.

llama.cpp has this built in (**b10431+**): start `llama-server` with **no `-m`** and it runs in
**router mode** — a coordinator that spawns a child server per model and routes each request by the
OpenAI `model` field. `scripts\windows\run-router.ps1` wraps it:

```powershell
.\scripts\windows\run-router.ps1            # :8080, serves qwen38 (coding) + ornith (big-text)
.\scripts\windows\run-router.ps1 -DryRun    # print the router cmdline and the generated preset
```

```jsonc
// same endpoint, choose the model per request:
{ "model": "qwen38", "messages": [...] }   // dense coder
{ "model": "ornith", "messages": [...] }   // fast MoE for big text
```

**Measured on this box (2026-08-18, b10431):** both models stay **co-resident** — qwen38 24.6 GB +
ornith 25.7 GB = ~50 GB of the 109 GB ceiling, host RAM 18 GB free — with **no reload between calls**
and **no speed penalty** on the idle model (qwen38 held 18.3 t/s alongside a resident ornith). The
`--models-max` flag caps how many stay resident; beyond it the router evicts least-recently-used.

Three things the launcher handles that will bite you if you drive `llama-server` by hand:

- **`load-mode = none` per model.** The default (mmap) pins a ~15 GB host-RAM file mirror *per model*.
  This box has ~32 GB of system RAM — two mirrors exhaust it. `none` keeps weights in the VRAM
  carve-out with the host copy paged out. This is the single biggest dual-model trap.
- **Pre-loading.** Autoload does **not** fire on the first `/v1/chat/completions` call — it returns
  `400 "model is not loaded"`. The launcher `POST`s `/models/load` for each model at startup, so
  clients never see it.
- **Context is split, not shared.** Two resident models divide the ~109 GB budget, so each gets
  `-Ctx 131072` here, not the 262144 a solo model gets. Raise or lower it per your models' sizes.

**The client contract changes:** router mode has **no default model**. Every request must name one;
a request with no `model` field (or an unknown name) returns 400. Point each tool at the model it
should use.

**When *not* to use it:** router mode is about serving different *models*. If you instead want one
model to serve several concurrent *users*, that is `--parallel` slots (sections 4–5), not this — and
note two models both generating at the same instant do contend for memory bandwidth, exactly the
interference measured in section 4. Router mode shines when the two models are used at different times
or lightly overlapping, which is the usual coding-plus-text pattern.

### Auto-starting the router at boot

The router does not survive a reboot on its own. Persist it with a **Startup-folder launcher** — *not*
a Windows service or a Scheduled Task. Vulkan/WDDM needs an interactive desktop session (a Session-0
service can't reach the GPU), and a Startup item runs in the real logon session with no kill-on-close
job object around its detached child. Create
`…\Microsoft\Windows\Start Menu\Programs\Startup\StrixHalo-Router.cmd`:

```bat
@echo off
cd /d D:\llamacpp-vulkan
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\llamacpp-vulkan\scripts\windows\run-router.ps1" -Models coder -Bin ".\bin-b11003" -Ctx 262144
```

(`-Models qwen38,ornith` was the original example. As of 2026-09-16 this box serves `coder`
— Qwen3-Coder-Next, which **requires** `-Bin .\bin-b11003` because the pinned `bin\` cannot load
`qwen3next` at all. Substitute whatever you actually serve.)

> **This file lives OUTSIDE the repo, so it drifts silently and nothing in CI will catch it.**
> Learned 2026-09-16: it was still launching `-Models gemma` well after `:8080` had moved to `coder`,
> so a reboot would have quietly served the wrong model with no one the wiser. **Re-check it every
> time the served set or the engine dir changes.**

Two more caveats, both learned the hard way:

- **It fires at *logon*, not at power-on** — Vulkan needs the interactive session. With no autologin
  (the default here) the router comes up ~20 s *after you log in*, not at the lock screen. For a truly
  headless box, enable Windows autologin (it stores the password — a deliberate security tradeoff).
- **A logon Scheduled Task was tried and rejected:** it exited non-zero because `run-router` kills the
  incumbent then waits only 3 s before relaunching, and WDDM hadn't freed the ~55 GB, so the new
  llama-server failed its GPU allocation (a hot-restart VRAM race — harmless at a real boot with no
  incumbent, but the task's session/job semantics are a poor fit for a detached GPU server).

## 9. Prometheus / OpenTelemetry metrics

`scripts\windows\metrics-exporter.ps1` serves merged Prometheus metrics on a **fixed port 9114**:

```powershell
.\scripts\windows\metrics-exporter.ps1          # serve until Ctrl-C
.\scripts\windows\metrics-exporter.ps1 -Once    # one scrape to stdout
```

```yaml
scrape_configs:
  - job_name: llamacpp
    static_configs:
      - targets: ['127.0.0.1:9114']
```

**Why an exporter rather than scraping llama.cpp directly** — two reasons, both specific to router mode:

1. **The router parent on `:8080` does not serve `/metrics`** (it returns 400). Only the per-model
   *child* processes do.
2. **Each child listens on a random port** chosen at launch (51955, 59026, …, different every
   restart), so there is no stable target to put in `prometheus.yml`.

The exporter discovers children through the router's own `/v1/models` (each entry carries the
child's full argv including `--port`), scrapes each child, relabels every series with
`model="<id>"`, and merges them onto one port.

**`metrics = 1` must be set per child** — it is off by default upstream and `/metrics` answers
**501 Not Implemented** without it. `run-router.ps1` puts it in `$common` as of 2026-10-02, so any
router it launches already exports. A child missing it is reported as a `# NOTE` line rather than
silently dropped.

### The metrics worth alerting on

| metric | meaning |
|---|---|
| `llamacpp:predicted_tokens_seconds` | **generation t/s** — the number you watch |
| `llamacpp:prompt_tokens_seconds` | prefill t/s |
| `llamacpp:requests_processing` | in-flight requests |
| `llamacpp:requests_deferred` | **queued** — sustained `> 0` means you need more slots |
| `llamacpp:prompt_tokens_cached_total` | prompt-cache hits; compare against `prompt_tokens_total` |
| `llamacpp:spec_decode_num_accepted_tokens_total` ÷ `…_draft_tokens_total` | speculative acceptance rate (0 when `-NoSpec`) |
| `llamacpp_slots_busy` / `llamacpp_slots_total` | slot occupancy (synthesised here, not upstream) |
| `llamacpp_slot_ctx_used_tokens` | per-slot context fill — watch for slots nearing their window |

### Reading slot occupancy correctly

A slot stays **assigned** to a conversation between requests so its KV cache can be reused, so
`llamacpp_slot_ctx_used_tokens` being non-zero on several slots does **not** mean several requests
are running. Only `is_processing` (→ `llamacpp_slots_busy`) counts active generation. Four occupied
slots with `slots_busy = 1` means four cached conversations and a client issuing requests
**sequentially** — not concurrency.

> **PS 5.1 trap, cost real time here.** `Invoke-RestMethod` on the `/slots` JSON array collapses it
> into a single object whose properties are arrays, so `.Count` reads **1** on a 4-slot server while
> the data actually holds every slot. An early exporter build reported `slots_total 1, slots_busy 1`
> against four live slots. Use `Invoke-WebRequest` + `ConvertFrom-Json`, and count by **iterating**
> rather than trusting `.Count`. Same family as the `ConvertTo-Json` collection-rewrapping gotcha in
> CLAUDE.md.

### Binding the exporter on all interfaces

The exporter defaults to `-Bind '+'` (all interfaces) so Prometheus on another host can scrape it.
`HttpListener` cannot bind `+` without a URL ACL, so the **first** run needs this once, elevated:

```
netsh http add urlacl url=http://+:9114/ user="DOMAIN\user"
netsh advfirewall firewall add rule name="llamacpp-metrics" dir=in action=allow protocol=TCP localport=9114
```

> **Do not paste `%USERDOMAIN%\%USERNAME%` into PowerShell.** Those are cmd.exe variables and are
> *not* expanded there, so netsh receives the literal text and fails with
> `Create SDDL failed, Error: 1332 The parameter is incorrect.` Use the output of `whoami`, or
> `"$env:USERDOMAIN\$env:USERNAME"`. The exporter prints the correct, already-resolved command when
> its bind fails, so copy it from there.

Without the ACL the exporter still starts, but **loopback-only** — it warns loudly rather than
downgrading silently, because from the scraping host that is indistinguishable from "the box is
down". Check the banner: it prints either `ALL INTERFACES` with each reachable URL, or `(local only)`.

**The endpoint is unauthenticated.** It exposes model names, slot occupancy, context sizes and token
counters — never prompt or completion text. Fine on a trusted LAN or tailnet; firewall it otherwise.

## 10. Slot count is capped by STABILITY, not memory

Measured 2026-10-02 on ornith15 / b11330 / `-ub 1024`, 10 sequential requests each, counting child
process restarts:

| slots × per-slot ctx | total KV | spec | result |
|---|---|---|---|
| 2 × 262144 | 512 K | **on** | 10/10, 0 restarts — **STABLE**, shipped |
| 3 × 262144 | 768 K | on | 4/10, 6 restarts — unstable |
| 4 × 262144 | 1 M | on | child crashes repeatedly — unstable |
| 4 × 262144 | 1 M | off | 10/10, 0 restarts — **STABLE** |
| 8 × 65536 | 512 K | off | stable |
| 8 × 262144 | 2 M | off | 2/10, 5 restarts — unstable |

Speculation **lowers** the usable KV ceiling: 512 K is fine with it, 768 K is not, while without it
1 M is fine and 2 M is not. Every failure occurred at **45–52 GB committed**, far below the ~109 GB
budget, so this is a Vulkan allocation limit rather than capacity — raising the carve-out will not
help. Re-test concurrency after any change to slot count, per-slot context, or speculation.

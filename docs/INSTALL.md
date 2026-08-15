# Install and first run

From nothing to a working OpenAI-compatible endpoint on your own machine, on **Windows, Linux or
macOS**. No ML background needed — if a term here is unfamiliar, [EXPLAIN.md](EXPLAIN.md) defines
all of them in plain English.

> 📊 Want the numbers before you install anything? **<https://strix.lazarev.cloud/>** has the
> measured results as charts, including which flags are worth setting and which are cargo cult.

Four steps on every platform:

```mermaid
flowchart LR
    A["1 · get llama.cpp<br/>the engine"] --> B["2 · get a model<br/>a .gguf file"]
    B --> C["3 · serve it<br/>one command"]
    C --> D["4 · check it<br/>curl or browser"]
```

---

## Which platform is which

Be aware of what is actually tested before you trust a number you read here.

| | state | what that means |
|---|---|---|
| **Windows 11** on Strix Halo | ✅ **measured** | Every benchmark in this repo was produced here. The tuned flags are measured-optimal on this exact chip. |
| **Linux** | 📝 **draft** | Scripts are ported flag-for-flag and syntax-checked. None has served a model on Linux. The llama.cpp flags should carry over; anything touching GPU memory accounting must be re-measured. |
| **macOS** (Apple silicon) | 📝 **draft** | Same: ported, never run. Metal is a different GPU architecture, so the *method* transfers and the *numbers* do not. |

**Contributions from a Linux or Mac box are the single most useful thing anyone could send.**

---

## Requirements

| | Windows | Linux | macOS |
|---|---|---|---|
| hardware | Strix Halo / gfx1151 (or any Vulkan GPU) | any Vulkan GPU | Apple silicon (M1 or newer) |
| driver | current AMD Adrenalin | `vulkaninfo --summary` must list your GPU | nothing — Metal is built in |
| shell | PowerShell 5.1 (ships with Windows) | bash + `curl`, `unzip` | bash + `curl`, `unzip`, or Homebrew |
| Python 3.12 | only for the coding eval | same | same |
| Docker | only for the coding-eval sandbox | same | same |

RAM is the real constraint. A model needs roughly its **file size** in memory, plus the KV cache.
16 GB runs an 8B model comfortably; the 27B model used as this repo's default needs ~20 GB with a
modest context.

---

## Step 1 — get llama.cpp

llama.cpp is the engine that actually runs the model. You do **not** need to compile it.

### Windows

```powershell
git clone https://github.com/lazarevtill/strix-halo-llm.git
cd strix-halo-llm

.\scripts\windows\fetch-llamacpp.ps1                 # newest release
.\scripts\windows\fetch-llamacpp.ps1 -Build b10431   # the build this repo's numbers use
```

### Linux

```bash
git clone https://github.com/lazarevtill/strix-halo-llm.git
cd strix-halo-llm

chmod +x scripts/linux/*.sh
./scripts/linux/fetch-llamacpp.sh                    # newest release
./scripts/linux/fetch-llamacpp.sh --build b10431     # pinned
```

If it reports no Vulkan device, the driver stack is the problem, not llama.cpp:

```bash
sudo apt install libvulkan1 mesa-vulkan-drivers vulkan-tools   # Debian/Ubuntu
vulkaninfo --summary                                           # must list your GPU
```

### macOS

```bash
git clone https://github.com/lazarevtill/strix-halo-llm.git
cd strix-halo-llm

chmod +x scripts/macos/*.sh
./scripts/macos/fetch-llamacpp.sh                    # Homebrew, Metal enabled by default
export LLAMA_BIN="$(command -v llama-server)"        # point the repo's scripts at it
```

Prefer the same `bin/` layout as the other platforms? `./scripts/macos/fetch-llamacpp.sh --method release`.

**Pin the build when reproducing a number.** Results move between builds, which is why every table
in this repo names the build it came from.

---

## Step 2 — get a model

A model is a single `.gguf` file. The downloader is resume-capable and verifies byte counts against
the Hugging Face API, so an interrupted download cannot leave you with a file that looks complete
and fails strangely later.

```powershell
.\scripts\windows\fetch-models.ps1 -List             # what's on offer, with sizes
.\scripts\windows\fetch-models.ps1 -Only qwen38      # 16.7 GB
```

```bash
./scripts/linux/fetch-models.sh --list               # Linux and macOS both use this one
./scripts/linux/fetch-models.sh --only qwen38
```

Which to start with:

| you have | start with | size |
|---|---|---|
| 16 GB RAM | a smaller 8B model — see `-List` | ~5 GB |
| 32 GB RAM | **`qwen38`** (Qwen3.8-27B UD-Q4_K_XL) | 16.7 GB |
| 64 GB+ | `qwen38`, then experiment upward | — |

Downloads are tens of GB. Start one and do something else.

---

## Step 3 — serve it

One model at a time, holding the whole memory budget. Every launcher here refuses to start when
another model is resident — two models sharing one memory bus don't give you a slightly wrong
number, they give you a meaningless one.

```powershell
.\scripts\windows\run-solo.ps1                       # Windows
```

```bash
./scripts/linux/run-solo.sh --dry-run                # prints the command, launches nothing
./scripts/linux/run-solo.sh                          # Linux

./scripts/macos/run-solo.sh --dry-run                # macOS
./scripts/macos/run-solo.sh
```

Use `--dry-run` first on the draft platforms. It prints the exact `llama-server` invocation without
starting anything, so you can see what it intends to do.

---

## Step 4 — check it works

```bash
curl http://127.0.0.1:8080/health
# {"status":"ok"}

curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello in five words."}]}'
```

There is also a web UI at <http://127.0.0.1:8080>.

That endpoint is OpenAI-compatible, so **Claude Code, Codex, Continue, and any OpenAI SDK point
straight at it** — set the base URL to `http://127.0.0.1:8080/v1` and use any string as the API key.

---

## When the first run fails

| symptom | cause | fix |
|---|---|---|
| `llama-server not found` | step 1 didn't finish | re-run the fetch script; check `bin/` |
| no Vulkan device in the banner | driver too old or absent | update the GPU driver; `vulkaninfo --summary` |
| loads, then exits without a message | ran out of memory | lower `--ctx`, or use a smaller quant |
| "cannot be opened because the developer cannot be verified" (macOS) | Gatekeeper quarantine | `xattr -dr com.apple.quarantine bin/` |
| a model that should fit refuses to load (macOS) | GPU wired-memory cap | `sudo sysctl iogpu.wired_limit_mb=<MB>`, leaving several GB for the OS |
| very slow, GPU idle | running on CPU | confirm `-ngl 999` and that the GPU appears in the startup banner |
| fine alone, terrible with a second model running | two resident models | serve one at a time |

**The memory cap is the same problem on every unified-memory machine.** On Windows/Strix Halo it's
the BIOS carve-out plus the WDDM shared heap (~109 GB usable, not the 96 GB the carve-out implies);
on macOS it's `iogpu.wired_limit_mb`. Different knob, identical failure: a model that arithmetic
says fits, refusing to load.

---

## What transfers between platforms, and what doesn't

The llama.cpp flags are properties of the model and the GPU architecture. The memory accounting is
a property of the OS.

| | |
|---|---|
| ✅ **likely transfers** | `-fa on` with `q8_0` KV · MoE beating dense per GB · the bf16 trap (bigger ≠ better) · `draft-mtp` speculation where the model ships an MTP head · quant-size-vs-speed running backwards |
| ⚠️ **re-measure per GPU** | `-ub 256`. This is the biggest Windows win here (+29% prefill) and the *most* architecture-specific: it works because a 256-row tile fits gfx1151's 32 KB of shared memory. Sweep it on your GPU |
| ❌ **Windows-only** | the ~109 GB ceiling · `Total Committed` vs `Dedicated Usage` · modern standby dropping VRAM · `--mlock` being harmful (it may be *correct* on Linux) |

**Port the method, not the numbers.** Anything measured on another platform belongs in its own
column, never merged into the Windows figures.

---

## Next

- **[EXPLAIN.md](EXPLAIN.md)** — every term above, in plain English, with diagrams
- **[RESULTS.md](RESULTS.md)** — what was measured, and what it means
- **[GOING-FASTER.md](GOING-FASTER.md)** — the tuning that paid off, and five ideas measurement killed
- **[BENCHMARKS.md](BENCHMARKS.md)** — how to measure without fooling yourself
- **[../evals/README.md](../evals/README.md)** — the eval harness, and the wrong numbers it used to produce

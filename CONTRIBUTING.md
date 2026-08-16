# Contributing

## What this repo wants most

**Numbers from a box that is not this one.** Every figure here was measured on a single
Windows 11 / Ryzen AI MAX+ 395 machine, which means the findings are honest and the *generality* is
unproven. Two things would change that:

- **Another Strix Halo box** — does the ~109 GB ceiling hold with a different carve-out, different
  RAM speed, a different driver?
- **Linux, on any gfx1151 part.** The bash trees in `scripts/linux/` and `scripts/macos/` are
  syntax-checked drafts that have **never served a model on their own platform**. Several of the
  headline findings are specifically Windows/WDDM ones — the shared-heap ceiling, `Total Committed`
  vs `Dedicated Usage`, modern standby dropping VRAM, `--mlock` being harmful — and they need
  re-measuring rather than assuming. ROCm may also beat Vulkan there; the 1.79× Vulkan win recorded
  here is against *Ollama's* ROCm on Windows, which is not the same comparison as llama.cpp's own
  ROCm backend.

Port the method, not the numbers. Anything measured elsewhere belongs in its own column, never
merged into the Windows figures.

## The one rule for a result

A benchmark result needs **context depth, quant, backend and build** attached, or it cannot be
compared to anything. Depth is the one people leave off: `llama-bench` defaults to depth 0, an empty
KV cache, and that number is a fiction for agentic work. `pp` and `tg` are reported separately —
prefill is compute-bound, decode is bandwidth-bound on *active* parameters, so a single "tok/s" is
not a result.

**If a run is worse than one published here, say so.** A contradiction is the most useful thing you
can send; this repo keeps both the claim and its refutation, because the contrast is the useful
part. `docs/BENCHMARKS.md` is what to read before measuring anything.

## Conventions

**PowerShell 5.1, not 7.** No `&&`, no ternary, no `??`. That constraint is deliberate: 5.1 ships
with Windows, so nothing here needs installing first. The 5.1 traps that have actually cost time are
listed at the top of `docs/BENCHMARKS.md` and in `evals/README.md`.

**The bash scripts use compact, aligned `case` blocks** for argument parsing — one line per option,
`;;` at the end:

```bash
case "$1" in
  -m|--model)      MODEL="$2"; shift 2 ;;
  --no-kv-quant)   KV_QUANT=0; shift ;;
  --dry-run)       DRY_RUN=1; shift ;;
  *) echo "unknown option: $1" >&2; usage; exit 2 ;;
esac
```

Match it, and **do not reformat code your change does not otherwise touch.** A whole-tree `shfmt`
pass once turned `KV_QUANT=0; shift` into `KV_QUANT=0 shift` — without the semicolon that is an
environment assignment scoped to `shift`, so `--no-kv-quant` parsed cleanly, exited 0, and quietly
did nothing. `bash -n` accepted it and shellcheck reported nothing, because the mutant is valid
bash. That is why CI runs the launchers and reads the argv they would exec.

**Model registry byte counts are verified against the Hugging Face API, never guessed.** The
downloader compares the fetched size against the recorded one, so a wrong number fails somebody's
download rather than a review.

**If you change a measured default, say what you measured** — hardware, depth, quant, backend,
build. A default that moved without a measurement behind it is a guess wearing a number.

## What is deliberately not in the repo

`models/` (~640 GB of GGUF) and `bin/` (llama.cpp binaries) are gitignored for the obvious reason.
The eval content is gitignored for a much less reversible one:

```
evals/tools/cases.jsonl      evals/code/tasks.json
evals/code/tests/            evals/code/reference/
```

**The harness is public; the answers are not.** Those suites are worth something only because they
exist nowhere public, so no model has trained on them — on decontaminated SWE-rebench, A3B-class
models score roughly **4× below** their self-reported SWE-bench figures, and that gap is benchmark
leakage. Pushing the cases would put them in the next crawl, retroactively devalue every number
already recorded here, and **cannot be undone.** `docs/PUBLISHING.md` covers what is safe to publish
and shows the file shapes so you can author your own cases.

## Running the verification suite locally

The same four checks CI runs (`.github/workflows/verify.yml`). None needs a GPU, a model, or the
private eval content:

```bash
# 1. bash syntax + lint
find scripts -name '*.sh' -type f -exec bash -n {} \;
shellcheck scripts/linux/*.sh scripts/macos/*.sh

# 2. python compiles, and the scorer passes its own self-test
python -m py_compile evals/*.py evals/code/*.py
python evals/test-rescore.py          # exits non-zero on failure

# 3. the launcher argument contract -- what the flags actually come out as
MODELS_DIR=/tmp/fake-models LLAMA_BIN=/bin/echo scripts/linux/run-solo.sh --dry-run
MODELS_DIR=/tmp/fake-models LLAMA_BIN=/bin/echo scripts/linux/run-solo.sh --dry-run --no-kv-quant
```

`--dry-run` prints the exact `llama-server` invocation and launches nothing, so a `.gguf`-shaped
empty file in `MODELS_DIR` is enough to exercise the whole argument path. CI asserts on that output:
`-ub 256` on Linux and `512` on macOS, `--cache-type-k/v q8_0` present by default and *absent* under
`--no-kv-quant`, `-lm none` rather than the deprecated `--no-mmap`, and that model selection fails
loudly instead of guessing or hanging when there is no terminal to ask at.

On Windows, every `.ps1` is parse-checked with **5.1** (`shell: powershell`, not `pwsh`):

```powershell
Get-ChildItem -Path scripts, evals -Recurse -Filter *.ps1 | ForEach-Object {
  $t = $null; $e = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e)
  if ($e.Count) { Write-Host ("FAIL {0}" -f $_.FullName); $e }
}
```

## Reporting

Two issue forms: **Benchmark result** for a number, **Bug report** for a script that misbehaves.
Discussions are not enabled — open an issue.

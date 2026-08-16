# What this changes

<!-- One or two lines. If it changes a measured default, the measurement goes in the next section. -->

## If a measured default moved

<!-- Delete this section if nothing measured changed. Otherwise: what you measured, on what
     hardware, at what context depth, with which quant, backend and build — the same four
     attributes a benchmark result needs. A default that changed without a measurement behind it
     is a guess wearing a number. -->

## Checks

- [ ] **PowerShell 5.1 only** — no `&&`, no ternary, no `??`. 5.1 is what ships with Windows, so
      nothing here needs installing first. `.github/workflows/verify.yml` parses every `.ps1` with
      5.1 on purpose; pwsh 7 would accept all three.
- [ ] **No reformatting of code this PR does not otherwise change.** A whole-tree `shfmt` pass once
      turned `KV_QUANT=0; shift` into `KV_QUANT=0 shift` — valid bash, silently disabling
      `--no-kv-quant`, and both `bash -n` and shellcheck passed it. Keep formatting changes in their
      own commit, or their own PR.
- [ ] **Every model registry byte count is verified against the Hugging Face API**, not typed from
      a file listing or carried over from a similar quant. The downloader compares against it, so a
      guessed number fails the download rather than the review.
- [ ] No private eval content added — `evals/code/tasks.json`, `tests/`, `reference/` and
      `evals/tools/cases.jsonl` stay gitignored. Publishing them is irreversible
      (see `docs/PUBLISHING.md`).
- [ ] `bash -n`, shellcheck, `python evals/test-rescore.py` and the launcher `--dry-run` contract
      all pass locally. Commands in `CONTRIBUTING.md`.

## Anything you could not verify

<!-- Say so here rather than leaving it implied. Linux and macOS scripts are unproven drafts;
     "syntax-checked, never run on the target platform" is an acceptable answer and a useful one. -->

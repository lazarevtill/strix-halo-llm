# Documentation

Four documents. Start with whichever matches what you're trying to do.

| doc | read it when | length |
|---|---|---|
| **[OPTIMIZATION.md](OPTIMIZATION.md)** | You want the box to go faster, or you're choosing a model/quant | long — it's a reference, skim the ⭐ sections |
| **[BENCHMARKS.md](BENCHMARKS.md)** | You want to measure something, or you're reading numbers someone else produced | medium |
| **[FLEET.md](FLEET.md)** | You have more than one machine, or you're wiring up retrieval / memory layers | medium |
| **[PUBLISHING.md](PUBLISHING.md)** | You're about to push this (or a fork) somewhere public | short |

## If you only read one page

**[OPTIMIZATION.md](OPTIMIZATION.md)** — the memory ceiling, the flags that matter, and the model
comparison. It's the highest-value page for a new owner.

## Conventions used across these docs

- **MEASURED** means it was run on this box and the number is real. Anything else is marked as an
  estimate, a vendor claim, or research.
- **Struck-through predictions are kept on purpose.** Where a published benchmark or a plausible
  assumption was later refuted by measurement, both are shown. Deleting the wrong prediction would
  hide the more useful lesson: which kinds of claims don't survive testing.
- Paths are Windows-style (`docs\BENCHMARKS.md`) because the scripts are PowerShell today. See
  [Platform support](../README.md#platform-support) for what changes on Linux.
- Dates are ISO (`2026-08-04`). Findings are dated because llama.cpp builds and drivers move.

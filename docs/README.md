# Documentation

## New here? → **[EXPLAIN.md](EXPLAIN.md)**

Plain-language primer: what prefill and generation are, why this hardware is fast at some things
and slow at others, what quantisation and speculative decoding actually do, and a glossary. No GPU
or ML background assumed. Everything else on this page assumes the terms it defines.

## Then pick by what you're doing

| doc | read it when | length |
|---|---|---|
| **[EXPLAIN.md](EXPLAIN.md)** | You want the concepts, in plain English, with diagrams | short |
| **[GOING-FASTER.md](GOING-FASTER.md)** | You want the settings to copy, and what NOT to try | short |
| **[OPTIMIZATION.md](OPTIMIZATION.md)** | You're choosing a model or quant, or hunting the memory ceiling | long — a reference, skim the ⭐ sections |
| **[BENCHMARKS.md](BENCHMARKS.md)** | You want to measure something, or you're reading numbers someone else produced | medium |
| **[FLEET.md](FLEET.md)** | You have more than one machine, or you're wiring up retrieval / memory layers | medium |
| **[MULTI-USER.md](MULTI-USER.md)** | Real people are using the endpoint: saved chats, capacity, what a restart costs them | medium |
| **[PUBLISHING.md](PUBLISHING.md)** | You're about to push this (or a fork) somewhere public | short |

## If you only read two pages

**[EXPLAIN.md](EXPLAIN.md)** for what the numbers mean, then
**[GOING-FASTER.md](GOING-FASTER.md)** for the settings worth copying.

## Conventions used across these docs

- **MEASURED** means it was run on this box and the number is real. Anything else is marked as an
  estimate, a vendor claim, or research.
- **Refuted ideas are listed, not narrated.** Where a plausible optimisation was disproved by
  measurement, it appears as one row in a "do not do this" table with the number that killed it —
  enough to stop you repeating it, without the history of how it was found. The pattern itself is
  summarised once, in [EXPLAIN.md §7](EXPLAIN.md).
- Paths are Windows-style (`docs\BENCHMARKS.md`) because the scripts are PowerShell today. See
  [Platform support](../README.md#platform-support) for what changes on Linux.
- Dates are ISO (`2026-08-04`). Findings are dated because llama.cpp builds and drivers move.

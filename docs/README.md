# Documentation

## New here? → **[INSTALL.md](INSTALL.md)**, then **[EXPLAIN.md](EXPLAIN.md)**

[INSTALL.md](INSTALL.md) takes you from nothing to a working endpoint on **Windows, Linux or
macOS** — four steps, with a troubleshooting table for when the first run fails.

[EXPLAIN.md](EXPLAIN.md) is the plain-language primer: what prefill and generation are, why this
hardware is fast at some things and slow at others, what quantisation and speculative decoding
actually do, and a glossary. No GPU or ML background assumed. Everything else here assumes the
terms it defines.

There is also a rendered report of the results at **<https://strix.lazarev.cloud/>**.

## Then pick by what you're doing

| doc | read it when | length |
|---|---|---|
| **[INSTALL.md](INSTALL.md)** | You have none of it working yet — any of the three platforms | short |
| **[EXPLAIN.md](EXPLAIN.md)** | You want the concepts, in plain English, with diagrams | short |
| **[RESULTS.md](RESULTS.md)** | You want the measured numbers and what they support | medium |
| **[GOING-FASTER.md](GOING-FASTER.md)** | You want the settings to copy, and what NOT to try | short |
| **[OPTIMIZATION.md](OPTIMIZATION.md)** | You're choosing a model or quant, or hunting the memory ceiling | long — a reference, skim the ⭐ sections |
| **[BENCHMARKS.md](BENCHMARKS.md)** | You want to measure something, or you're reading numbers someone else produced | medium |
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
- Paths are Windows-style (`docs\BENCHMARKS.md`) because the measured platform is Windows. Linux
  and macOS equivalents are in [INSTALL.md](INSTALL.md) and
  [Platform support](../README.md#platform-support).
- **Numbers are withdrawn rather than quietly corrected.** Where a result turned out to be
  unsound, the page says so and explains what went wrong, because the failure is usually more
  reusable than the number was. The quality scores are in that state right now — see
  [RESULTS.md §3](RESULTS.md#3-quality).
- Dates are ISO (`2026-08-04`). Findings are dated because llama.cpp builds and drivers move.

# Publishing this repo — what is safe, what is not

Read this before `git init` / `git push`, and before relaxing anything in `.gitignore`.

## ⛔ The one that is easy to get wrong: the eval content

`evals/` contains two suites whose **entire value is that they are unpublished**. No model has
trained on them, which is why their numbers can be trusted at all. For calibration: on
decontaminated **SWE-rebench**, A3B-class models score roughly **4x below** their self-reported
SWE-bench figures. That gap is benchmark leakage, and it is what these suites exist to avoid.

Pushing the cases publicly would:
1. put them in the next crawl, so every model trained after that date may have memorised them;
2. retroactively devalue every number already recorded here, because you could no longer tell
   whether a future model scored well by reasoning or by recall;
3. be irreversible — you cannot un-publish a benchmark.

So the split is:

| published | withheld |
|---|---|
| the **harness** — runners, scorers, sandbox, smoke test | `evals/tools/cases.jsonl` (29 cases) |
| the **methodology** — BENCHMARKS.md, evals/README.md | `evals/code/tasks.json` (4 tasks x 3 turns) |
| the **tool schemas** — `evals/tools/tools.json` | `evals/code/tests/` (hidden pytest suites) |
| the **results** and how to read them | `evals/code/reference/` (reference solutions) |

The harness is the reusable part and the part worth sharing. The answers are not.

### Authoring your own cases

Everything you need is in `evals/README.md`. Shapes:

- **Tool cases** (`cases.jsonl`, one JSON object per line):
  `{"id": "...", "cat": "select|args|enum|multi|chain|abstain|hard", "prompt": "...", "expect": [{"name": "tool", "args": {...}}]}`
  `expect: []` means *no tool call should be emitted* — the abstain category, which most models fail
  and which is weighted equally on purpose.
- **Coding tasks** (`tasks.json`): `{"id", "module", "entry", "turns": [t1, t2, t3]}` with a matching
  `tests/test_<id>.py` sectioned by `# ---- turn N additions ----`, plus a known-good
  `reference/<id>.py`.

Then run `python evals/code/smoke.py`, which **fails loudly if a turn prompt is not satisfiable by
the reference solution**. That check is not optional: a turn-3 prompt here once asked for a spend to
succeed while its own hidden test asserted it fails, so it silently rewarded *ignoring the user* —
any model that engaged with the contradiction scored 0.

## Audited and clean

A scan of all 249 tracked text files (excluding `.venv`, `node_modules`, `.remember`) found:

- **No credentials, tokens, private keys, or `Bearer` headers.** No `.env` files exist in the tree.
- No AWS/GCP keys, no `glpat-`/`ghp_`/`hf_` tokens.

## Scrubbed before publication

| was | now | where |
|---|---|---|
| NetBird address `100.x.x.x` | `127.0.0.1` in code defaults; `<inference-host>` in docs | `bench-web/{models.py,store.py,docker-compose.yml,targets.json}`, 4 docs |
| LAN address `192.168.x.x` | `<lan-ip>`, `<host-a>`, `<host-b>` | `CLAUDE.md` |
| NetBird CIDR | `<netbird-cidr>` | `CLAUDE.md` |
| internal GitLab URL incl. org/group path | `<your-git-remote>` | `ornith-router/finetune/README.md` |

Code defaults now point at `127.0.0.1` and stay overridable via `TARGET_BASE_URL`, so the bench web
app still works out of the box without advertising anyone's network topology.

## Excluded by .gitignore

- `models/` — **~640 GB** of GGUF weights. Never commit weights; `fetch-models.ps1` re-downloads them.
- `bin/`, `bin-b9771/`, `bin-b10182/`, `bin-poolside/` — vendored llama.cpp binaries (~90 MB each).
- `.venv/`, `node_modules/`, `__pycache__/` — dependency trees (the venv alone is ~36k files, and it
  is the source of nearly every "secret-like" regex hit in a naive scan: library source code, not
  your secrets).
- `.remember/` — private session/working logs.
- Raw benchmark dumps, eval results, transcripts, `*.bak` quarantine files, logs.

## Before you push — the checklist

```powershell
git init
git add -A
git status --short          # eyeball it; nothing from the table above should appear
git ls-files | Measure-Object          # expect a few hundred files, not thousands
git ls-files | Select-String 'cases.jsonl|tasks.json|tests/|reference/|\.gguf|\.remember'   # expect NOTHING
```

Then re-run the secret scan on what is actually staged:

```powershell
git ls-files | ForEach-Object { Select-String -Path $_ -Pattern '(?i)(api[_-]?key|secret|password|token)\s*[:=]\s*["'']?[A-Za-z0-9_\-\.]{16,}' -EA SilentlyContinue }
```

## If something sensitive is ever committed

Rotate first, scrub second. A credential that reached a remote is compromised the moment it was
pushed — rewriting history does not un-leak it, and forks/caches/crawlers may already hold it.
Rotate the credential, then clean the history with `git filter-repo`, then force-push.

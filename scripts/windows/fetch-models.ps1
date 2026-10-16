<#
.SYNOPSIS
  Download the July-2026 "biggest that fits" model set for this box, with resume + size verification.

.DESCRIPTION
  Replaces download-model.ps1 for large multi-shard models. Differences that matter at this scale:
    * uses curl.exe (ships with Windows) with `-C -` so an interrupted 90 GB download RESUMES
      instead of restarting; Invoke-WebRequest has no resume and buffers badly
    * verifies each file against its EXPECTED byte count (from the HF API) and re-fetches on mismatch
    * skips files already complete, so re-running is cheap and idempotent
    * registry of vetted models: every size here was byte-summed from the HF API, not estimated

  MEASURED CEILING on this box is ~109 GiB total (96 GiB carve-out + ~13.4 GiB WDDM shared).
  Sizes below are GiB of weights; leave room for KV + compute buffers. See OPTIMIZATION.md.

.EXAMPLE
  .\fetch-models.ps1 -List                       # show the registry, sizes, what's already present
  .\fetch-models.ps1 -Only ornith-bf16           # one model
  .\fetch-models.ps1 -Only ornith-bf16,qwen122b  # several
  .\fetch-models.ps1 -All                        # every LOADABLE entry (WILL-NOT-LOAD ones skipped; size: -All -WhatIf)
  .\fetch-models.ps1 -All -WhatIf                # plan only
#>
[CmdletBinding()]
param(
    [string[]] $Only,
    [switch]   $All,
    [switch]   $List,
    [switch]   $WhatIf,
    [string]   $Dest = ''      # '' => models\llm, or models\image for entries marked dir = 'image' (paths.ps1)
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'paths.ps1')          # engines\, models\, logs\: the one path resolver (paths.ps1)

# label -> repo, files (path within repo), expected bytes per file, notes
# Every byte count verified against https://huggingface.co/api/models/<repo>/tree/... on 2026-07-30.
$REG = [ordered]@{
    'ornith-bf16' = @{
        repo  = 'deepreinforce-ai/Ornith-1.0-35B-GGUF'
        files = @(@{ p='ornith-1.0-35b-bf16.gguf'; b=69376636800 })
        note  = '35B/A3B FULL PRECISION. Fastest of the set (~63 t/s at Q5). 262K ctx, MIT.'
    }
    'ornith-q8' = @{
        repo  = 'deepreinforce-ai/Ornith-1.0-35B-GGUF'
        files = @(@{ p='ornith-1.0-35b-Q8_0.gguf'; b=36903138880 })
        note  = '35B/A3B near-lossless, half the size of bf16.'
    }
    'glimmer' = @{
        repo  = 'unsloth/Muse-Glimmer-30B-GGUF'
        files = @(
            @{ p='Muse-Glimmer-30B-UD-Q4_K_XL.gguf'; b=15878222368 },
            @{ p='dflash-kquant.gguf';               b=1631205312  },
            @{ p='mmproj-kquant.gguf';               b=1400328928  }
        )
        # 30B DENSE (not MoE) + 1.8B vision encoder, 131K ctx, Apache-2.0, Meta Superintelligence Labs.
        # DENSE IS THE CATCH ON THIS BOX: every token reads ALL weights, so tg is set by the quant
        # size, not by an active-param count. Q4_K_XL (14.79 GB) is chosen over Q5_K_M (17.88 GB)
        # deliberately -- memory is not the constraint here (109 GiB), BANDWIDTH is, so the smaller
        # quant is the faster one.
        #   AMD measured 24 t/s on a Ryzen AI Max+ 395 (this exact chip), Windows + llama.cpp +
        #   Vulkan, WITH dFlash -> dflash-kquant.gguf is NOT optional. Pass via --spec-type draft-dflash.
        #   Do NOT back out the baseline using the 5090's 3.1x: Meta's card gives only 1.5-1.8x on
        #   Apple silicon, which is bandwidth-bound like this box (verifying a draft batch still
        #   re-reads all ~15 GB). At 1.5-1.8x, 24 t/s implies a ~14 t/s baseline, not ~8. Honest
        #   range unaccelerated: 8-15 t/s, likely nearer 14 -- Laguna territory, i.e. usable.
        #   SAMPLING per Meta: --temp 1.0 --top-p 0.95 --top-k 64  (NOT our 0.6/0.95/20 default).
        # ⚠️ arch `muse_glimmer` is ABSENT from b10182 AND b10338. Support merged to master in
        # PR #26841 at 2026-08-10 11:07Z, which is 4.5 h AFTER b10338 was tagged -- so it needs the
        # next release or a master build. PR #26842 (drafter optimisation) is still open/draft.
        note  = '30B DENSE +vision, 131K, Apache-2.0. MCP Atlas 75.5 vs Qwen3.6 62.5. Needs > b10338.'
    }
    'qwen38' = @{
        repo  = 'unsloth/Qwen3.8-27B-GGUF'
        files = @(
            @{ p='Qwen3.8-27B-UD-Q4_K_XL.gguf'; b=17923394624 },
            @{ p='mmproj-F16.gguf';             b=927607488   }
        )
        # 27B DENSE + vision, 262K ctx (1M via YaRN), Apache-2.0, Qwen. Sizes verified 2026-08-14.
        # HYBRID ATTENTION IS THE POINT: layout is 16 x (3 x GatedDeltaNet -> FFN | 1 x GatedAttn -> FFN),
        # so only 16 of 64 layers hold a KV cache. KV/token = 16 layers * 4 kv-heads * 256 head_dim
        # * 2 (K+V) * 2 B = 64 KiB. That is 8 GiB at 131072 and 16 GiB at 262144 -- roughly a quarter
        # of what a non-hybrid dense model of this shape would cost. 3 slots x FULL 262144 comes to
        # ~66 GiB all-in (16.7 weights + 48 KV + 0.9 mmproj), which fits the 109 GiB ceiling.
        # DENSE, so tg is set by quant size, not active params. MEASURED 2026-08-14 on b10431,
        # solo occupancy, greedy sampling (scripts\windows\bench-qwen38.ps1):
        #     no spec 11.33 t/s | draft-mtp n=3 20.27 t/s (1.79x) | at -c 262144 19.67 t/s
        # The pre-measurement estimate was 11-12 t/s raw; the raw figure landed at 11.33, but MTP
        # lifts the usable number to ~20. Do not quote the unaccelerated number as this model's speed.
        #   MTP IS EMBEDDED IN THE GGUF -- there is NO separate draft file, unlike laguna/glimmer.
        #   It appears in the load log as blk.64.nextn.* "unused tensor ... ignoring" until enabled.
        #   Enable with: --spec-type draft-mtp --spec-draft-n-max 3   <-- 3, NOT higher.
        #   n=4 drops to 16.53 and n=5 to 7.73, i.e. WORSE THAN NO SPECULATION. Depth is not
        #   monotonic: accepted length rises but acceptance falls, and rejected drafts cost a full
        #   verify pass. Stacking (draft-mtp,ngram-mod) is also a loss: 17.97.
        #   MTP and batching COMPETE (both use the batch dim): 1 user 20.27 vs 11.33 (MTP wins big),
        #   3 users aggregate 20.85 vs 23.82 (MTP loses mildly). Default stays MTP-on.
        #   -ctk/-ctv q8_0 is SPEED-NEUTRAL (20.23) and halves KV -- take it for context headroom.
        #   PREFILL is the long-context cost, not tg: 203 t/s @2k -> 97 t/s @44k, so a 44k prompt
        #   takes ~7.5 MINUTES to ingest. Generating at 262k is nearly free; filling it is not.
        #   (A third party on llama.cpp issue #27076 reported acceptance 0.735 / mean len 1.74 on a
        #   16 GB RX 6900 XT; we measure 0.603 / 2.78 at n=3 with everything resident.)
        #   SAMPLING per Qwen: thinking  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0
        #                      instruct  --temp 0.7 --top-p 0.80 --top-k 20 --presence-penalty 1.5
        # arch string is `qwen3_5`, ALREADY PRESENT in b10338 via qwen122b, so the grep-the-DLL trick
        # used for glimmer WOULD FALSE-POSITIVE here -- it rides the existing qwen3_5 loader and there
        # is no dedicated Qwen3.8 PR. LOAD TEST on b10431: loads clean and answers SHORT prompts
        # correctly (17*24=408, Canberra, 64). That check mattered -- a bad mapping can load and emit
        # FLUENT NONSENSE at a perfectly respectable t/s, which no speed number would ever reveal.
        # BUT THAT IS NOT A PROOF OF LONG-CONTEXT CORRECTNESS. partial_rotary_factor 0.25 and
        # mrope_interleaved are exactly the parameters that fail at DEPTH, not at ten tokens, and no
        # output from the 44k-prefill or 262k-context runs was ever read -- those were timed, not
        # inspected. Before trusting this model on long documents, bury a fact ~30k tokens deep and
        # ask for it back.
        # Vulkan risk NOT observed here: issue #27076 reports a `device lost` crash on multi-turn with
        # LCP slot reuse, but that is RADV/Linux/RDNA2. ~50 min of sweeping on Windows gfx1151 produced
        # zero device-lost events. Still worth watching under sustained multi-user load.
        # QUALITY IS UNMEASURED -- speed only. Run evals before trusting the vendor's benchmark card.
        note  = '27B DENSE +vision, hybrid KV (64 KiB/tok), 262K, Apache-2.0. 20.27 t/s w/ MTP n=3. Quality untested.'
    }
    'qwen38-quants' = @{
        repo  = 'unsloth/Qwen3.8-27B-GGUF'
        files = @(
            @{ p='Qwen3.8-27B-IQ4_XS.gguf';      b=15705861088 },
            @{ p='Qwen3.8-27B-UD-Q3_K_XL.gguf';  b=13441059904 }
        )
        # ⚠️ THE PREDICTION THAT MOTIVATED THIS ENTRY WAS REFUTED. It projected "tg scales ~1/filesize
        # because the model is dense": IQ4_XS ~23 t/s, UD-Q3_K_XL ~27 t/s. Measured 2026-08-14, both
        # came back SLOWER than the bigger quant they were supposed to beat:
        #
        #     UD-Q4_K_XL  16.69 GiB   20.06 t/s   <- biggest AND fastest
        #     IQ4_XS      14.63 GiB   19.63 t/s   (predicted ~23)
        #     UD-Q3_K_XL  12.52 GiB   18.17 t/s   (predicted ~27)
        #
        # Dequantisation ALU cost outweighs the bandwidth saved: Q4_K unpacks cheaply, IQ4_XS and
        # Q3_K do not. Below ~Q4_K you spend compute to save bandwidth you were not short of.
        # The note about Q5_K_XL being "bigger, therefore SLOWER" was the same reasoning and is
        # equally unsupported -- see the qwen38-highquants entry, which tests upward instead.
        # KEPT, not deleted: these files are the evidence for the refutation.
        # QUALITY COST IS UNMEASURED. Q3 on a 27B dense model is a real risk.
        note  = 'qwen38 SMALLER quants. Both measured SLOWER than UD-Q4_K_XL -- kept as evidence.'
    }
    'qwen38-highquants' = @{
        repo  = 'unsloth/Qwen3.8-27B-GGUF'
        files = @(
            @{ p='Qwen3.8-27B-Q6_K.gguf'; b=22884408288 },
            @{ p='Qwen3.8-27B-Q8_0.gguf'; b=29047086048 }
        )
        # THE OTHER HALF OF THE SWEEP. Every quant measured so far sits at or below UD-Q4_K_XL, so
        # "Q4_K_XL is optimal" only ever meant "it was the largest one tried" -- the identical error
        # the -ub sweep made when it tested 512/1024/2048 and called 512 the optimum, before testing
        # downward found 256. Smaller was measured slower; nobody has measured bigger.
        #
        # There is a real mechanism to test, not just symmetry. Q8_0 barely dequantises at all,
        # so if ALU cost is what made Q3/IQ4 slow, the cost curve should keep improving upward
        # even as bytes grow -- until bandwidth reclaims the lead. Where that crossover sits is the
        # measurement.
        #
        # MEMORY IS NOT THE CONSTRAINT and it is worth being blunt about it: Q8_0 is 27.05 GiB and
        # leaves ~74 GiB of the 109 GiB ceiling unused, even with the full 262K context at q8_0 KV
        # (~8 GiB). This box has been serving a 16.7 GiB model on a 109 GiB budget.
        # Q8_0 is also the quality endpoint -- ~99.3% fidelity to the unquantised model.
        note  = 'qwen38 BIGGER quants: Q6_K + Q8_0. Tests upward, which no sweep here has done.'
    }
    'qwen38-kl' = @{
        repo  = 'unsloth/Qwen3.8-27B-GGUF'
        files = @(
            @{ p='Qwen3.8-27B-Q4_K_M.gguf'; b=17106775008 },
            @{ p='Qwen3.8-27B-Q5_K_M.gguf'; b=19834055648 }
        )
        # THE QUALITY-A/B REPRODUCIBILITY SET (docs/BENCHMARKS.md Round 5, 2026-08-18). The A/B asked
        # which quant to SERVE, not which is fastest, by KL-divergence vs the Q8_0 reference (already
        # in qwen38-highquants) with `llama-perplexity --kl-divergence`. Fetch those two + this pair +
        # the default UD-Q4_K_XL (in 'qwen38') to reproduce the whole sweep.
        #
        #   RESULT (mean KLD vs Q8_0, lower = closer to reference):
        #     UD-Q4_K_XL  0.011165   <- WINNER, and it is already the serve default
        #     Q4_K_M      0.016814      (+34% divergence; +38% in the 99th-pct tail)
        #   Q4_K_M is 5.5% faster to generate but measurably further from reference, most on the hard
        #   tokens. Serve UD-Q4_K_XL. Q5_K_M is here because rounds 3-4 cite it (the up-side of the
        #   SPEED curve: -12% generation vs Q4_K_M for no measured quality gain over UD-Q4_K_XL).
        # Byte counts verified against the HF API 2026-08-18.
        note  = 'qwen38 quality-A/B arms: Q4_K_M (KL loser) + Q5_K_M. Reproduces BENCHMARKS Round 5.'
    }
    'qwen38-uncensored' = @{
        repo  = 'huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF'
        files = @(
            @{ p='Huihui-Qwen3.8-27B-abliterated-UD-Q4_K_XL.gguf'; b=17378626464; as='Qwen38-uncensored-UD-Q4_K_XL.gguf' },
            @{ p='mmproj-model-bf16.gguf';                         b=931145888;   as='mmproj-Qwen38-uncensored-bf16.gguf' }
        )
        # Abliterated (refusal-removed) Qwen3.8-27B -- SAME dense arch + quant as 'qwen38', so it
        # inherits qwen38's MEASURED tuning (draft-mtp, UD-Q4_K_XL/KL-best, +vision). 'as' gives it a
        # distinct on-disk name so it does not collide with the censored qwen38 quants. Byte counts
        # verified against the HF API 2026-08-25. run-router label: qwen38-uncensored.
        note  = 'Qwen3.8-27B ABLITERATED (uncensored) UD-Q4_K_XL + vision. Dense; inherits qwen38 tuning.'
    }
    'cyberstrike' = @{
        repo  = 'huihui-ai/Huihui-CyberStrike-OffSec-35B-abliterated-GGUF'
        files = @(
            @{ p='Huihui-CyberStrike-OffSec-35B-abliterated-Q5_K.gguf'; b=25347531968; as='CyberStrike-OffSec-35B-abliterated-Q5_K.gguf' },
            @{ p='mmproj-model-bf16.gguf';                              b=902822080;   as='mmproj-CyberStrike-OffSec-35B-bf16.gguf' }
        )
        # Abliterated offensive-security / pentest model. Arch is qwen35moe (MoE) -- SAME family as
        # Ornith, so the registered spec follows Ornith's MEASURED choice, ngram-mod. It DOES carry an
        # MTP head (header lists nextn_predict_layers), so draft-mtp also loads, but it is UNMEASURED
        # here -- A/B it with bench-spec.ps1 before preferring it. Byte counts verified 2026-08-25.
        # run-router label: cyberstrike.
        note  = 'CyberStrike-OffSec-35B ABLITERATED (uncensored, pentest) Q5_K + vision. MoE (qwen35moe).'
    }
    'flashnext' = @{
        repo  = 'unsloth/Qwen3.8-Flash-Next-GGUF'
        files = @(
            @{ p='UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf'; b=10946624 },
            @{ p='UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf'; b=49835229856 },
            @{ p='UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf'; b=43836407744 }
        )
        # PENDING ENGINE SUPPORT -- see docs/ROADMAP.md. arch=qwen4exp (Qwen4 preview, 180B MoE+SSM).
        # NOT loadable on b10431 or any current release; needs llama.cpp PR #27742 merged + shipped.
        # UD-IQ4_XS (87.2 GB) is the recommended fit under the ~109 GB ceiling (best quality that
        # still leaves ~22 GB for KV/compute). Byte counts verified vs HF API 2026-08-26.
        # UPDATE 2026-10-05: #27742 merged 2026-08-27; qwen4exp is in b11330+. Use b11408+ (k-pool re-reserve
        # abort fix #29958, indexer buffer halved #29825, Vulkan sparse FA for quantized KV #29639 = b11414).
        # Known on THIS box's setup: -np 2 can hang (#28280) -> serve with 1 slot; vision broken on Vulkan
        # (#29093). The 28.8 GB per_layer_token_embd table may be CPU-pinned (#29932) vs ~32 GB system RAM.
        # MTP draft: 'flashnext-mtp' (ggml-org, 2026-09-30; unsloth's 09-01 MTP files fail, #29174).
        note  = 'Qwen3.8-Flash-Next UD-IQ4_XS (qwen4exp, 125B/~6B active). Loads on b11408+; 1 slot, text-only on Vulkan.'
    }
    'flashnext-iq1' = @{
        repo  = 'unsloth/Qwen3.8-Flash-Next-GGUF'
        files = @(
            @{ p='UD-IQ1_S/Qwen3.8-Flash-Next-UD-IQ1_S-00001-of-00003.gguf'; b=10946624 },
            @{ p='UD-IQ1_S/Qwen3.8-Flash-Next-UD-IQ1_S-00002-of-00003.gguf'; b=49990818368 },
            @{ p='UD-IQ1_S/Qwen3.8-Flash-Next-UD-IQ1_S-00003-of-00003.gguf'; b=22544696352 }
        )
        # The 1.58-bit floor (67.6 GB) -- smallest fit, lowest quality on a 180B model. Kept as the
        # cheap fallback; prefer 'flashnext' (IQ4_XS). Same PENDING gate (PR #27742). Verified 2026-08-26.
        note  = 'Qwen3.8-Flash-Next UD-IQ1_S (1.58-bit fallback). Prefer flashnext (IQ4_XS); same caveats.'
    }
    'coder-next' = @{
        repo  = 'unsloth/Qwen3-Coder-Next-GGUF'
        files = @(
            @{ p='Qwen3-Coder-Next-UD-Q4_K_XL.gguf'; b=49608478720 }
        )
        # Qwen3-Coder-Next: 80B-total / 3B-active coding-agent MoE (512 experts, 10 active), 262K ctx,
        # NO vision (text-only), NO MTP head in config (spec via ngram-mod or a separate draft model).
        # Base model_type=qwen3_next -> llama.cpp arch **qwen3next** (CORRECTED 2026-09-16 from the GGUF
        # header; this comment used to say qwen4exp, which is Flash-Next's arch, not this one -- same
        # family, different arch string). REQUIRES bin-b11003 (or b10677); will NOT load on pinned bin\.
        # qwen3next is a linear-attention/SSM hybrid -- the #27805 risk class -- and is now VULKAN-VERIFIED
        # here: 12/12 byte-identical on b11003 at the serving ubatch, 2026-09-16. UD-Q4_K_XL is a single
        # 49.6 GB file (fits solo w/ room; ~50 GB could co-reside). Byte count verified vs HF API 2026-09-12.
        # SERVED on :8080 at -ub 1024 (a per-model override worth +34.8% deep prefill; see OPTIMIZATION.md).
        note  = 'Qwen3-Coder-Next UD-Q4_K_XL (80B/A3B coding MoE, qwen3next). Served on :8080 2026-09-16 -> 09-19 (history); Vulkan-verified. Needs its ub 1024 override.'
    }
    'ornith15' = @{
        repo  = 'ornith-ai/Ornith-1.5-35B-A3B-GGUF'
        files = @(
            @{ p='Ornith-1.5-35B-Q6_K.gguf';            b=29208731392 }
            @{ p='mmproj-Ornith-1.5-35B-BF16.gguf';     b=902822240 }
        )
        # Ornith-1.5-35B-A3B -- the GENUINE successor to the ornith-1.0-35b already here. Confirmed same
        # org: huggingface.co/deepreinforce-ai/Ornith-1.0-35B 307-redirects to ornith-ai/Ornith-1.0-35B
        # (the org was renamed, NOT a different publisher reusing the name -- an earlier note here got
        # that wrong). FIRST-PARTY GGUF (4.5M downloads), so best available provenance.
        # 36B total / ~3B ACTIVE MoE, model_type qwen3_5_moe -> llama.cpp arch 'qwen35moe', which is
        # ALREADY PRESENT in bin-b11003 (and in the pinned bin\, same arch as ornith-1.0). Standard
        # attention -- NOT an SSM/linear-attention hybrid -- so NO #27805 risk class.
        # 262144 native ctx (1M only via YaRN 4.0). MIT. VISION via the first-party mmproj above.
        # THINKING model: emits <think> blocks into reasoning_content -> budget max-tokens generously
        # or `content` comes back EMPTY (the exact gemma-4 trap). Sampling temp 0.6 / top-p 0.95 /
        # top-k 20 == the router's existing Qwen defaults, so no per-model sampler override needed.
        # Q6_K 27.2 GB + mmproj 0.84 GB CO-RESIDES with the 50 GB coder (~78 GB of ~109) -- which is the
        # point: it restores VISION to :8080 without giving up the text-only coder.
        # Q6_K over Q8_0 (35.2 GB) deliberately: the gemma A/B measured Q8_0 SLOWER with no quality gain
        # over Q6_K. That is a prior, not a measurement on THIS model -- A/B if it matters.
        # Vendor-reported SWE-bench Verified 79% / SWE-bench Pro 59.6% / Terminal-Bench 2.1 68.5% /
        # GPQA Diamond 89.2% -- SOURCED, UNMEASURED. docs/BENCHMARKS.md: decontaminated scores run ~4x
        # below self-reported. Do NOT rank it against the coder on these. Byte counts verified 2026-09-19.
        note  = 'Ornith-1.5-35B-A3B Q6_K + mmproj (36B/A3B, qwen35moe, MIT, VISION, thinking). Successor to ornith-1.0; co-resides with coder.'
    }
    'glm53-reap50' = @{
        repo  = 'patrickbdevaney/GLM-5.3-Flash-REAP50-GGUF'
        files = @(
            @{ p='GLM-5.3-Flash-REAP50-IQ4_XS.gguf';      b=88048752032 }
            @{ p='mmproj-GLM-5.3-Flash-REAP50-F16.gguf';  b=1128047424 }
        )
        # GLM-5.3-Flash, REAP50 (expert-pruned) -- the model this repo ruled out TWICE on size and once
        # on arch. BOTH blockers are now gone:
        #   * arch MERGED: PR #27773 merged 2026-09-30; 'glm5-next' confirmed present in bin-b11330.
        #   * REAP50 halves the experts so an HONEST 4-bit fits: IQ4_XS 82.0 GB (Q4_K_M 92.5 GB also
        #     fits). The UNPRUNED model only fit at 1-bit (UD-IQ1_S 93.1 GB) -- see 'glm53-flash'.
        # Header verified by range-fetching the first 1 MiB BEFORE downloading 82 GB (do this always):
        #   general.architecture = glm5-next, expert_count = 144 (halved by REAP), expert_used_count = 8,
        #   block_count = 46, context_length = 1048576, embedding_length = 4096.
        # NOTE 144 experts is BELOW 256, so llama.cpp #28501 (row-id hoisting above 256 experts) does
        # NOT apply here -- that win is coder-only. Do not expect it.
        # EXPECT IT TO BE SLOW: ~A18B active vs ornith15's ~3B, and REAP prunes TOTAL params, never
        # ACTIVE ones. tg is bandwidth-bound on active params, so budget ~10-15 t/s against ornith15's
        # 70.8. This is a bigger-brain/much-slower trade, not a free upgrade.
        # QUALITY IS UNMEASURED AND NOT MEASURABLE HERE (repo quality scores are withdrawn). At ~92 GB
        # you can have HALF the experts at 4-bit (this) or ALL of them at 1-bit (glm53-flash IQ1_S):
        # two different degradation modes at one footprint. Do not rank them without evidence.
        # 82 GB cannot co-reside with anything -- router-down operation. Byte-verified 2026-10-02.
        #
        # !! DOES NOT LOAD -- DO NOT RE-DOWNLOAD (tested 2026-10-02 on b11330 AND b11324) !!
        #   error loading model hyperparameters: key not found in model: glm5-next.attention.indexer.kpool
        # The GGUF carries indexer.head_count / key_length / top_k but NOT indexer.kpool, which
        # upstream requires. Arch IS supported (glm5-next present in b11330); the FILE is the problem.
        #
        # ROOT CAUSE + THE CHECK THAT CAUGHT IT: the repo's `lastModified` reads 2026-10-01, i.e.
        # AFTER glm5-next merged (#27773, 2026-09-30) -- which is why it looked safe. That field is
        # MISLEADING: it reflects ANY file change, and on 10-01 only README.md was touched. The
        # actual .gguf files were uploaded 2026-08-30/31, a MONTH BEFORE upstream support existed,
        # and the repo ships its own glm5-next-llama.cpp.patch + .bundle -- they were converted with
        # the author's private fork, whose metadata does not match what upstream settled on.
        # => ALWAYS check per-file `lastCommit.date` from the HF tree API, never repo lastModified.
        # (Repo-level lastModified was also the check used for the Nemotron entry below; it happened
        #  to be right there, but it is not a reliable signal.)
        #
        # Tried and rejected: b11324, the last build before #29805 ("clamp kpool re-pool bound",
        # 2026-10-01T19:55) -- fails identically, so kpool was required from the original merge and
        # no post-merge build will load this file.
        # GATE: a re-conversion with current upstream convert_hf_to_gguf.py. No other GLM-5.3 REAP
        # GGUF exists (checked 2026-10-02); the full 320B model only fits at 1-bit, which was
        # already judged not worth it. Re-check per-FILE dates before spending 82 GB again.
        note  = 'GLM-5.3-Flash REAP50 IQ4_XS (82 GB, glm5-next). !! WILL NOT LOAD -- converted 2026-08-30 with a pre-merge private fork, missing indexer.kpool. Needs upstream reconversion. Do not re-fetch. !!'
    }
    'ornith15-dflash' = @{
        repo  = 'na0x2c6/Ornith-1.5-35B-A3B-DFlash-GGUF'
        files = @(
            @{ p='Ornith-1.5-35B-A3B-DFlash-Q8_0.gguf'; b=421060960 }
            @{ p='Ornith-1.5-35B-A3B-DFlash-BF16.gguf'; b=782819680 }
        )
        # DFlash block-diffusion DRAFT model for the SERVED ornith15 -- a speed lever, not a model.
        # Base is FIRST-PARTY: ornith-ai/Ornith-1.5-35B-A3B-DFlash (published 2026-09-28, MIT, tagged
        # speculative-decoding-draft / block-diffusion). These GGUFs are a THIRD-PARTY conversion
        # (na0x2c6) of a custom_code model -- confirm it actually loads and that acceptance > 0 before
        # trusting any speedup number; a speculator that silently fails to engage reads as 1.00x, not
        # as an error. GGUF arch is 'dflash' (confirmed by range-fetching the header), present in b11046.
        # Usage: --spec-type draft-dflash --spec-draft-model <this> --spec-draft-n-max N
        #   (both --spec-draft-model and --model-draft are valid aliases in b11046 -- verified in --help,
        #    which resolves the long-standing UNVERIFIED note in stage-nextgen.ps1.)
        # WHY IT MATTERS HERE: ornith15's current draft-mtp peaks at only 1.11x (measured 2026-09-19),
        # far below qwen38's 1.79x. A dedicated draft has much more room. draft-mtp and draft-dflash are
        # MUTUALLY EXCLUSIVE -- whichever wins REPLACES the other in run-router's $known.
        # Two quants on purpose: Q8_0 drafts faster, BF16 should accept more often, and for speculative
        # decoding that tradeoff is the whole game. Both are negligible on disk. Byte-verified 2026-10-02.
        note  = 'DFlash draft for ornith15 (Q8_0 0.39 GB + BF16 0.73 GB, arch dflash). Speed lever: A/B vs draft-mtp n=3 (current 1.11x).'
    }
    'nemotron-puzzle-q6' = @{
        repo  = 'RemySkye/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-GGUF'
        files = @(
            @{ p='NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-Q6_K.gguf'; b=67243104384; as='Nemotron-3-Puzzle-75B-A9B-Q6_K.gguf' }
        )
        # NVIDIA Nemotron-3-Puzzle: NAS-derived ("Puzzle") Nemotron-H variant, 75B total / 9B ACTIVE.
        # arch = 'nemotron_h_moe' -- CONFIRMED before downloading by HTTP range-fetching the first 1 MiB
        # of this exact file and reading general.architecture out of the GGUF header (cheap preflight;
        # do this before committing to any 60 GB+ pull). Present in bin-b11003 AND bin-b10677.
        # Arch support merged upstream in PR #25444; it maps onto the existing nemotron_h_moe id rather
        # than carrying a distinct 'puzzle' string.
        # WHY Q6_K and not Q4: 62.6 GB of a ~109 GB ceiling leaves ~45 GB for KV/compute, so the usual
        # reason to drop to Q4 (fit) does not apply on this box -- spend the headroom on quant instead.
        #
        # !! DOES NOT LOAD -- DO NOT RE-DOWNLOAD (measured 2026-09-16, 62.6 GB pulled and byte-verified) !!
        # b11003 refuses it:
        #   load_arch_tensors: layer 88 declares neither expert_feed_forward_length nor
        #   expert_used_count, cannot determine the expert FFN size
        # This is NOT a bad quant and NOT our config. Puzzle is NAS-derived and genuinely heterogeneous:
        # the GGUF stores per-layer arrays (90 entries) in which 49 layers are legitimately 0 because they
        # are Mamba-2/attention layers with no expert FFN. block_count=90, nextn_predict_layers=2, so
        # layers 88-89 are the MTP block; 88 holds nextn.* + attention tensors and NO ffn_*_exps, so its 0
        # is correct. Verified by decoding the header here.
        # ROOT CAUSE (upstream, confirmed): every published Puzzle GGUF was converted from the #25444
        # REVIEW BRANCH and uses an MTP layout master does not read. PR #28779 (merged 2026-09-13, present
        # in b11003) only converts the old SIGFPE into this clean error -- its own description says the
        # files "need reconverting with the current converter". A NEWER BUILD WILL NOT HELP.
        # All four publishers predate the fix (lastModified checked 2026-09-16): RemySkye 07-14,
        # YanissAmz 07-08, MRockatansky 08-03, Myric 09-09. Re-check for a post-2026-09-13 re-upload
        # before spending the bandwidth again; otherwise the only path is converting from the BF16
        # safetensors (~150 GB) with a current convert_hf_to_gguf.py.
        # LICENSE: OpenMDW v1.1 -- NOT Apache/MIT like the rest of this registry.
        # If it ever loads: Mamba-2 state is view-aliased -> #27805 risk class -> run the stage-nextgen.ps1
        # determinism diff first. 9B active is 3x the coder's, so expect materially LOWER tg than the
        # coder's 44 t/s (tg is bandwidth-bound on ACTIVE params). It DOES have an MTP head
        # (nextn_predict_layers=2) so draft-mtp would be available. Byte count verified 2026-09-16.
        note  = 'Nemotron-3-Puzzle-75B-A9B Q6_K (62.6 GB, nemotron_h_moe). !! WILL NOT LOAD -- all published GGUFs use a stale MTP layout; needs reconversion upstream. Do not re-fetch. !!'
    }
    'writer-plus-35b' = @{
        repo  = 'mradermacher/creative-writer-plus-35b-preview-01-2025-i1-GGUF'
        files = @(
            @{ p='creative-writer-plus-35b-preview-01-2025.i1-Q4_K_M.gguf'; b=21527052480; as='creative-writer-plus-35b-Q4_K_M.gguf' }
        )
        # Dedicated CREATIVE-WRITING finetune (jukofyork 'Control Adapters' method), base = Command-R 35B
        # -> arch 'command-r' (PRESENT in bin-b10677; standard attention, NOT a next-gen/SSM arch, so NO
        # #27805 Vulkan risk -- safe to serve as-is). Dense 35B; i1 (imatrix) Q4_K_M 21.5 GB co-resides
        # with the router (~20 GB alongside qwen38+ornith). Tuned for prose/fiction, weak at code by
        # design. Serve at writing sampling (--temp 0.7-0.9), NOT Qwen greedy. Quality is SUBJECTIVE and
        # unmeasured here (repo withdrew quality scores) -- A/B by eye vs Ornith. Byte verified 2026-09-12.
        note  = 'creative-writer-plus-35b i1-Q4_K_M (Command-R prose finetune, 21.5 GB, co-resident). Text-focused; A/B vs Ornith.'
    }
    'gemma4-ablit' = @{
        repo  = 'bullerwins/Huihui-gemma-4-26B-A4B-it-abliterated-GGUF'
        files = @(
            @{ p='Huihui-gemma-4-26B-A4B-it-abliterated-Q4_K_M.gguf'; b=16796011168; as='gemma4-26B-A4B-abliterated-Q4_K_M.gguf' }
        )
        # ABLITERATED (huihui, refusal-removed) Gemma-4-26B-A4B-it -- 26B-total/4B-active MoE, arch
        # gemma4 (PRESENT in bin-b10677; standard attention, NO #27805 Vulkan risk). Strong general
        # PROSE + uncensored: the abliterated writing counterpart to creative-writer-plus-35b (which is
        # NOT abliterated, only a permissive Command-R base). 4B active -> fast tg; ~16.8 GB Q4_K_M
        # co-resides easily; gemma4 KV is GQA (small), so it does NOT have command-r's huge-KV problem.
        # Text-only GGUF (no mmproj in this repo). Serve at writing sampling (temp 0.7-0.9). Same huihui
        # abliteration lineage as qwen38-uncensored/cyberstrike. Byte verified vs HF API 2026-09-12.
        note  = 'Gemma-4-26B-A4B ABLITERATED (huihui) Q4_K_M, 16.8 GB MoE. Uncensored prose, fast (A4B), co-resident. arch gemma4.'
    }
    'gemma4-ablit-q6' = @{
        repo  = 'bullerwins/Huihui-gemma-4-26B-A4B-it-abliterated-GGUF'
        files = @(
            @{ p='Huihui-gemma-4-26B-A4B-it-abliterated-Q6_K.gguf'; b=22638394528; as='gemma4-26B-A4B-abliterated-Q6_K.gguf' }
        )
        # Higher-quality quant of gemma4-ablit for the quality/speed A/B (same huihui abliteration
        # lineage as the Q4_K_M). Q6_K = near-lossless. Byte verified vs HF API 2026-09-12.
        note  = 'Gemma-4-26B-A4B ABLITERATED Q6_K, 22.6 GB (near-lossless). Quality arm of the fast-vs-good A/B.'
    }
    'gemma4-mmproj' = @{
        repo  = 'unsloth/gemma-4-26B-A4B-it-GGUF'
        files = @(
            @{ p='mmproj-F16.gguf'; b=1193058784; as='mmproj-gemma-4-26B-A4B-f16.gguf' }
        )
        # Vision projector for gemma4-ablit -- the abliterated GGUF repo (bullerwins/Huihui) ships NO
        # mmproj, but abliteration only edits the LM (refusal directions), NOT the vision tower, so the
        # BASE gemma-4-26B-A4B projector pairs with the abliterated Q6_K weights. Enables image input on
        # the 'gemma' router model. Byte verified vs HF API 2026-09-13. run-router 'gemma' entry -> mmproj.
        note  = 'Gemma-4-26B-A4B vision mmproj (F16, 1.19 GB, from base repo). Pairs with the abliterated LM.'
    }
    'gemma4-ablit-q8' = @{
        repo  = 'bullerwins/Huihui-gemma-4-26B-A4B-it-abliterated-GGUF'
        files = @(
            @{ p='Huihui-gemma-4-26B-A4B-it-abliterated-Q8_0.gguf'; b=26859854496; as='gemma4-26B-A4B-abliterated-Q8_0.gguf' }
        )
        # Max-quality practical quant (Q8_0 ~ reference) for the A/B. Biggest -> slowest tg (more bytes
        # per token on the 4B active set), so it is the 'good' extreme vs Q4's 'fast'. Verified 2026-09-12.
        note  = 'Gemma-4-26B-A4B ABLITERATED Q8_0, 26.9 GB (max quality). Slow/good extreme of the A/B.'
    }
    'flashnext-mtp' = @{
        repo  = 'ggml-org/Qwen3.8-Flash-Next-GGUF'
        files = @(
            @{ p='mtp-Qwen3.8-Flash-Next-Q8_0.gguf'; b=4137429280 }
        )
        # MTP draft head for 'flashnext' (--spec-type draft-mtp --model-draft ...). ggml-org upload dated
        # 2026-09-30 (per-file lastCommit). unsloth's 2026-09-01 MTP files fail with "tensor not found" (#29174).
        note  = 'MTP draft for Qwen3.8-Flash-Next (Q8_0, 4.1 GB). Pair with flashnext.'
    }
    'holo4' = @{
        repo  = 'bartowski/Hcompany_Holo4-35B-A3B-GGUF'
        files = @(
            @{ p='Hcompany_Holo4-35B-A3B-Q6_K.gguf';         b=30738578112 }
            @{ p='mmproj-Hcompany_Holo4-35B-A3B-bf16.gguf';  b=902822432 }
        )
        # H Company Holo4-35B-A3B (2026-09-24, Apache-2.0): computer-use/agentic finetune on the qwen35moe
        # arch -- the SAME arch as ornith15, so no new engine risk. Vendor claims OSWorld 2.0 30.9% (CLAIMED).
        # Files dated 2026-09-29/30 (per-file lastCommit), byte counts from the HF tree API 2026-10-05.
        note  = 'Holo4-35B-A3B Q6_K + vision (qwen35moe, 3B active, Apache-2.0). Agentic/computer-use.'
    }
    'ling3-vl' = @{
        repo  = 'bartowski/Ling-3.0-flash-VL-GGUF'
        files = @(
            @{ p='Ling-3.0-flash-VL-Q4_K_M/Ling-3.0-flash-VL-Q4_K_M-00001-of-00002.gguf'; b=39487785120 }
            @{ p='Ling-3.0-flash-VL-Q4_K_M/Ling-3.0-flash-VL-Q4_K_M-00002-of-00002.gguf'; b=39173735424 }
            @{ p='mmproj-Ling-3.0-flash-VL-bf16.gguf';                                     b=878174272 }
        )
        # inclusionAI Ling-3.0-flash-VL: 124B / ~5.5B active, 512 experts (#28501 applies), MIT, image+video,
        # tools. Arch bailingmoe3 (+ VL via #29151, merged 2026-09-24). KDA/linear-attention hybrid ->
        # run the #27805-class determinism gate first. GGUF context_length 131072 (256K needs YaRN).
        note  = 'Ling-3.0-flash-VL Q4_K_M 78.7 GB + vision (bailingmoe3, 124B/5.5B active, MIT).'
    }
    # ---- IMAGE GENERATION (stable-diffusion.cpp sd-server, not llama.cpp) --------------------------------
    # Qwen-Image-2.1 (Qwen, 2026-09): #1 open-weights model on Artificial Analysis for BOTH text-to-image
    # (1041) and editing (1074) as of 2026-10-15. 7.1B MMDiT + Qwen3-VL-8B text encoder + its own VAE.
    # LICENCE: Qwen Research licence -- NON-COMMERCIAL (HF card). Byte counts + per-file dates from the HF
    # tree API 2026-10-15. Files must be used together: diffusion + vae (this entry) + 'qwen-image-21-te'.
    'qwen-image-21' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/Qwen-Image-2.1'
        files = @(
            @{ p='diffusion_models/qwen_image_2.1_bf16.safetensors';       b=14230280616 }   # base, 40 steps, CFG ~6
            @{ p='diffusion_models/qwen_image_2.1_turbo_bf16.safetensors'; b=14230280616 }   # Turbo, 8 steps, CFG 1 (2026-10-09)
            @{ p='vae/qwen_image_2.1_vae_bf16.safetensors';                b=675509688 }     # NOT interchangeable with Qwen-Image/Wan VAEs
        )
        note  = 'Qwen-Image-2.1 base + Turbo (bf16) + VAE. Image gen+edit via sd-server. NON-COMMERCIAL licence.'
    }
    'qwen-image-21-te' = @{
        dir   = 'image'
        repo  = 'Qwen/Qwen3-VL-8B-Instruct-GGUF'
        files = @(
            @{ p='Qwen3VL-8B-Instruct-F16.gguf';        b=16388044896 }
            @{ p='mmproj-Qwen3VL-8B-Instruct-F16.gguf'; b=1159029824 }    # vision tower: needed for EDITS (--llm_vision)
        )
        # F16 GGUF on purpose: this driver's largest single Vulkan allocation is 2 GiB, and sd.cpp #1718
        # (Windows, Strix Halo) crashed allocating a 2.49 GB F32 token table from an FP8 encoder file.
        # F16 keeps that table at ~1.24 GB.
        note  = 'Qwen3-VL-8B text encoder (F16 GGUF) + vision mmproj, for Qwen-Image-2.1.'
    }
    'qwen-image-21-turbo-q8' = @{
        dir   = 'image'
        repo  = 'unsloth/Qwen-Image-2.1-Turbo-GGUF'
        files = @(
            @{ p='qwen-image-2.1-turbo-Q8_0.gguf'; b=7640860480 }
        )
        # Q8_0 sampled ~25% faster than the bf16 safetensors on this Vulkan driver (512^2, 8 steps:
        # 33.8 s vs 46.0 s, 2026-10-15). File dated 2026-10-10 (per-file lastCommit).
        note  = 'Qwen-Image-2.1 Turbo, Q8_0 GGUF (8 steps). Faster than bf16 on Vulkan here.'
    }
    # ---- Uncensored image models (adult content; added at the box owner's request 2026-10-15) --------------
    # Picked from CivitAI's monthly top checkpoints + HF (2026-10-15): photoreal NSFW has moved to Krea 2
    # fine-tunes; Kroma is the Chroma author's Krea 2 fine-tune on the Chroma dataset. Anime: Anima.
    # All HF, ungated. Byte counts + per-file dates from the HF tree API 2026-10-15.
    'kroma' = @{
        dir   = 'image'
        repo  = 'voldemir/Kroma-GGUF'
        files = @(
            @{ p='kroma-v0.3-turbo.q8_0.gguf'; b=13621775872 }   # Q8_0: 2.4x faster than bf16 on this Vulkan driver
        )
        # LICENCE: MIT for Kroma's weights, but the Krea 2 Community License still applies (commercial cap,
        # deployer content-filter clause, bans non-consensual intimate imagery). 12.9B DiT, turbo: ~8-12
        # steps, CFG 1. Text encoder + VAE are in 'kroma-te'.
        note  = 'Kroma v0.3 Turbo Q8_0 (Krea 2 fine-tune, uncensored, 12.9B). Licence: MIT + Krea 2 Community License.'
    }
    'kroma-te' = @{
        dir   = 'image'
        repo  = 'Qwen/Qwen3-VL-4B-Instruct-GGUF'
        files = @(
            @{ p='Qwen3VL-4B-Instruct-Q8_0.gguf'; b=4280406144 }
        )
        note  = 'Qwen3-VL-4B text encoder (Q8_0) for Kroma / Krea 2. NOT the fp8 encoder (sd.cpp #1708).'
    }
    'wan21-vae' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/Wan_2.1_ComfyUI_repackaged'
        files = @(
            @{ p='split_files/vae/wan_2.1_vae.safetensors'; b=253815318 }
        )
        note  = 'Wan 2.1 VAE -- the VAE sd.cpp docs/krea2.md specifies for Krea 2 / Kroma.'
    }
    'anima' = @{
        dir   = 'image'
        repo  = 'vanes430/Anima-Turbo-V1.1-GGUF'
        files = @(
            @{ p='anima-turbo-v1.1-Q8_0.gguf'; b=2239471744 }
        )
        # Only the official 2B Anima works in sd.cpp; layer-expanded "2.9B" CivitAI variants render broken
        # (sd.cpp #1877). LICENCE: CircleStone non-commercial + NVIDIA Open Model License (outputs usable).
        note  = 'Anima Turbo v1.1 Q8_0 (anime/illustration, uncensored, 2B). Non-commercial licence. Needs anima-te.'
    }
    'anima-te' = @{
        dir   = 'image'
        repo  = 'circlestone-labs/Anima'
        files = @(
            @{ p='split_files/text_encoders/qwen_3_06b_base.safetensors'; b=1192135096 }
            @{ p='split_files/vae/qwen_image_vae.safetensors';            b=253806246 }
        )
        note  = 'Anima text encoder (Qwen3 0.6B base) + Qwen-Image VAE.'
    }
    # ---- Z-Image Turbo: the fast general model (added 2026-10-15) ------------------------------------------
    # Tongyi-MAI's 6B distilled DiT, 8 steps at CFG 1, Apache-2.0 (the only commercially usable model in
    # the image registry). Still the current Turbo release (HF lastModified 2026-01-30). leejet's GGUF is
    # the one sd.cpp docs/z_image.md links, from the sd.cpp author.
    'z-image-turbo' = @{
        dir   = 'image'
        repo  = 'leejet/Z-Image-Turbo-GGUF'
        files = @(
            @{ p='z_image_turbo-Q8_0.gguf'; b=6577440704 }
        )
        note  = 'Z-Image-Turbo Q8_0 (6B, 8 steps, Apache-2.0). Needs z-image-te.'
    }
    'z-image-te' = @{
        dir   = 'image'
        # Text encoder: Z-Image ships the ORIGINAL Qwen3-4B (its text_encoder shards 1-2 have the same LFS
        # sha256 as Qwen/Qwen3-4B's, checked 2026-10-15), not the 2507 Instruct the sd.cpp doc example uses.
        # So the official Qwen Q8_0 GGUF. VAE: the FLUX.1 autoencoder, from Comfy-Org's ungated repackage.
        repo  = 'Qwen/Qwen3-4B-GGUF'
        files = @(
            @{ p='Qwen3-4B-Q8_0.gguf'; b=4280404704 }
        )
        note  = 'Qwen3-4B text encoder (Q8_0) for Z-Image. Also needs flux-ae.'
    }
    'flux-ae' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/z_image_turbo'
        files = @(
            @{ p='split_files/vae/ae.safetensors'; b=335304388 }
        )
        note  = 'FLUX.1 VAE (ae.safetensors) -- the VAE Z-Image uses.'
    }
    # ---- FLUX.3 Image Klein (BFL, released 2026-10-15; added 2026-10-16) ------------------------------------
    # Needs sd.cpp master-968-8cd731e or newer (FLUX.3 support is #2143, one commit after master-967).
    # LICENCE: FLUX Kommunity License v1.0 -- free commercial use under $5M annual revenue, else non-commercial;
    # bans NCII/CSAM. The official repo is gated (click-through); this is an ungated sd.cpp GGUF conversion of it.
    'flux3-klein' = @{
        dir   = 'image'
        repo  = 'akhaliq/flux-3-image-klein-sd-gguf'
        files = @(
            @{ p='flux3_image_klein_sd-Q8_0.gguf'; b=5991748384 }   # 5.6B, distilled: 16 steps, CFG 1; edits with up to 10 refs
        )
        note  = 'FLUX.3 Image Klein Q8_0 (5.6B, gen + edit). FLUX Kommunity License. Needs flux2-vae + kroma-te (Qwen3-VL-4B).'
    }
    'flux2-vae' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/flux2-klein-4B'
        files = @(
            @{ p='split_files/vae/flux2-vae.safetensors'; b=336211292 }   # identical size to FLUX.3's own ae.safetensors
        )
        note  = 'FLUX.2 VAE -- used by FLUX.2 klein and FLUX.3 Image Klein.'
    }
    # ---- Image extras (added 2026-10-16): ESRGAN upscalers, YOLOv8 detectors, IP-Adapter, LTX video -----------
    # Sub-folders under the models dir: upscalers\ (ESRGAN) and detectors\ (YOLOv8, sd.cpp layout).
    'upscalers' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/Real-ESRGAN_repackaged'
        files = @(
            @{ p='RealESRGAN_x4plus.safetensors'; b=66857836; as='upscalers\RealESRGAN_x4plus.safetensors' }   # BSD-3, photos
        )
        note  = 'RealESRGAN x4plus (4x photo upscaler, BSD-3) for Upscale and hires fix.'
    }
    'upscaler-anime' = @{
        dir   = 'image'
        repo  = 'hlky/RealESRGAN_x4plus_anime_6B'
        files = @(
            @{ p='diffusion_pytorch_model.safetensors'; b=17888804; as='upscalers\RealESRGAN_x4plus_anime_6B.safetensors' }
        )
        note  = 'RealESRGAN x4plus anime 6B (4x, anime/illustration), safetensors repack.'
    }
    'upscaler-ultrasharp' = @{
        dir   = 'image'
        repo  = 'Kim2091/UltraSharp'
        files = @(
            @{ p='4x-UltraSharp.safetensors'; b=66864028; as='upscalers\4x-UltraSharp.safetensors' }
        )
        note  = '4x-UltraSharp (detail-preserving 4x upscaler). LICENCE CC BY-NC-SA 4.0 (non-commercial).'
    }
    'adetailer' = @{
        dir   = 'image'
        repo  = 'exeterminal/adetailer-yolov8-safetensors'
        files = @(
            @{ p='face_yolov8n.safetensors'; b=6033980;  as='detectors\face_yolov8n.safetensors' }
            @{ p='face_yolov8s.safetensors'; b=22284028; as='detectors\face_yolov8s.safetensors' }
            @{ p='hand_yolov8n.safetensors'; b=6033980;  as='detectors\hand_yolov8n.safetensors' }
        )
        # Bingsu's ADetailer YOLOv8 detectors, converted to sd.cpp's convert_yolov8_to_safetensors.py layout
        # (the metadata yolov8.variant / names / reg_max match what that converter writes). AGPL-3.0 like YOLOv8.
        note  = 'ADetailer face/hand detectors (YOLOv8, sd.cpp safetensors layout). AGPL-3.0.'
    }
    'ipadapter-sdxl' = @{
        dir   = 'image'
        repo  = 'h94/IP-Adapter'
        files = @(
            @{ p='sdxl_models/ip-adapter_sdxl_vit-h.safetensors'; b=698391064 }
        )
        # The PLAIN adapter on purpose: ip-adapter-PLUS_sdxl_vit-h washed every colour out to near-greyscale
        # on this box (WAI-illustrious, CFG 6, strengths 0.35-0.7, 2026-10-16); the plain one keeps full colour.
        note  = 'IP-Adapter for SDXL (image prompt), ViT-H. Apache-2.0. Needs clip-vision-h.'
    }
    'clip-vision-h' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/Wan_2.1_ComfyUI_repackaged'
        files = @(
            @{ p='split_files/clip_vision/clip_vision_h.safetensors'; b=1264219396 }
        )
        note  = 'CLIP-Vision ViT-H/14 image encoder (IP-Adapter, Wan 2.1 I2V).'
    }
    'ltx23' = @{
        dir   = 'image'
        repo  = 'unsloth/LTX-2.3-GGUF'
        files = @(
            @{ p='distilled-1.1/ltx-2.3-22b-distilled-1.1-Q8_0.gguf';                     b=22755540000 }
            @{ p='text_encoders/ltx-2.3-22b-distilled_embeddings_connectors.safetensors'; b=2312144712 }
            @{ p='vae/ltx-2.3-22b-distilled_video_vae.safetensors';                       b=1452256522 }
            @{ p='vae/ltx-2.3-22b-distilled_audio_vae.safetensors';                       b=364853140 }
        )
        # LTX-2.3 distilled 1.1 (Lightricks, 22B): t2v / i2v / first+last frame, WITH AUDIO, 8 steps at CFG 1.
        # LICENCE: LTX-2 Community License (free incl. commercial under $10M annual revenue).
        note  = 'LTX-2.3 distilled-1.1 Q8_0 + connectors + video/audio VAE. Needs ltx23-te.'
    }
    'ltx23-te' = @{
        dir   = 'image'
        repo  = 'unsloth/gemma-3-12b-it-GGUF'
        files = @(
            @{ p='gemma-3-12b-it-Q8_0.gguf'; b=12510212576 }
        )
        note  = 'Gemma 3 12B (Q8_0): the LTX-2.3 text encoder. Gemma terms of use.'
    }
    'minimax-h3' = @{
        dir   = 'image'
        repo  = 'unsloth/MiniMax-H3-GGUF'
        files = @(
            @{ p='minimax_h3_fl2va_pruned-Q8_0.gguf';                 b=21437786208 }
            @{ p='qwen3vl_32b_minimax_h3-Q4_K_M.gguf';                b=18218065024 }   # same bytes as leejet/MiniMax-H3-GGUF
            @{ p='vae/minimax_h3_video_vae_fp16.safetensors';         b=5207808496 }    # same bytes as Comfy-Org/MiniMax-H3
            @{ p='vae/minimax_h3_audio_vae_fp32.safetensors';         b=605254808 }
        )
        # MiniMax H3 (33B dense, pruned FL2VA): text->video and first/last-frame->video WITH STEREO SOUND, 24 fps.
        # stable-diffusion.cpp supports it since ea7f0c8 (2026-08-04). LICENCE: MiniMax H3 Community License --
        # its Applicable Territory EXCLUDES the EU, UK, US and South Korea; commercial use needs "MiniMax H3" shown
        # in the UI and written authorisation above $20M revenue.
        note  = 'MiniMax H3 FL2VA pruned Q8_0 + Qwen3-VL-32B (H3 variant) Q4_K_M + video/audio VAE. Licence excludes EU/UK/US/KR.'
    }
    'minimax-h3-turbo' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/MiniMax-H3'
        files = @(
            @{ p='loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'; b=1956193000; as='loras\minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors' }
        )
        # lightx2v's 8-step turbo LoRA (Apache-2.0). MEASURED 2026-10-16, 864x480 x 56 frames: 873 s at 20 steps
        # without it -> 409 s at 8 steps with it, same seed, at least as good a picture, fuller sound.
        note  = 'MiniMax H3 8-step turbo LoRA (lightx2v, Apache-2.0) -- the registry applies it by default.'
    }
    # ---- Video: Wan 2.2 (added 2026-10-15; all Apache-2.0, ungated) --------------------------------------
    # sd-server master-967 serves video on /sdcpp/v1/vid_gen (PR #1437). Byte counts from the HF tree API.
    'wan22-ti2v-turbo' = @{
        dir   = 'image'
        repo  = 'hum-ma/Wan2.2-TI2V-5B-Turbo-GGUF'
        files = @(
            @{ p='Wan2_2-TI2V-5B-Turbo-Q8_0.gguf'; b=5404990176 }   # quanhaol's 4-step Turbo of Wan2.2-TI2V-5B (origin repo since made private)
        )
        note  = 'Wan 2.2 TI2V-5B Turbo Q8_0: text->video AND image->video, 4 steps, 24 fps. Needs wan-umt5 + wan22-vae.'
    }
    'wan22-i2v-a14b-4step' = @{
        dir   = 'image'
        repo  = 'jayn7/WAN2.2-I2V_A14B-DISTILL-LIGHTX2V-4STEP-GGUF'
        files = @(
            @{ p='high_noise_260412/wan2.2_i2v_A14b_high_noise_lightx2v_4step_720p_260412-Q8_0.gguf'; b=15416449664 }
            @{ p='low_noise_260412/wan2.2_i2v_A14b_low_noise_lightx2v_4step_720p_260412-Q8_0.gguf';  b=15416449664 }
        )
        # lightx2v's distilled Wan2.2-I2V-A14B (2 experts: high-noise + low-noise), 4 steps, CFG 1, 16 fps.
        # Uses the Wan 2.1 VAE ('wan21-vae'), no clip_vision.
        note  = 'Wan 2.2 I2V-A14B lightx2v 4-step distilled Q8_0 (2 x 15.4 GB): quality image->video. Needs wan-umt5 + wan21-vae.'
    }
    'wan-umt5' = @{
        dir   = 'image'
        repo  = 'city96/umt5-xxl-encoder-gguf'
        files = @(
            @{ p='umt5-xxl-encoder-Q8_0.gguf'; b=6043068256 }
        )
        note  = 'umt5-xxl text encoder (Q8_0) shared by every Wan model.'
    }
    'wan22-vae' = @{
        dir   = 'image'
        repo  = 'Comfy-Org/Wan_2.2_ComfyUI_Repackaged'
        files = @(
            @{ p='split_files/vae/wan2.2_vae.safetensors'; b=1409400960 }
        )
        note  = 'Wan 2.2 VAE -- TI2V-5B only (the A14B models use the Wan 2.1 VAE).'
    }
    'qwen-image-21-q8' = @{
        dir   = 'image'
        repo  = 'leejet/Qwen-Image-2.1-GGUF'
        files = @(
            @{ p='qwen_image_2.1-Q8_0.gguf'; b=7687155744 }
        )
        note  = 'Qwen-Image-2.1 base, Q8_0 GGUF (fallback if bf16 is slow/broken on Vulkan).'
    }
    'glm53-flash' = @{
        repo  = 'unsloth/GLM-5.3-Flash-GGUF'
        files = @(
            @{ p='UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00001-of-00003.gguf'; b=9429859 },
            @{ p='UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00002-of-00003.gguf'; b=49621122496 },
            @{ p='UD-IQ1_S/GLM-5.3-Flash-UD-IQ1_S-00003-of-00003.gguf'; b=43456692608 }
        )
        # PENDING ENGINE SUPPORT -- see docs/ROADMAP.md. arch=glm5_next (320B-A18B). Only the 1-bit
        # quant fits the ~109 GB ceiling: UD-IQ1_S 93.1 GB; everything >= IQ3 is 120-200 GB (over).
        # 1-bit on a 320B MoE is a harsh cut -- quality UNMEASURED. llama.cpp PR #27752 is
        # ready-for-review but NOT merged (glm5_next absent from b10665). Do NOT download 93 GB until
        # it merges AND Vulkan (#27805) is trustworthy. Byte counts verified vs HF API 2026-08-28.
        # 2026-10-05: these files declare general.architecture = 'glm5next' (NO hyphen) -- a pre-merge
        # name. Upstream merged it as 'glm5-next' (2026-09-30, in b11330), so b11330+ rejects them as an
        # unknown arch. The post-merge ggml-org/GLM-5.3-Flash-GGUF starts at Q2_K 133.8 GB -- over budget.
        note  = 'GLM-5.3-Flash UD-IQ1_S (93.1 GB). !! WILL NOT LOAD -- arch string glm5next (pre-merge); upstream is glm5-next. Do not re-fetch. !!'
    }
    'dflash2-qwen38' = @{
        repo  = 'incoai/Qwen3.8-27B-DFlash2-GGUF'
        files = @(
            @{ p='Qwen3.8-27B-DFlash2-Q4_K_M.gguf'; b=1143006752 }
        )
        # DFlash2 block-diffusion DRAFT model for Qwen3.8-27B speculative decoding -- NOT a standalone
        # model (the router discovery loop excludes 'dflash' files from serving targets). Use as a draft
        # with --spec-type draft-dflash. arch support MERGED (PR #27342) BUT BLOCKED on Vulkan by issue
        # #27805 (verifier accepts wrong tokens) -- do NOT use on this box until #27805 is fixed. And in
        # llama.cpp its ~1.8x decode ~= our existing draft-mtp anyway. Q8_0 (2.06 GB) / BF16 (3.86 GB)
        # also exist; Q4_K_M is smallest. See docs/ROADMAP.md. Byte count vs HF API 2026-08-28.
        note  = 'DFlash2 DRAFT for qwen38 (Q4_K_M 1.1 GB). PENDING Vulkan fix #27805 -- do not use on Vulkan yet.'
    }
    'qwen122b' = @{
        repo  = 'unsloth/Qwen3.5-122B-A10B-MTP-GGUF'
        files = @(
            @{ p='UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf'; b=10943808 },
            @{ p='UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00002-of-00003.gguf'; b=49667346080 },
            @{ p='UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00003-of-00003.gguf'; b=28968190016 }
        )
        note  = '125B/A10B, honest 4-bit, 262K ctx, Apache-2.0. MTP head -> --spec-type draft-mtp.'
    }
    'laguna' = @{
        repo  = 'poolside/Laguna-S-2.1-GGUF'
        files = @(
            @{ p='laguna-s-2.1-Q4_K_M.gguf';     b=96031829760 },
            @{ p='laguna-s-2.1-DFlash-BF16.gguf'; b=2233764224 },
            @{ p='chat_template.jinja';           b=4028 }
        )
        note  = '118B/A8B, 1M ctx, OpenMDW-1.1. Best agentic-coding scores (TB2.1 70.2%). DFlash draft incl.'
    }
    'deepseek-v4-flash' = @{
        repo  = 'unsloth/DeepSeek-V4-Flash-GGUF'
        files = @(
            @{ p='UD-IQ2_M/DeepSeek-V4-Flash-UD-IQ2_M-00001-of-00003.gguf'; b=5256864 },
            @{ p='UD-IQ2_M/DeepSeek-V4-Flash-UD-IQ2_M-00002-of-00003.gguf'; b=49956780160 },
            @{ p='UD-IQ2_M/DeepSeek-V4-Flash-UD-IQ2_M-00003-of-00003.gguf'; b=40964890464 }
        )
        note  = '284B/A13B, 1M ctx, MIT. BUT ~2-bit quant and the slowest tg here (highest active params).'
    }
}
# DELIBERATELY NOT IN THE REGISTRY (2026-07-30, user's call): gpt-oss-120b and any other 2025-era
# model. The bar is "Ornith-1.0-35B-tier agentic/coding quality or better, 2026 releases only" --
# gpt-oss-120b is the oldest thing in its size class and does not clear it. Don't re-add it.

# Where an entry's files go: -Dest if given, else models\image for dir = 'image' entries, else models\llm.
function Get-EntryDest([string]$label) {
    if ($Dest) { return $Dest }
    if ($REG[$label].dir -eq 'image') { return (Get-StrixModelsDir image) }
    return (Get-StrixModelsDir llm)
}

function Show-Reg {
    Write-Host "`nRegistry (label -> weights GiB, status):" -ForegroundColor Cyan
    foreach ($k in $REG.Keys) {
        # NB: PS 5.1 Measure-Object cannot read hashtable keys as properties -- sum by hand.
        $tot = 0; foreach ($f in $REG[$k].files) { if ($f.b -gt 0) { $tot += $f.b } }
        $have = 0
        foreach ($f in $REG[$k].files) {
            $lp = Join-Path (Get-EntryDest $k) $(if ($f.as) { $f.as } else { [IO.Path]::GetFileName($f.p) })
            if (Test-Path $lp) { $have += (Get-Item $lp).Length }
        }
        $pct = if ($tot -gt 0) { [math]::Round(100*$have/$tot) } else { 0 }
        $st  = if ($tot -gt 0 -and $have -ge $tot) { 'COMPLETE' } elseif ($have -gt 0) { "$pct%" } else { '-' }
        "{0,-18} {1,8:N2} GiB  {2,-9}  {3}" -f $k, ($tot/1GB), $st, $REG[$k].note
    }
    $d = Get-PSDrive ((Get-StrixModelsDir llm).Substring(0,1)) -EA SilentlyContinue
    if ($d) { Write-Host ("`n{0}: {1:N1} GiB free" -f $d.Name, ($d.Free/1GB)) -ForegroundColor DarkGray }
    Write-Host ""
}
if ($List) { Show-Reg; return }

$curl = (Get-Command curl.exe -EA SilentlyContinue).Source
if (-not $curl) { Write-Error "curl.exe not found (expected in C:\Windows\System32). Cannot resume large downloads."; exit 1 }

# -All skips entries marked WILL NOT LOAD: 60-90 GB each of files this repo has already proven
# cannot be served. Name one explicitly with -Only to fetch it anyway (e.g. to re-test after an
# upstream reconversion).
# `powershell.exe -File fetch-models.ps1 -Only a,b` delivers 'a,b' as ONE string (CLAUDE.md conventions),
# so it failed as an unknown label. Split on commas here, as run-router.ps1 does for -Models.
$Only = @($Only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$sel = if ($All) { @($REG.Keys | Where-Object { $REG[$_].note -notmatch 'WILL NOT LOAD' }) } elseif ($Only) { $Only } else { Write-Error "Specify -Only <label,...> / -All / -List"; exit 1 }
if ($All) {
    foreach ($k in @($REG.Keys | Where-Object { $REG[$_].note -match 'WILL NOT LOAD' })) {
        Write-Host "  -All skips '$k' (marked WILL NOT LOAD; use -Only $k to force)" -ForegroundColor DarkYellow
    }
}
foreach ($s in $sel) { if (-not $REG.Contains($s)) { Write-Error "unknown label '$s'. Known: $($REG.Keys -join ', ')"; exit 1 } }

# Plan only the bytes still MISSING. Counting full sizes refused to resume an 82 GB download with
# 20 GB left to fetch and 30 GB free.
$plannedBytes = 0
foreach ($s in $sel) {
    foreach ($f in $REG[$s].files) {
        if ($f.b -le 0) { continue }
        $lp = Join-Path (Get-EntryDest $s) $(if ($f.as) { $f.as } else { [IO.Path]::GetFileName($f.p) })
        $haveB = if (Test-Path $lp) { (Get-Item $lp).Length } else { 0 }
        if ($haveB -gt $f.b) { $haveB = 0 }   # oversized -> will be deleted and refetched
        $plannedBytes += ($f.b - $haveB)
    }
}
$drv = Get-PSDrive ((Get-StrixModelsDir llm).Substring(0,1))
$dests = @($sel | ForEach-Object { Get-EntryDest $_ } | Select-Object -Unique)
Write-Host ("`nPlan: {0} model(s), ~{1:N1} GiB still to download into {2}" -f $sel.Count, ($plannedBytes/1GB), ($dests -join ' + ')) -ForegroundColor Cyan
Write-Host ("{0}: {1:N1} GiB free -> ~{2:N1} GiB after" -f $drv.Name, ($drv.Free/1GB), (($drv.Free-$plannedBytes)/1GB)) -ForegroundColor DarkGray
if ($plannedBytes -gt $drv.Free) { Write-Error "Not enough free space on $($drv.Name):"; exit 1 }
if ($WhatIf) { Write-Host "[WhatIf] nothing downloaded." -ForegroundColor Yellow; return }

$grand = [Diagnostics.Stopwatch]::StartNew()
$doneBytes = 0
foreach ($s in $sel) {
    $m = $REG[$s]
    Write-Host "`n=============== $s ===============" -ForegroundColor Cyan
    Write-Host "  $($m.note)" -ForegroundColor DarkGray
    foreach ($f in $m.files) {
        # 'as' (optional) saves under a clean/distinct name -- needed when two repos ship an
        # identically-named file (e.g. both huihui GGUFs have mmproj-model-bf16.gguf) and so a
        # model resolves to the same on-disk name the launchers expect.
        $name = if ($f.as) { $f.as } else { [IO.Path]::GetFileName($f.p) }
        $out  = Join-Path (Get-EntryDest $s) $name
        $url  = "https://huggingface.co/$($m.repo)/resolve/main/$($f.p)"
        # 'as' may name a sub-folder (upscalers\, detectors\): curl -o does not create it
        New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null

        if ((Test-Path $out) -and $f.b -gt 0 -and (Get-Item $out).Length -eq $f.b) {
            Write-Host ("  [have] {0} ({1:N2} GiB)" -f $name, ($f.b/1GB)) -ForegroundColor DarkGreen
            $doneBytes += $f.b; continue
        }
        if ((Test-Path $out) -and $f.b -gt 0 -and (Get-Item $out).Length -gt $f.b) {
            Write-Host ("  [bad size, refetching] $name") -ForegroundColor Yellow
            Remove-Item $out -Force
        }
        # A partial that does not start with the GGUF magic is not a partial download -- it is an
        # HTTP error body (401 gated / 404) that curl wrote before --fail was added. Resuming onto it
        # with -C - would produce a file of exactly the right SIZE with garbage in its first bytes,
        # and the size check would call it complete.
        if ((Test-Path $out) -and $name -like '*.gguf' -and (Get-Item $out).Length -gt 0) {
            $fs = [IO.File]::OpenRead($out); $hd = New-Object byte[] 4; $null = $fs.Read($hd, 0, 4); $fs.Close()
            if ([Text.Encoding]::ASCII.GetString($hd) -ne 'GGUF') {
                Write-Host ("  [not a GGUF -- an old error body? deleting] $name") -ForegroundColor Yellow
                Remove-Item $out -Force
            }
        }
        $existing = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        if ($existing -gt 0) { Write-Host ("  [resume @ {0:N2} GiB] {1}" -f ($existing/1GB), $name) -ForegroundColor Yellow }
        else                 { Write-Host ("  [get] {0}" -f $name) -ForegroundColor Green }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        # -L follow redirects (HF -> CDN), -C - resume, --retry survive transient CDN faults.
        # --fail: an HTTP error (401 gated, 404 renamed) must NOT be written into the output file as
        # if it were model bytes -- see the GGUF-magic check above for what that used to cause.
        & $curl -L -C - --fail --retry 8 --retry-delay 5 --retry-all-errors `
                --connect-timeout 30 -o $out $url
        $rc = $LASTEXITCODE
        $sw.Stop()
        if ($rc -ne 0) {
            Write-Host ("  FAILED {0}: curl exit {1}{2}" -f $name, $rc, $(if ($rc -eq 22) { ' (HTTP error -- gated repo needs a token, or the file was renamed upstream)' } else { ' (re-run to resume)' })) -ForegroundColor Red
            if (Test-Path $out) { $doneBytes += (Get-Item $out).Length }
            continue
        }

        if (-not (Test-Path $out)) { Write-Host "  FAILED (no file): $name" -ForegroundColor Red; continue }
        $got = (Get-Item $out).Length
        if ($f.b -gt 0 -and $got -ne $f.b) {
            Write-Host ("  SIZE MISMATCH {0}: got {1} expected {2} -- re-run to resume" -f $name, $got, $f.b) -ForegroundColor Red
        } else {
            $mbps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round((($got-$existing)/1MB)/$sw.Elapsed.TotalSeconds,1) } else { 0 }
            Write-Host ("  OK {0:N2} GiB in {1:N1} min ({2} MB/s)" -f ($got/1GB), $sw.Elapsed.TotalMinutes, $mbps) -ForegroundColor Cyan
        }
        $doneBytes += $got
    }
}
$grand.Stop()
Write-Host ("`nTotal: {0:N1} GiB in {1:N1} min" -f ($doneBytes/1GB), $grand.Elapsed.TotalMinutes) -ForegroundColor Green
Show-Reg

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
  .\fetch-models.ps1 -All                        # the whole bench set (~314 GiB)
  .\fetch-models.ps1 -All -WhatIf                # plan only
#>
[CmdletBinding()]
param(
    [string[]] $Only,
    [switch]   $All,
    [switch]   $List,
    [switch]   $WhatIf,
    [string]   $Dest = 'D:\llamacpp-vulkan\models'
)
$ErrorActionPreference = 'Continue'

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
        note  = 'Qwen3.8-Flash-Next UD-IQ4_XS (qwen4exp preview). PENDING llama.cpp PR #27742 -- cannot run yet.'
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
        note  = 'Qwen3.8-Flash-Next UD-IQ1_S (1.58-bit fallback). PENDING llama.cpp PR #27742 -- cannot run yet.'
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
        note  = 'Qwen3-Coder-Next UD-Q4_K_XL (80B/A3B coding MoE, qwen3next). SERVING on :8080; Vulkan-verified.'
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
        note  = 'GLM-5.3-Flash UD-IQ1_S (1-bit, 93.1 GB, glm5_next). PENDING llama.cpp PR #27752 -- cannot run yet.'
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

function Show-Reg {
    Write-Host "`nRegistry (label -> weights GiB, status):" -ForegroundColor Cyan
    foreach ($k in $REG.Keys) {
        # NB: PS 5.1 Measure-Object cannot read hashtable keys as properties -- sum by hand.
        $tot = 0; foreach ($f in $REG[$k].files) { if ($f.b -gt 0) { $tot += $f.b } }
        $have = 0
        foreach ($f in $REG[$k].files) {
            $lp = Join-Path $Dest $(if ($f.as) { $f.as } else { [IO.Path]::GetFileName($f.p) })
            if (Test-Path $lp) { $have += (Get-Item $lp).Length }
        }
        $pct = if ($tot -gt 0) { [math]::Round(100*$have/$tot) } else { 0 }
        $st  = if ($tot -gt 0 -and $have -ge $tot) { 'COMPLETE' } elseif ($have -gt 0) { "$pct%" } else { '-' }
        "{0,-18} {1,8:N2} GiB  {2,-9}  {3}" -f $k, ($tot/1GB), $st, $REG[$k].note
    }
    $d = Get-PSDrive ($Dest.Substring(0,1)) -EA SilentlyContinue
    if ($d) { Write-Host ("`n{0}: {1:N1} GiB free" -f $d.Name, ($d.Free/1GB)) -ForegroundColor DarkGray }
    Write-Host ""
}
if ($List) { Show-Reg; return }

if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force $Dest | Out-Null }
$curl = (Get-Command curl.exe -EA SilentlyContinue).Source
if (-not $curl) { Write-Error "curl.exe not found (expected in C:\Windows\System32). Cannot resume large downloads."; exit 1 }

$sel = if ($All) { @($REG.Keys) } elseif ($Only) { $Only } else { Write-Error "Specify -Only <label,...> / -All / -List"; exit 1 }
foreach ($s in $sel) { if (-not $REG.Contains($s)) { Write-Error "unknown label '$s'. Known: $($REG.Keys -join ', ')"; exit 1 } }

$plannedBytes = 0
foreach ($s in $sel) { foreach ($f in $REG[$s].files) { if ($f.b -gt 0) { $plannedBytes += $f.b } } }
$drv = Get-PSDrive ($Dest.Substring(0,1))
Write-Host ("`nPlan: {0} model(s), ~{1:N1} GiB into {2}" -f $sel.Count, ($plannedBytes/1GB), $Dest) -ForegroundColor Cyan
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
        $out  = Join-Path $Dest $name
        $url  = "https://huggingface.co/$($m.repo)/resolve/main/$($f.p)"

        if ((Test-Path $out) -and $f.b -gt 0 -and (Get-Item $out).Length -eq $f.b) {
            Write-Host ("  [have] {0} ({1:N2} GiB)" -f $name, ($f.b/1GB)) -ForegroundColor DarkGreen
            $doneBytes += $f.b; continue
        }
        if ((Test-Path $out) -and $f.b -gt 0 -and (Get-Item $out).Length -gt $f.b) {
            Write-Host ("  [bad size, refetching] $name") -ForegroundColor Yellow
            Remove-Item $out -Force
        }
        $existing = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        if ($existing -gt 0) { Write-Host ("  [resume @ {0:N2} GiB] {1}" -f ($existing/1GB), $name) -ForegroundColor Yellow }
        else                 { Write-Host ("  [get] {0}" -f $name) -ForegroundColor Green }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        # -L follow redirects (HF -> CDN), -C - resume, --retry survive transient CDN faults
        & $curl -L -C - --retry 8 --retry-delay 5 --retry-all-errors `
                --connect-timeout 30 -o $out $url
        $sw.Stop()

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

# Results

RTX 3090, llama.cpp router, 1 slot, `cache-reuse 256`.
Reproduce with the commands in the README. Numbers are from small samples
(56 to 96 points per replay row, 3 functions per typing run), so treat
differences under ~5 points as noise.

## Models

| model                        | FIM format | notes                                                                                                               |
| ---------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------- |
| sweep-next-edit-v2-7B Q5_K_M | qwen PSM   | Best everywhere. Also does next-edit, so one model can cover both. ~130 tok/s                                       |
| mellum-4b-dpo Q8_0           | mellum SPM | Close on Go and YAML, weaker on Svelte, Astro, Lua. ~150 tok/s. `/infill` breaks it, it needs SPM with `<filename>` |
| zeta-2.1 Q8_0                | none       | Next-edit only, lost plain FIM. ~90 tok/s, 2x slower than sweep for the same edits                                  |

## Replay: exact-match rate by suite (block policy, `defs` context)

| suite              | sweep | mellum |
| ------------------ | ----- | ------ |
| go (kagi)          | 66%   | 57%    |
| svelte (suimon)    | 51%   | 38%    |
| astro (lyvo)       | 38%   | 34%    |
| yaml (nokku, helm) | 48%   | 46%    |
| lua (nvim config)  | 38%   | 21%    |

## What moved the needle

1. **Stop policy.** Letting the model run to 8 lines made most suggestions wrong
   in the tail. `block` (one statement, or the block it opens) took Svelte from
   18% to 42% exact with Mellum.
2. **Confidence gate.** Mean token logprob of the kept text. At -0.1 the share of
   correct ghosts goes to 89% on Go, 69 to 85% elsewhere, while still showing
   something at a third to two thirds of the points.
3. **Context.** Of the strategies, `defs` (definitions of identifiers near the
   cursor, from other open buffers) helped Go and Svelte by 3 to 7 points.
   `similar` (Jaccard chunks from all buffers) was equal at twice the prompt size.
   `recent` buffers were slightly worse than no context. With 100+ buffers open,
   picking by what the code references beats picking by recency.

## Typing sim at 100 wpm (sweep, defs, block)

| suite  | gate | keystrokes saved | ghost wrong from its first word |
| ------ | ---- | ---------------- | ------------------------------- |
| go     | -0.1 | 67%              | 9% of keystrokes                |
| go     | off  | 77%              | 29%                             |
| svelte | -0.1 | 55%              | 7%                              |
| svelte | off  | 61%              | 18%                             |

Time to ghost p50 58 to 70ms back then, but that counted ghosts the gate later
wiped (see below). No mismatches: every retyped function came out
byte-identical. Word accepts carry a lot: most ghosts are right until a literal
(a URL, a message string) and word-accept takes the right part.

## Flicker fix: the ghost waits for the gate's verdict

The gate judges the mean logprob of the whole kept text, but the ghost used to
stream in token by token. A late shaky token then wiped a ghost the user had
already seen. The typing sim now counts flickers: a ghost that disappears with
no keystroke since it last changed.

| suite  | ghost shown     | keystrokes saved | hides / 100 chars | flickers / 100 chars | time to ghost p50 / p90 |
| ------ | --------------- | ---------------- | ----------------- | -------------------- | ----------------------- |
| go     | while streaming | 67%              | 12.4              | 9.4                  | 59 / 71ms               |
| go     | after verdict   | 67%              | 2.7               | 0.0                  | 126 / 229ms             |
| svelte | after verdict   | 54%              | 4.9               | 0.0                  | 123 / 273ms             |

Same savings, no flicker, but the first ghost now costs the whole generation
(~8ms per token at 130 tok/s). Also, blink opens its menu on almost every
identifier char, and the ghost used to hide whenever the menu was open. It now
hides only once a menu item is selected.

## Speculative decoding (server side, b11223)

Set on the router command, it applies to every model. Not switchable per
request. Output and logprobs stay identical, so the gate is unaffected.

| `--spec-type`                      | drafts accepted (24 kagi points)                           | decode tok/s |
| ---------------------------------- | ---------------------------------------------------------- | ------------ |
| none / `ngram-mod`                 | ~0, `ngram-mod` matches 24 tokens, completions are shorter | ~127         |
| `ngram-simple`, size-n 3, size-m 8 | 130 of 289                                                 | ~200         |

Typing sim with `ngram-simple`:

| suite  | keystrokes saved | time to ghost p50 / p90   |
| ------ | ---------------- | ------------------------- |
| go     | 69 to 70%        | 122 to 130 / 290 to 297ms |
| svelte | 51%              | 124 / 214ms               |

Faster decoding did not move p50. The typical ghost is a few tokens, so time
to ghost is mostly time to first token. Breakdown for go (p50 of user requests
that ran to the end): ttft 62ms, of which the prompt is 38ms for 153 new tokens.
The rest is TLS (~7ms, a fresh handshake per curl), the router proxy hop and
streaming. The typing sim now prints this breakdown.

## Suffix length (qwen format)

Each keystroke changes the end of the prefix, and in PSM the suffix comes after
it, so the server re-evaluates the whole suffix every time. `format.suffix.qwen`
sets how many lines below the cursor go in. Replay with sweep and `defs`, scored
with the -0.1 gate (shown / right / chars saved):

| lines    | go (96 points) | svelte (79 points) |
| -------- | -------------- | ------------------ |
| 20 (old) | 63 / 56 / 1903 | 47 / 33 / 725      |
| 12       | 66 / 58 / 1970 | 47 / 32 / 770      |
| 8        | 66 / 58 / 1859 | 41 / 30 / 675      |
| 4        | 62 / 54 / 1687 | 42 / 31 / 715      |

12 is as good as 20, 8 starts losing on Svelte. Typing sim with 12, `ngram-simple` on:

| suite            | lines | keystrokes saved | time to ghost p50 / p90 | ttft p50 | new prompt tokens |
| ---------------- | ----- | ---------------- | ----------------------- | -------- | ----------------- |
| go (3 funcs)     | 20    | 70%              | 130 / 290ms             | 62ms     | 153               |
| go (3 funcs)     | 12    | 68%              | 105 / 164ms             | 49ms     | 110               |
| svelte (6 funcs) | 20    | 53%              | 123 / 244ms             | 70ms     | 223               |
| svelte (6 funcs) | 12    | 51%              | 105 / 188ms             | 50ms     | 110               |

## Mellum2 vs sweep

Replay with `defs`, scored at the -0.1 gate (shown / right / precision / chars saved).
Both models are about equally precise at -0.1, so one threshold works for both.

| suite  | sweep                | mellum2              |
| ------ | -------------------- | -------------------- |
| go     | 67 / 58 / 86% / 1970 | 58 / 53 / 91% / 1688 |
| svelte | 47 / 33 / 70% / 779  | 49 / 30 / 61% / 523  |
| astro  | 25 / 18 / 72% / 436  | 31 / 23 / 74% / 571  |
| yaml   | 27 / 20 / 74% / 465  | 34 / 26 / 76% / 592  |
| lua    | 15 / 14 / 93% / 332  | 15 / 12 / 80% / 303  |

Typing sim (3 funcs):

| suite | model   | keystrokes saved | time to ghost p50 / p90 |
| ----- | ------- | ---------------- | ----------------------- |
| go    | sweep   | 68%              | 105 / 164ms             |
| go    | mellum2 | 65%              | 74 / 251ms              |
| astro | sweep   | 35%              | 80 / 235ms              |
| astro | mellum2 | 61%              | 68 / 360ms              |

SPM puts the suffix first, so typing within a line re-evaluates ~2 prompt
tokens. But every new line shifts the suffix and re-evaluates the whole prompt
(~1400 tokens, ~170ms), which is the p90.

## Seed-Coder and Mellum2 Q8

Replay at the -0.1 gate (shown / right / precision / chars saved), `defs` unless noted:

| suite  | sweep                | mellum2 Q4           | mellum2 Q8           | seed                 | seed, no context     |
| ------ | -------------------- | -------------------- | -------------------- | -------------------- | -------------------- |
| go     | 67 / 58 / 86% / 1970 | 58 / 53 / 91% / 1688 | 58 / 55 / 94% / 1736 | 64 / 53 / 82% / 1750 | 67 / 56 / 83% / 1943 |
| svelte | 47 / 33 / 70% / 779  | 49 / 30 / 61% / 523  | 49 / 33 / 67% / 677  | 51 / 35 / 68% / 793  | 49 / 33 / 67% / 686  |
| astro  | 25 / 18 / 72% / 436  | 31 / 23 / 74% / 571  | 30 / 24 / 80% / 596  | 34 / 25 / 73% / 662  | 34 / 24 / 70% / 634  |
| yaml   | 27 / 20 / 74% / 465  | 34 / 26 / 76% / 592  | 32 / 29 / 90% / 656  | 40 / 35 / 87% / 896  | 39 / 34 / 87% / 884  |
| lua    | 15 / 14 / 93% / 332  | 15 / 12 / 80% / 303  | 16 / 12 / 75% / 303  | 23 / 14 / 60% / 313  | 22 / 14 / 63% / 313  |

Typing sim, only the model under test loaded (3 funcs):

| suite | model      | keystrokes saved | time to ghost p50 / p90 |
| ----- | ---------- | ---------------- | ----------------------- |
| astro | sweep      | 34%              | 84 / 223ms              |
| astro | mellum2 Q4 | 61%              | 68 / 360ms              |
| astro | mellum2 Q8 | 62%              | 157 / 519ms             |
| astro | seed       | 62%              | 138 / 637ms             |
| yaml  | sweep      | 32%              | 58 / 101ms              |
| yaml  | mellum2 Q8 | 35%              | 63 / 109ms              |
| yaml  | seed       | 34%              | 69 / 141ms              |

On Astro both SPM models save nearly twice what sweep does. The YAML typing
sim can't tell the models apart on 3 blocks, even though the replay favors seed.
Q8 buys Mellum2 precision in the replay but not keystrokes in the sim, and costs
latency. With several models loaded at once the 3090 runs out of VRAM and
latency explodes (sweep went to 727ms p50), so benches unload the rest first
(`POST /models/unload`).

## Cache reuse

`--cache-reuse 64` changed nothing. A direct test (insert one token before a
~560-token tail) reused only the part before the edit, so the tail is not being
shifted. Unclear whether the setting reaches the model process or whether this
build skips reuse for this setup.

## Open problems and next steps

- Time to ghost is ~105ms p50. Of the ~50ms ttft, ~28ms is the prompt (the
  suffix again) and ~20ms is TLS, the router hop and streaming. A lower
  `--cache-reuse` than 256 might let llama.cpp shift the cached suffix instead
  of recomputing it. Plain http on the LAN saves the ~7ms TLS handshake.
- A line-prefix gate (keep the longest run of whole lines whose mean passes)
  would let multi-line blocks show their first line early without ever
  retracting it. Needs per-line confidence in the replay logs to judge.
- Next-edit lane with sweep (`format.nes.sweep` exists, bench/run.lua covers
  it). Cancel the stream once the output rejoins the original, which was
  lossless for single edits and cut latency to ~250 to 800ms.
- One llama.cpp slot, so prefetch and live requests evict each other's cache.
  Go to `N_PARALLEL: 2` with `CTX_SIZE: 16384` once next-edit runs too.
- More FIM models to try: Qwen2.5-Coder-7B base, Seed-Coder-8B-Base,
  Qwen3-Coder-30B-A3B. Each needs a `config.models` entry and a bench run.
- `defs` finds definitions by regex. Treesitter or LSP definitions may do
  better on Svelte and Astro, where context barely helped.

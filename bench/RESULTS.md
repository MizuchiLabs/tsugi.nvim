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

## Open problems and next steps

- Time to ghost is ~125ms p50 now that the ghost waits for the full text. Most
  of it is decoding. N-gram speculative decoding on the server (no draft model,
  code repeats a lot) is the obvious lever. It is a server flag, not settable
  per request on b11223.
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

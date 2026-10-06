# Results

RTX 3090, llama.cpp router (b11382), 1 slot per model, q8 KV cache, `cache-reuse 128`.
Reproduce with the commands in the README. Numbers are from small samples
(56 to 160 points per replay row, 4 functions per typing run). The points of
one function move together, so treat differences under ~10 points on a single
row as noise.

The suites of the maintainer's repos follow those repos, so the same row
measured a week apart is a different sample. Go went from 86% to 70% fully
right that way, with the same model and gate. The `x-` suites are pinned to a
commit and do not drift.

## Models

| model                         | FIM format | notes                                                                                             |
| ----------------------------- | ---------- | ------------------------------------------------------------------------------------------------- |
| sweep-next-edit-v2-7B Q5_K_M  | qwen PSM   | The only one that also does next-edit. Least precise of the three, rates its own text too high    |
| Mellum2-12B-A2.5B-Base Q4_K_M | mellum SPM | The default. Most precise with seed. Cannot resume from the middle of a prompt                    |
| Seed-Coder-8B-Base Q8_0       | seed SPM   | Most precise with Mellum2. Slow decode (~80 tok/s), which the streaming gate hides                |
| mellum-4b-dpo Q8_0            | mellum SPM | Behind the others. `/infill` breaks it, it needs SPM with `<filename>`                            |
| zeta-2.1 Q8_0                 | none       | Next-edit only, lost plain FIM. ~90 tok/s, 2x slower than sweep for the same edits                |

## Current numbers

Everything below uses `confidence = 0.7`, `defs` context and the block policy.

Replay (ghost shown at / fully right / chars saved per point):

| suite    | points | sweep            | mellum2          | seed             |
| -------- | ------ | ---------------- | ---------------- | ---------------- |
| go       | 96     | 79% / 86% / 14.8 | 76% / 90% / 13.4 | 72% / 91% / 13.0 |
| svelte   | 80     | 66% / 81% / 8.3  | 74% / 86% / 9.6  | 68% / 85% / 9.3  |
| astro    | 78     | 74% / 86% / 11.8 | 71% / 93% / 11.8 | 63% / 90% / 10.2 |
| yaml     | 72     | 81% / 78% / 6.9  | 79% / 89% / 7.5  | 69% / 94% / 8.3  |
| lua      | 56     | 68% / 79% / 4.5  | 66% / 86% / 5.4  | 70% / 85% / 5.7  |
| x-go     | 160    | 72% / 83% / 13.6 | 71% / 94% / 14.2 | 70% / 97% / 14.5 |
| x-ts     | 56     | 70% / 67% / 5.8  | 62% / 74% / 5.2  | 57% / 72% / 5.6  |
| x-svelte | 152    | 83% / 83% / 15.7 | 79% / 89% / 15.6 | 76% / 88% / 14.1 |
| x-lua    | 159    | 63% / 75% / 7.0  | 60% / 89% / 7.8  | 61% / 91% / 8.0  |
| x-python | 143    | 56% / 82% / 7.3  | 57% / 94% / 7.4  | 59% / 94% / 8.3  |
| x-rust   | 148    | 73% / 84% / 11.4 | 76% / 90% / 11.2 | 70% / 86% / 11.8 |

Mellum2 and seed are more precise than sweep on every row, by 2 to 16 points,
and save about as much. That holds on the held-out repos, so it is not a quirk of
the maintainer's code.

Typing sim at 100 wpm, 4 functions:

| suite  | model   | keystrokes saved | time to ghost p50 / p90 | ghost wrong from its first word | next ghost right after a full accept |
| ------ | ------- | ---------------- | ----------------------- | ------------------------------- | ------------------------------------ |
| go     | sweep   | 70%              | 51 / 60ms               | 11%                             | 37 of 85                             |
| svelte | sweep   | 65%              | 44 / 63ms               | 11%                             | 18 of 50                             |
| go     | mellum2 | 75%              | 33 / 37ms               | 7%                              | 39 of 80                             |
| astro  | mellum2 | 63%              | 42 / 51ms               | 6%                              | 44 of 151                            |
| go     | seed    | 77%              | 38 / 52ms               | 5%                              | 32 of 68                             |
| astro  | seed    | 62%              | 35 / 58ms               | 7%                              | 42 of 146                            |
| yaml   | seed    | 83%              | 37 / 86ms               | 1%                              | 22 of 43                             |

No mismatches and no flickers in any run.

## What moved the needle

1. **Stop policy.** Letting the model run to 8 lines made most suggestions wrong
   in the tail. `block` (one statement, or the block it opens) took Svelte from
   18% to 42% exact with Mellum.
2. **Joint probability gate.** The ghost ends before the first token that takes
   the product of the token probabilities below 0.7, and it shows while it
   streams. Against the old mean-logprob gate: 4 to 9 times fewer wrong chars
   shown in the replay, time to ghost from ~140ms to ~50ms, Svelte from 49% to
   65% of keystrokes saved.
3. **Context.** Of the strategies, `defs` (definitions of identifiers near the
   cursor, from other open buffers) helped Go and Svelte by 3 to 7 points.
   `similar` (Jaccard chunks from all buffers) was equal at twice the prompt size.
   `recent` buffers were slightly worse than no context. With 100+ buffers open,
   picking by what the code references beats picking by recency.
4. **Not repeating the closer.** With an autopairs plugin almost every ghost
   inside a fresh bracket wrote the closer a second time. Stopping at it took
   Go from 20% to 91% right in that spot.

## Joint probability gate

The old gate showed a ghost when the mean token logprob was above -0.1. A mean
lets one shaky token hide among many sure ones. On Go with sweep it showed 203
ghosts. 24 of them had a joint probability under 0.3, and none of those was
right. Of 58 multi-line ghosts it showed, 22 were right.

The models' probabilities are honest. Share of whole ghosts that were right, by
the joint probability the model gave them (829 points on the held-out repos):

| joint probability | sweep | mellum2 | seed |
| ----------------- | ----- | ------- | ---- |
| under 0.1         | 2%    | 2%      | 2%   |
| 0.1 to 0.3        | 12%   | 20%     | 19%  |
| 0.3 to 0.5        | 39%   | 43%     | 40%  |
| 0.5 to 0.7        | 57%   | 55%     | 60%  |
| 0.7 to 0.9        | 64%   | 76%     | 76%  |
| 0.9 and up        | 94%   | 97%     | 96%  |

So the gate keeps the longest run of tokens whose joint probability stays at or
above `confidence`. A later token can only lower it, so the cut is final. That
lets the ghost show token by token, and the request is cancelled at the cut.

Both gates on the same raw outputs (ghosts shown / fully right / chars saved /
wrong chars shown). These came from scratch runs with per-token logs, before
the replay logged tokens itself:

| suite, model           | points | mean -0.1               | joint 0.7               |
| ---------------------- | ------ | ----------------------- | ----------------------- |
| go, sweep              | 287    | 203 / 70% / 4744 / 3627 | 215 / 85% / 4287 / 751  |
| go, mellum2            | 287    | 210 / 73% / 5442 / 3815 | 209 / 92% / 3938 / 314  |
| svelte, sweep          | 120    | 53 / 70% / 1173 / 1142  | 82 / 82% / 1065 / 121   |
| lua, sweep             | 56     | 18 / 61% / 202 / 219    | 36 / 78% / 256 / 98     |
| astro, mellum2         | 230    | 95 / 79% / 2098 / 1272  | 153 / 83% / 2029 / 193  |
| yaml, seed             | 129    | 76 / 88% / 1244 / 391   | 90 / 94% / 1329 / 78    |
| six held-out, sweep    | 829    | 365 / 69% / 8475 / 5765 | 536 / 77% / 8030 / 1460 |
| six held-out, mellum2  | 829    | 374 / 75% / 9122 / 5830 | 498 / 87% / 8154 / 641  |
| six held-out, seed     | 829    | 388 / 74% / 9859 / 5476 | 506 / 86% / 7971 / 824  |

Other floors on the held-out repos (shown / fully right): 0.5 gives 663 / 64%
with sweep, 640 / 75% with mellum2, 639 / 74% with seed. 0.8 gives 475 / 83%,
439 / 92%, 438 / 92%.

Typing sim, same 4 functions before and after:

| suite, model   | gate      | keystrokes saved | time to ghost p50 / p90 | ghost wrong from its first word |
| -------------- | --------- | ---------------- | ----------------------- | ------------------------------- |
| go, sweep      | mean -0.1 | 68%              | 148 / 330ms             | 11%                             |
| go, sweep      | joint 0.7 | 70%              | 51 / 60ms               | 11%                             |
| svelte, sweep  | mean -0.1 | 49%              | 131 / 259ms             | 4%                              |
| svelte, sweep  | joint 0.7 | 65%              | 44 / 63ms               | 11%                             |
| astro, mellum2 | mean -0.1 | 36%              | 67 / 249ms              | 2%                              |
| astro, mellum2 | joint 0.7 | 63%              | 42 / 51ms               | 6%                              |

On Svelte the ghost is wrong from its first word during 11% of the session, up
from 4%, because a ghost is on screen about three times as often. A higher
floor trades that back.

Two details that came with it:

- A ghost of only whitespace no longer counts as shown. Before, an indent token
  that streamed first and was then cut looked like a flicker.
- The prefetch also runs after a cut ghost. The model is often sure again once
  the cut part is accepted. With it the next ghost is on screen right after 34
  of 81 full accepts on Go and 21 of 53 on Svelte. Without it 19 of 81 and 9 of
  52. It costs about 5 more requests per 100 chars.

## Autopairs

With an autopairs plugin the cursor often sits in `foo(|)`. The model then
writes the rest of the line as if the closer were not there, closer included.
Accepting that leaves `foo(a, b); err != nil {)`. Neither bench saw it: the
replay cut the rest of the line, and the typing sim has no pairs.

`replay.lua --pairs true` puts the cursor right after an opener with its closer
in place. The truth is the text up to that closer. The ghost now stops before a
bracket it did not open itself, or before the quote that ends the string. With
sweep:

| suite  | points | right before | right after |
| ------ | ------ | ------------ | ----------- |
| go     | 60     | 20%          | 91%         |
| svelte | 45     | 41%          | 68%         |

A ghost that was on screen before the pair appeared also survives now. It used
to be dropped the moment the text after the cursor changed.

## Suffix follows the cursor

The window used to end on a grid row. Pressing Enter then pushed the last
suffix line out of it. In a suffix-first prompt that change sits near the
start, so the whole prefix was computed again. Mellum2 is worse off still: it
cannot resume from the middle of a prompt at all, so it redid all 1894 tokens
(277ms) where a normal keystroke costs 2 tokens (17ms).

The suffix is now a fixed number of lines below the cursor. Adding a line
above it leaves it the same text. Mellum2 on Go, 4 functions:

| window end         | keystrokes saved | time to ghost p50 / p90 |
| ------------------ | ---------------- | ----------------------- |
| on a grid row      | 74%              | 33 / 352ms              |
| follows the cursor | 75%              | 33 / 37ms               |

The replay moved by 3 of 96 points, which is noise.

## Cursor jumps

The typing sim types top-down and never moves the cursor elsewhere. Doing that
by hand in a 2000-token prompt (tokens redone, prompt time):

| step                     | sweep (prefix first) | seed (suffix first) | mellum2 (suffix first) |
| ------------------------ | -------------------- | ------------------- | ---------------------- |
| a keystroke              | 116, 31ms            | 2, 14ms             | 2, 16ms                |
| cursor 10 lines down     | 227, 52ms            | 1462, 311ms         | 2219, 325ms            |
| cursor 25 lines up       | 88, 25ms             | 1563, 347ms         | 1970, 278ms            |
| back to an earlier place | 332, 65ms            | 1, 13ms             | 3, 13ms                |

A suffix-first prompt starts with the lines below the cursor, so moving the
cursor changes it near the start. The first ghost at a new place then takes
~350ms with seed and mellum2 and ~50ms with sweep. After that they are the
faster ones. Coming back to a place is cheap for all three, the server keeps
old prompt states in RAM.

## Held-out suites

The maintainer's repos are what tsugi was tuned on. The `x-` suites are six
public repos pinned to a commit: ollama (Go), hono (TS), shadcn-svelte,
snacks.nvim (Lua), pydantic-ai (Python) and jj (Rust). Regions come only from
files added since early 2026, except in snacks.nvim, which had none.

The gate carries over. The calibration table above is from these repos, and
sweep's is the same on the maintainer's code. What does not carry over as well:

- Block ghosts need a bracket to open the block. Only 3 of 159 ghosts in Lua
  and 4 of 153 in Python had more than one line, against 43 of 158 in Go.
- `defs` finds definitions by patterns for Go, Lua, JS/TS and Python. Rust and
  others get no cross-file context from it.

## Server settings

Measured with sweep unless noted.

| what                                              | result                                                                                  |
| ------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `cache-reuse 128`, window start jumps down        | prompt 218ms to 49ms (median of 29 jumps, reused at 27), same text at 22 of 27          |
| `cache-reuse 128` on Mellum2                      | no effect                                                                               |
| `spec-type ngram-simple` (n 3, m 8)               | 120 to 132-312 tok/s, same text, but speculated tokens lose their probabilities         |
| draft model (`draft-simple`, qwen2.5-coder 0.5b)  | never switched on                                                                       |
| `ubatch-size 2048`                                | cold prompt 258ms to 238ms                                                              |
| `ctx-size`                                        | defaults are 32768 (sweep, seed) and 131072 (Mellum2). 8192 to 16384 changes no speed   |
| `cache-ram` (on by default)                       | back to an earlier window: 46ms instead of 253ms                                        |
| q8 KV cache instead of f16                        | 92 of 96 texts the same, gate verdict as good                                           |
| a keystroke, 12 suffix lines                      | ~120 tokens redone, 30ms                                                                |
| a new window                                      | ~1050 to 1350 tokens, 205 to 260ms. After an `n_predict 0` request 97ms instead of 304ms |
| fixed cost per request                            | ~12ms: curl spawn 4.3ms, TLS handshake 6.3ms                                            |
| killing curl                                      | frees the slot at once                                                                  |
| sampler chain, `n_probs`                          | the chain costs nothing, `n_probs` ~6% of decode speed                                  |

Keep speculative decoding off. With it the streamed response has no
probability entry for speculated tokens (189 of 287 Go ghosts had gaps), and
the plain response reports them as certain. The gate does not trust text
without a probability, so it cut there and chars saved fell by 38%.

`cache-reuse` only helps when text was removed before a long unchanged part,
like the window start moving down. It does nothing when text is inserted
before it. That is why the old test (insert a token before a long tail) showed
no reuse. The flag also never reached the model processes until the router got
a preset file. `GET /v1/models` lists the arguments of each model.

## Tried, no gain

- **Token healing.** Roll the prefix back to the start of the word and force
  the typed part with a grammar. Same text at 130 of 142 mid-word points on Go
  and 47 of 57 on Svelte. Mid-word points are no worse than others to begin with.
- **Line-prefix gate.** Keep the longest run of whole lines whose mean passes.
  198 ghosts at 73% right on Go, against 203 at 70% for the plain mean.

## Open problems and next steps

- The first ghost after a cursor jump takes ~350ms with the default model, see
  Cursor jumps. Asking for the prompt early would hide it: on InsertEnter, and
  when the cursor rests in normal mode. An `n_predict 0` request did that by
  hand (304ms to 97ms for the first keystroke). Not built or benched yet.
- mellum2 is the default since it is as precise as seed and a little quicker.
  A model per filetype is still open.
- Carry the ghost across the closer. Inside `foo(|)` the model's text after
  the `)` matched the real line in 27 of 30 cases on Go and 19 of 23 on Svelte.
  Showing that part after the closer would save a second round.
- A block rule by indentation, so Lua, Python and YAML get block ghosts too.
- `defs` by treesitter or LSP symbols instead of per-language patterns.
- Time to ghost is ~50ms p50 with sweep. 30ms of it is the suffix, which a
  prefix-first prompt redoes on every keystroke. The suffix-first models are at
  ~35ms. Plain http and a kept-alive connection would take ~10ms more off.
- The maintainer's suites drift with their repos. Pinning them to a commit like
  the `x-` suites would make rows comparable over time.
- Next-edit lane with sweep (`format.nes.sweep` exists, bench/run.lua covers
  it). Cancel the stream once the output rejoins the original, which was
  lossless for single edits and cut latency to ~250 to 800ms.
- More FIM models to try: Qwen2.5-Coder-7B base, Qwen3-Coder-30B-A3B. Each
  needs a `config.models` entry and a bench run on both groups of suites.

## History

Older runs, kept for the record. They used the mean-logprob gate and older
samples of the repos.

### Replay: exact-match rate by suite (block policy, `defs` context)

| suite              | sweep | mellum |
| ------------------ | ----- | ------ |
| go (kagi)          | 66%   | 57%    |
| svelte (suimon)    | 51%   | 38%    |
| astro (lyvo)       | 38%   | 34%    |
| yaml (nokku, helm) | 48%   | 46%    |
| lua (nvim config)  | 38%   | 21%    |

### Typing sim at 100 wpm (sweep, defs, block)

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

### Flicker fix: the ghost waits for the gate's verdict

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

### Speculative decoding (server side, b11223)

Set on the router command, it applies to every model. Not switchable per
request. The text stays identical. The logprobs do not, see Server settings.

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

### Suffix length (qwen format)

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

### Mellum2 vs sweep

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

### Seed-Coder and Mellum2 Q8

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

### Cache reuse

`--cache-reuse 64` changed nothing. A direct test (insert one token before a
~560-token tail) reused only the part before the edit, so the tail is not being
shifted. Unclear whether the setting reaches the model process or whether this
build skips reuse for this setup.

# AGENTS.md

Rules for anyone working on tsugi, human or agent. This is stable guidance.
Current numbers and open problems live in `bench/RESULTS.md`, not here.

## 1. What tsugi is

AI code completion for Neovim that feels like Supermaven did: fast, quiet
when unsure, and right often enough that you tab through whole blocks. It runs
on local models via llama.cpp on one consumer GPU (the maintainer's is an
RTX 3090), no cloud.

The bet: the model matters less than the tooling around it. What to put in the
prompt, when to stop generating, when to show nothing, and how fast the ghost
appears decide whether completion helps or annoys.

It has to beat plain blink + LSP completion to be worth having. Where the LSP
is already perfect (single identifiers), tsugi adds nothing. It wins on
statements, error handling, test tables, repetitive config, the rest of a line.

The maintainer writes Go, Svelte, Astro, YAML/Helm, and Lua for Neovim, keeps
many buffers open, and accepts with `<M-f>` (Tab belongs to blink).

## 2. Non-negotiables

1. **Measure before believing.** Every change to prompts, stop rules, context,
   gating, or timing is judged by `bench/replay.lua` and `bench/typing.lua` on
   real code, not by intuition or one example. Record what changed in
   `bench/RESULTS.md`.
2. **A wrong ghost costs more than no ghost.** Showing garbage trains the user
   to ignore the ghost. Prefer short, confident suggestions over long ones.
3. **Latency is a feature.** Time to ghost should stay under ~100ms p50 on a
   warm server. Anything that grows the prompt or adds a round trip must pay
   for itself in the numbers.
4. **Keep the prompt cacheable.** llama.cpp reuses the KV cache for a shared
   prompt prefix. Stable content goes first, windows snap to a grid, context
   chunks only change when the cursor moves far. Don't reshuffle the prompt
   per keystroke.
5. **Pure Lua, no daemon.** Neovim 0.12+, `vim.system` + curl for HTTP. A
   separate process needs a measured reason.
6. **Follow each model's training format exactly.** Wrong special tokens or
   section order silently wrecks quality. Check the model card or reference
   code, then verify on the server.

## 3. Layout

```
lua/tsugi/
  init.lua      setup, autocmds, keymaps, :Tsugi command
  config.lua    defaults and the model registry
  engine.lua    state machine: debounce, request, type-through, cache, prefetch, accept
  complete.lua  one FIM request: prompt, stream, trim, cancel, confidence
  format.lua    prompt formats per model (fim.mellum, fim.qwen, nes.sweep, nes.zeta)
  trim.lua      stop rules for streamed output (pure, unit tested)
  context.lua   cross-file context strategies (none, recent, similar, defs)
  ui.lua        ghost text via extmarks
  stats.lua     counters behind :Tsugi stats
bench/
  run.lua       hand-written cases, compares models and formats incl. next-edit
  replay.lua    quality: retypes real functions at sampled points, all repo files open
  typing.lua    feel: drives an embedded nvim at N wpm with a simulated user
  suites.lua    which repos and languages the benches use
  RESULTS.md    current findings and open problems
tests/          unit tests, run with nvim -l tests/run.lua
```

## 4. Working on it

- `nvim -l tests/run.lua` must pass. Test behaviour through small generic
  examples, like the existing trim tests.
- Format with `stylua lua bench tests`.
- Benches read the server from `TSUGI_URL`. It is the maintainer's home
  server (a llama.cpp router with one slot). Never commit its address.
- Never run two benches at once, or a bench while loading another model. They
  share one GPU, and latency numbers become garbage. Quality numbers are
  unaffected since decoding is greedy.
- A model that was idle may be unloaded. The first request then takes seconds.
  Warm it up before timing anything.
- The replay writes per-point logs to `bench/out/*.jsonl`. Read the wrong cases
  before tuning anything. Most insights so far came from reading them.
- The typing sim checks that every retyped function comes out byte-identical.
  A mismatch is an engine bug, not noise.
- Adding a model: an entry in `config.models`, a format in `format.lua` if it
  is new, then run the replay and typing sim and add a row to RESULTS.md.

## 5. Code style

- No legacy code, shims, or commented-out code. Refactor fully.
- Comments only where the code can't say it: why, not what. One line.
- Public API (`require("tsugi")`, config fields) gets doc comments.
- Short plain words in docs and comments. No em-dashes, no semicolons.
- Commits only when the maintainer asks.

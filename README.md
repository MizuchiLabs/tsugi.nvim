# tsugi.nvim

AI code completion for Neovim on your own GPU. It talks to a llama.cpp server,
shows the rest of your line or block as ghost text, and stays quiet when the
model isn't sure. Pure Lua, no daemon, no cloud. Work in progress.

## How it works

1. You type. After a short pause (`debounce`) tsugi sends the code around the
   cursor plus relevant snippets from your other buffers (`context`) to the server.
2. The answer streams back and gets cut down to one statement, or the whole
   block when the statement opens one (`lines`). Generation stops as soon as
   the rest would be thrown away.
3. The confidence gate multiplies the model's own token probabilities as they
   arrive. The ghost ends before the first token that takes the product below
   `confidence`, and generation stops there. A wrong ghost costs more than no ghost.
4. The ghost appears with the first token. Keep typing and it follows along as
   long as you type what it says. Accept it all, a word, or a line.
5. While you read the ghost, tsugi already asks for what comes after it
   (`prefetch`), so chained accepts often show the next ghost instantly.

## Install

Needs Neovim 0.12+, `curl`, and a running llama-server.

```lua
-- lazy.nvim
{
  "MizuchiLabs/tsugi.nvim",
  lazy = false,
  opts = {
    url = "http://127.0.0.1:8080",
  },
}
-- vim.pack
vim.pack.add { "https://github.com/MizuchiLabs/tsugi.nvim" }
require("tsugi").setup {
  url = "http://127.0.0.1:8080",
}
```

## Configuration

Everything below is the default. Pass only what you want to change.

```lua
require("tsugi").setup {
  -- llama-server address. Router mode works, the model id picks the model.
  url = "http://127.0.0.1:8080",

  -- Which entry of `models` to use.
  model = "mellum2",
  models = {
    sweep = { id = "sweep-next-edit-v2-7B-Q5_K_M", fim = "qwen" },
    mellum = { id = "mellum-4b-dpo-all.Q8_0", fim = "mellum" },
    mellum2 = { id = "Mellum2-12B-A2.5B-Base.Q4_K_M", fim = "mellum" },
    seed = { id = "Seed-Coder-8B-Base.Q8_0", fim = "seed" },
  },

  -- Cross-file context, combined in order.
  --   "defs"    definitions of identifiers near the cursor, from other buffers
  --   "similar" chunks from open buffers that look like the code at the cursor
  --   "recent"  recently visited buffers
  --   "none"    current file only
  context = { "defs" },

  -- "block": one statement, or the whole block it opens.
  -- A number: up to that many lines.
  lines = "block",

  -- How sure the model must be that the shown text is right, from 0 to 1.
  -- The ghost ends before the first token that would take it below.
  -- Higher is stricter. false shows everything.
  confidence = 0.7,

  -- ms to wait after a keystroke before asking the server.
  debounce = 20,

  -- Ask for the next suggestion while the current one is on screen.
  prefetch = true,

  -- Set a key to false to leave it unmapped. With nothing to accept, the key
  -- does what it normally does (except Alt keys).
  keymaps = {
    accept = "<M-f>",
    accept_word = "<C-Right>",
    accept_line = "<C-l>",
    dismiss = "<C-]>",
  },
}
```

### Tuning the gate

The models' token probabilities are honest: text they rate 90% or more is
right about 95% of the time, also on code they have never seen. So `confidence`
reads as "how likely is this ghost to be fully right". The gate is strict on
purpose. In a tiny scratch file the model is rarely sure, so ghosts are short
there. In a real project they run longer.

| `confidence` | what you get                                                 |
| ------------ | ------------------------------------------------------------ |
| `0.8`        | shorter ghosts, about 5 points more of them fully right      |
| `0.7`        | the default, 8 to 9 in 10 fully right depending on the model |
| `0.5`        | longer ghosts, about 12 points fewer of them fully right     |
| `false`      | everything the model says                                    |

`:Tsugi stats` tells you how many suggestions the gate cut short or dropped.

## Usage

| key         | action                 |
| ----------- | ---------------------- |
| `<M-f>`     | accept the whole ghost |
| `<C-Right>` | accept the next word   |
| `<C-l>`     | accept the next line   |
| `<C-]>`     | dismiss                |

| command                       | does                                         |
| ----------------------------- | -------------------------------------------- |
| `:Tsugi`                      | show the current model and context           |
| `:Tsugi model`                | pick a model, it loads on the server at once |
| `:Tsugi model mellum2`        | switch to a model by name                    |
| `:Tsugi context similar defs` | switch context strategies                    |
| `:Tsugi stats`                | requests, accepts, gate drops, time to ghost |

From Lua, `require("tsugi").accept(kind?)` accepts (`"all"`, `"word"`, `"line"`)
and returns false when there is nothing to accept. `require("tsugi").use_model(name?)`
switches models, handy on a keymap.

### With blink.cmp

The ghost stays up while the completion menu is open and hides once you select
an item. To share `<Tab>` with blink, unmap tsugi's accept key and put it
first in blink's chain:

```lua
-- tsugi
opts = { keymaps = { accept = false } }

-- blink.cmp
keymap = {
  ["<Tab>"] = {
    function() return require("tsugi").accept() end,
    "select_next",
    "snippet_forward",
    "fallback",
  },
}
```

### With an autopairs plugin

When a plugin like blink.pairs has already put the closing bracket or quote
after the cursor, the ghost stops before it instead of writing it again. A
ghost that was on screen before the pair appeared stays up.

## Which model

tsugi uses one model at a time. Switch with `:Tsugi model`.

Mellum2 and Seed-Coder are the most precise. At the default gate about 9 in 10
of their ghosts are fully right, against 8 in 10 for sweep, for about the same
amount of text. That holds on the maintainer's repos and on public repos the
benches keep as a held-out set. sweep is the one that also does next-edit.

The two put the lines below the cursor first in the prompt, sweep puts them
last. That makes typing cheap for them, ~35ms to the ghost against ~50ms. The
price is the first ghost after you move the cursor somewhere else: ~350ms for
them, ~50ms for sweep.

| language            | most precise  |
| ------------------- | ------------- |
| Go                  | seed, mellum2 |
| Svelte / TypeScript | mellum2, seed |
| Astro               | mellum2       |
| YAML / Helm         | seed          |
| Lua                 | mellum2, seed |
| Python              | mellum2, seed |
| Rust                | mellum2       |

Measured with `bench/replay.lua` and `bench/typing.lua`, details and raw
numbers in `bench/RESULTS.md`.

| key       | model                         | notes                                                                      |
| --------- | ----------------------------- | -------------------------------------------------------------------------- |
| `mellum2` | Mellum2-12B-A2.5B-Base Q4_K_M | the default. MoE, fastest to the first token while you type                |
| `seed`    | Seed-Coder-8B-Base Q8_0       | as precise as mellum2, slower decode (~80 tok/s) that you rarely notice    |
| `sweep`   | sweep-next-edit-v2-7B Q5_K_M  | also does next-edit, quick after a cursor jump, least precise of the three |
| `mellum`  | mellum-4b-dpo Q8_0            | the small one. About as precise as sweep, behind mellum2 and seed          |

Use base or completion-tuned models. Instruct and thinking variants are made for
chat, and thinking ones write reasoning before any code.

## Server

Any llama-server with the `/completion` endpoint. What we run on one RTX 3090:

```sh
llama-server -m Mellum2-12B-A2.5B-Base.Q4_K_M.gguf --ctx-size 8192 --flash-attn on
```

In router mode the same goes into the preset file, one section per model:

```ini
[Mellum2-12B-A2.5B-Base.Q4_K_M]
c = 8192

[sweep-next-edit-v2-7B-Q5_K_M]
c = 16384
cache-reuse = 128
```

- Set `--ctx-size`. The default is the model's training size, 131k for Mellum2
  and 32k for sweep and seed, and all of it is reserved in VRAM. tsugi's
  completion prompts are 1k to 2k tokens.
- `--cache-reuse` lets the server keep its work when the prompt window moves
  down the file. For sweep every such jump recomputes the whole prompt (~220ms)
  without it and takes ~50ms with it. It does nothing for Mellum2.
- Leave speculative decoding off (`--spec-type`). Speculated tokens come back
  without their probabilities, so the confidence gate can't judge them.
- Keep the model loaded. An idle unload (`--sleep-idle-seconds`) makes the next
  suggestion take seconds.
- Leave `--cache-ram` on, which it is by default. Coming back to a place you
  edited before then costs ~45ms instead of ~250ms.
- On a 24GB card, keep one or two models loaded. Three of these at once run out
  of VRAM and latency goes up tenfold.

## Development

```sh
nvim -l tests/run.lua                               # unit tests
stylua lua bench tests                              # format
VIMRUNTIME=$(nvim --clean --headless +'lua io.write(vim.env.VIMRUNTIME)' +qa 2>&1) \
  lua-language-server --check .                     # types and lint, uses .luarc.json
nvim -l bench/run.lua [case] [strategy]             # formats and latency, tiny hand cases
nvim -l bench/replay.lua --suite go --model sweep   # quality on real repos, many buffers open
nvim -l bench/replay.lua --suite go --pairs true    # same, cursor inside brackets an autopair closed
nvim -l bench/typing.lua --suite go --funcs 3       # real-time typing sim against the plugin
```

Benches talk to `TSUGI_URL` (default `http://127.0.0.1:8080`). Suites live in
`bench/suites.lua`, results and open problems in `bench/RESULTS.md`. The `x-`
suites are public repos pinned to a commit. They are fetched into `bench/cache`
on first use (~600MB) and tell you whether a change helps on code that is not
yours.
See `AGENTS.md` for the rules of the road.

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
3. The confidence gate scores the kept text by its mean token logprob. Below
   `confidence` nothing is shown. A wrong ghost costs more than no ghost.
4. The ghost appears. Keep typing and it follows along as long as you type what
   it says. Accept it all, a word, or a line.
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
```

## Configuration

Everything below is the default. Pass only what you want to change.

```lua
require("tsugi").setup {
  -- llama-server address. Router mode works, the model id picks the model.
  url = "http://127.0.0.1:8080",

  -- Which entry of `models` to use.
  model = "sweep",
  models = {
    sweep = { id = "sweep-next-edit-v2-7B-Q5_K_M", fim = "qwen" },
    mellum = { id = "mellum-4b-dpo-all.Q8_0", fim = "mellum" },
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

  -- Minimum mean token logprob to show a ghost. Higher is stricter.
  -- false shows everything.
  confidence = -0.1,

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

The gate is strict on purpose. In a tiny scratch file the model is rarely sure,
so you may see almost nothing there. In a real project it shows up often.

| `confidence` | what you get                                         |
| ------------ | ---------------------------------------------------- |
| `-0.1`       | fewer ghosts, and when one shows it is usually right |
| `-0.3`       | more ghosts, more of them wrong                      |
| `false`      | everything the model says                            |

`:Tsugi stats` tells you how many suggestions the gate dropped.

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
| `:Tsugi model mellum`         | switch model                                 |
| `:Tsugi context similar defs` | switch context strategies                    |
| `:Tsugi stats`                | requests, accepts, gate drops, time to ghost |

From Lua, `require("tsugi").accept(kind?)` accepts (`"all"`, `"word"`, `"line"`)
and returns false when there is nothing to accept.

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

## Server

Any llama-server with the `/completion` endpoint. What we run on one RTX 3090:

```sh
llama-server -m sweep-next-edit-v2-7B-Q5_K_M.gguf \
  --ctx-size 8192 --flash-attn on --cache-reuse 256
```

- `--cache-reuse` lets the server reuse the prompt prefix between keystrokes.
  tsugi keeps the prompt stable for exactly that reason.
- Keep the model loaded. An idle unload (`--sleep-idle-seconds`) makes the next
  suggestion take seconds.

| model                 | notes                                                |
| --------------------- | ---------------------------------------------------- |
| sweep-next-edit-v2-7B | best overall, ~130 tok/s on a 3090                   |
| mellum-4b-dpo         | a bit faster, close on Go and YAML, weaker elsewhere |

## Development

```sh
nvim -l tests/run.lua                               # unit tests
stylua lua bench tests                              # format
nvim -l bench/run.lua [case] [strategy]             # formats and latency, tiny hand cases
nvim -l bench/replay.lua --suite go --model sweep   # quality on real repos, many buffers open
nvim -l bench/typing.lua --suite go --funcs 3       # real-time typing sim against the plugin
```

Benches talk to `TSUGI_URL` (default `http://127.0.0.1:8080`). Suites live in
`bench/suites.lua`, results and open problems in `bench/RESULTS.md`.
See `AGENTS.md` for the rules of the road.

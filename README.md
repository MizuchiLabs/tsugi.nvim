# tsugi.nvim

Local code completion for Neovim, backed by llama.cpp. Work in progress.

```lua
require("tsugi").setup({
  url = "http://127.0.0.1:8080",
  model = "sweep", -- key in `models`
  context = { "defs" }, -- none, recent, similar, defs (combinable)
})
```

`<M-f>` accepts, `<C-Right>` accepts a word, `<C-l>` a line, `<C-]>` dismisses.
All of them are set in `keymaps`, e.g. `keymaps = { accept = "<Tab>" }`.
`:Tsugi model sweep` and `:Tsugi context similar defs` switch at runtime,
`:Tsugi stats` shows accept counts and latency.

The ghost stays up while a completion menu (blink or native) is open and hides
once an item in it is selected. To share `<Tab>` with blink, set
`keymaps = { accept = false }` and put tsugi first in its chain:

```lua
["<Tab>"] = { function() return require("tsugi").accept() end, "select_next", "snippet_forward", "fallback" },
```

## Server

Point it at a llama-server (router mode works, the model id picks the model).
Keep the completion model loaded, an idle unload means a cold first request.

## Tests and benchmarks

```sh
nvim -l tests/run.lua
nvim -l bench/run.lua [case] [strategy]            # formats and latency, tiny hand cases
nvim -l bench/replay.lua --suite go --model mellum  # quality on real repos, many buffers open
nvim -l bench/typing.lua --suite go --funcs 3       # real-time typing sim against the plugin
```

Suites live in `bench/suites.lua`. Benches talk to `TSUGI_URL` (default `http://127.0.0.1:8080`).

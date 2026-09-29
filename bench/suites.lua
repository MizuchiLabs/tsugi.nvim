-- Daily-coding suites. Each retypes `funcs` randomly picked functions (or
-- indented blocks with `blocks`) while every matching file in the repo is open
-- as a buffer. `pick` limits which files regions are picked from.
return {
  {
    name = "go",
    repo = "~/Projects/mizuchilabs/kagi",
    glob = { "*.go" },
    exclude = { "sqlc/" },
    funcs = 12,
  },
  {
    name = "svelte",
    repo = "~/Projects/mizuchilabs/suimon",
    glob = { "*.svelte", "*.ts" },
    exclude = { "generated", "components/ui/" },
    funcs = 10,
  },
  {
    name = "astro",
    repo = "~/Projects/mizuchilabs/lyvo",
    glob = { "*.astro", "*.ts" },
    pick = "%.astro$",
    blocks = true,
    funcs = 10,
  },
  {
    name = "yaml",
    repo = "~/Projects/nokku-sh/nokku",
    glob = { "*.yaml", "*.yml", "*.tpl" },
    exclude = { "pnpm" },
    blocks = true,
    funcs = 10,
  },
  {
    name = "lua",
    repo = "~/.config/nvim",
    glob = { "*.lua" },
    funcs = 8,
  },
}

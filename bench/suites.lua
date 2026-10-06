-- Daily-coding suites. Each retypes `funcs` randomly picked functions (or
-- indented blocks with `blocks`) while every matching file in the repo is open
-- as a buffer. `pick` limits which files regions are picked from.
--
-- The x- suites are held out: public repos pinned to `rev` and fetched into
-- bench/cache on first use. Regions come only from files added after `base`
-- (early 2026), and at most `files` buffers are open. A change that only helps
-- the maintainer's own code shows up as a gap between the two groups.
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
  {
    name = "x-go",
    url = "https://github.com/ollama/ollama",
    rev = "e363843b834c9aed95f3a9a7363adbb11d6a1444",
    base = "27db7f806f73802cbeb9f829982ad4e0a6fbeaf8",
    glob = { "*.go" },
    exclude = { "_test.go", ".pb.go", "testdata/" },
    funcs = 20,
    files = 400,
  },
  {
    name = "x-ts",
    url = "https://github.com/honojs/hono",
    rev = "5f36607f67aa9357887337328ac84a1c1d48dc04",
    base = "cea7b7b993af682fbf10bb29937d028a55b8ab7e",
    glob = { "*.ts", "*.tsx" },
    exclude = { ".test.", ".d.ts", "benchmarks/" },
    funcs = 20,
    files = 400,
  },
  {
    name = "x-svelte",
    url = "https://github.com/huntabyte/shadcn-svelte",
    rev = "493481fab94f68b8982949bc8a37eede786f2462",
    base = "88871c494c40b0a25052d99e2a0d8ba2f03d94a7",
    glob = { "*.svelte", "*.ts" },
    exclude = { ".test.", ".d.ts", "__generated" },
    funcs = 20,
    files = 400,
  },
  {
    name = "x-lua",
    url = "https://github.com/folke/snacks.nvim",
    rev = "882c996cf28183f4d63640de0b4c02ec886d01f2",
    glob = { "*.lua" },
    exclude = { "tests/" },
    funcs = 20,
    files = 400,
  },
  {
    name = "x-python",
    url = "https://github.com/pydantic/pydantic-ai",
    rev = "62013d9fa54e441e03a792ba8c26c20b56d55291",
    base = "f4c52ad09018e11ae00f7937b519423ae6f97654",
    glob = { "*.py" },
    exclude = { "tests/", "cassettes/", "examples/", "docs/" },
    blocks = true,
    funcs = 20,
    files = 400,
  },
  {
    name = "x-rust",
    url = "https://github.com/jj-vcs/jj",
    rev = "4df526513289fdee58eb7e8351c2ff87aac099ff",
    base = "91954b0d27ecdae19143b5a8244e4c1ef704fd72",
    glob = { "*.rs" },
    exclude = { "tests/" },
    blocks = true,
    funcs = 20,
    files = 400,
  },
}

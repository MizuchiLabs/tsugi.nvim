-- Usage: nvim -l tests/run.lua [filter]
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
vim.opt.rtp:prepend(root)

local failed, passed = 0, 0
for _, file in ipairs(vim.fn.glob(root .. "/tests/*_test.lua", false, true)) do
  local tests = dofile(file)
  for name, fn in vim.spairs(tests) do
    if not arg[1] or name:find(arg[1], 1, true) then
      local ok, err = pcall(fn)
      if ok then
        passed = passed + 1
      else
        failed = failed + 1
        io.write(("FAIL %s: %s\n  %s\n"):format(vim.fs.basename(file), name, err))
      end
    end
  end
end
io.write(("%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)

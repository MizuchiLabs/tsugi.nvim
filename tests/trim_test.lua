local trim = require("tsugi.trim")

local function eq(want, got)
  if want ~= got then
    error(("want %s, got %s"):format(vim.inspect(want), vim.inspect(got)), 2)
  end
end

local T = {}

T["midline stops at newline"] = function()
  local text, done = trim.fim("resp\nfoo", { "\tEncode(); err" }, 1, 8, false, 8)
  eq("resp", text)
  eq(true, done)
end

T["midline keeps streaming until newline"] = function()
  local text, done = trim.fim("re", { "\tEncode(); err" }, 1, 8, false, 8)
  eq("re", text)
  eq(false, done)
end

T["midline drops repeated rest of line"] = function()
  local text = trim.fim("resp); err != nil {\n", { "if err := Encode(); err != nil {" }, 1, 17, false, 8)
  eq("resp", text)
end

T["midline keeps short closing paren the model wrote itself"] = function()
  local text = trim.fim("foo(bar)\n", { "x := wrap()" }, 1, 10, false, 8)
  eq("foo(bar)", text)
end

T["multiline stops at dedent below cursor indent"] = function()
  local lines = { "func f() error {", "\t", "}" }
  local raw = "if err != nil {\n\t\treturn err\n\t}\n\treturn nil\n}\n\nfunc g() {"
  local text, done = trim.fim(raw, lines, 2, 1, false, 8)
  eq("if err != nil {\n\t\treturn err\n\t}\n\treturn nil", text)
  eq(true, done)
end

T["multiline stops at blank line after a statement group"] = function()
  local text, done = trim.fim("a := 1\n\tb := 2\n\n\tc := 3\n", { "\t" }, 1, 1, false, 8)
  eq("a := 1\n\tb := 2", text)
  eq(true, done)
end

T["multiline stops when it reaches the next existing line"] = function()
  local lines = { "\t", "\treturn nil", "}" }
  local text, done = trim.fim("x := 1\n\treturn nil\n", lines, 1, 1, false, 8)
  eq("x := 1", text)
  eq(true, done)
end

T["multiline keeps partial last line while streaming"] = function()
  local text, done = trim.fim("if x {\n\t\tret", { "\t" }, 1, 1, false, 8)
  eq("if x {\n\t\tret", text)
  eq(false, done)
end

T["final output trims trailing whitespace"] = function()
  local text, done = trim.fim("return nil  \n", { "\t" }, 1, 1, true, 8)
  eq("return nil", text)
  eq(true, done)
end

T["block keeps a single statement"] = function()
  local text, done = trim.fim("x := load()\n\ty := 2\n", { "\t" }, 1, 1, false, "block")
  eq("x := load()", text)
  eq(true, done)
end

T["block keeps the whole block a statement opens"] = function()
  local raw = "if err != nil {\n\t\treturn err\n\t}\n\treturn nil\n"
  local text, done = trim.fim(raw, { "\t" }, 1, 1, false, "block")
  eq("if err != nil {\n\t\treturn err\n\t}", text)
  eq(true, done)
end

T["block starts at the first line with code"] = function()
  local raw = "\n\tx := 1\n\ty := 2\n"
  local text = trim.fim(raw, { "func f() {", "}" }, 1, 10, false, "block")
  eq("\n\tx := 1", text)
end

return T

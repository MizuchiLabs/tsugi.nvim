local trim = require "tsugi.trim"

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

T["midline stops at the closing paren that is already there"] = function()
  local text, done = trim.fim("r, &in); err != nil {", { "if err := readJSON()" }, 1, 19, false, "block")
  eq("r, &in", text)
  eq(true, done)
end

T["midline stops at the quote that ends the string"] = function()
  local text = trim.fim("hello %s\", name)", { "fmt.Println(\"\")" }, 1, 13, false, "block")
  eq("hello %s", text)
end

T["midline keeps an escaped quote"] = function()
  local text = trim.fim([[say \"hi\" now", x)]], { "fmt.Println(\"\")" }, 1, 13, false, "block")
  eq([[say \"hi\" now]], text)
end

T["until_closer leaves text alone when no closer follows the cursor"] = function()
  local text, cut = trim.until_closer("foo)", "")
  eq("foo)", text)
  eq(false, cut)
end

T["until_closer keeps brackets the text opened itself"] = function()
  eq("a(b)[c]", (trim.until_closer("a(b)[c]) + 1", ")")))
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

---Tokens from pairs of text and probability.
local function tokens(list)
  local out, pos = {}, 0
  for i = 1, #list, 2 do
    out[#out + 1] = { at = pos + 1, len = #list[i], logprob = math.log(list[i + 1]) }
    pos = pos + #list[i]
  end
  return out
end

T["sure keeps everything while the joint probability holds"] = function()
  eq(8, trim.sure(tokens { "foo", 0.9, "(bar)", 0.9 }, 8, 0.7))
end

T["sure cuts before the token that drops below the floor"] = function()
  eq(7, trim.sure(tokens { "foo", 0.9, "(bar", 0.9, ")", 0.5 }, 8, 0.7))
end

T["sure adds up small doubts"] = function()
  eq(2, trim.sure(tokens { "a", 0.85, "b", 0.85, "c", 0.85 }, 3, 0.7))
end

T["sure shows nothing when the first token is a guess"] = function()
  eq(0, trim.sure(tokens { "foo", 0.3, "(bar)", 0.99 }, 8, 0.7))
end

T["sure ignores tokens past the kept text"] = function()
  eq(3, trim.sure(tokens { "foo", 0.9, "\nbar", 0.1 }, 3, 0.7))
end

T["sure does not trust text without a probability"] = function()
  eq(3, trim.sure(tokens { "foo", 0.9 }, 8, 0.7))
end

return T

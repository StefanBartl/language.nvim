std = "luajit"
globals = { "vim" }
-- LuaCATS `fun(...)` annotations for callback-heavy provider interfaces run
-- long; wrapping them hurts readability more than it helps.
max_line_length = 160

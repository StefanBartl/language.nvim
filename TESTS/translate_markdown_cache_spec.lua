-- TESTS/translate_markdown_cache_spec.lua -- translate/markdown/cache.lua: the key,
-- the bounded memory cache, and the optional disk file (persistence, size cap,
-- merge with another instance, a damaged file). Disk lives in a fixture directory
-- inside the repository, never in the developer's real stdpath("cache").

return function(H)
  local cache = require("language.translate.markdown.cache")
  local dir, cleanup = H.fixture("md-cache")

  cache._reset()

  -- key: every ingredient counts ------------------------------------------------------------
  do
    local base = cache.key("deepl", nil, "EN", "DE", "Hallo Welt")
    H.eq(#base, 32, "a fixed-length hash")
    H.eq(cache.key("deepl", nil, "EN", "DE", "Hallo Welt"), base, "stable")
    H.ok(
      cache.key("google", nil, "EN", "DE", "Hallo Welt") ~= base,
      "the engine is part of the key"
    )
    H.ok(cache.key("deepl", "m1", "EN", "DE", "Hallo Welt") ~= base, "the model is part of the key")
    H.ok(cache.key("deepl", nil, "FR", "DE", "Hallo Welt") ~= base, "the target is part of the key")
    H.ok(cache.key("deepl", nil, "EN", nil, "Hallo Welt") ~= base, "the source is part of the key")
    H.ok(cache.key("deepl", nil, "EN", "DE", "Hallo Welt!") ~= base, "the text is part of the key")
    H.eq(
      cache.key("deepl", nil, "en", "de", "Hallo Welt"),
      base,
      "language codes are case-insensitive"
    )
    H.ok(
      cache.key("a", "b", "EN", nil, "x") ~= cache.key("a", nil, "EN", nil, "bx"),
      "fields cannot run into each other"
    )
  end

  -- memory ------------------------------------------------------------------------------------
  do
    H.eq(cache.get("nokey"), nil)
    cache.set("k1", "v1")
    H.eq(cache.get("k1"), "v1")
    cache.set("k1", "v1b")
    H.eq(cache.get("k1"), "v1b", "a key is overwritten")
    H.eq(cache.stats().entries, 1)
    cache.clear()
    H.eq(cache.get("k1"), nil, "clear forgets")
    H.eq(cache.stats().entries, 0)
  end

  -- memory bound: the oldest go first, a recently read entry survives ------------------------------
  do
    cache._reset()
    cache.configure({ max_units = 10 })
    for i = 1, 10 do
      cache.set("k" .. i, "v" .. i)
    end
    H.eq(cache.get("k1"), "v1", "reading k1 refreshes it")
    cache.set("k11", "v11")
    H.ok(cache.stats().entries <= 10, "bounded: " .. cache.stats().entries)
    H.eq(cache.get("k11"), "v11", "the newest is there")
    H.eq(cache.get("k1"), "v1", "the recently read one survived")
    H.eq(cache.get("k2"), nil, "the oldest unread one went")
    for i = 12, 200 do
      cache.set("k" .. i, "v" .. i)
    end
    H.ok(cache.stats().entries <= 10, "stays bounded under load: " .. cache.stats().entries)
    H.eq(cache.get("k200"), "v200")
  end

  -- disk: persistence ------------------------------------------------------------------------------------
  do
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    cache.set("persist1", "gespeichert")
    cache.set("persist2", "auch")
    cache.flush()
    H.eq(vim.fn.filereadable(dir .. "/translate_markdown.json"), 1, "the file is written")

    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("persist1"), "gespeichert", "a new session reads it back")
    H.eq(cache.get("persist2"), "auch")

    -- memory only: nothing is written
    local before = vim.fn.getftime(dir .. "/translate_markdown.json")
    cache._reset()
    cache.configure({ disk = false, dir = dir })
    cache.set("mem-only", "x")
    cache.flush()
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("mem-only"), nil, "with disk off, nothing reaches the file")
    H.eq(vim.fn.getftime(dir .. "/translate_markdown.json"), before)
  end

  -- disk: merge with what another instance wrote -------------------------------------------------------------
  do
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("persist1"), "gespeichert")
    -- another Neovim adds an entry behind our back
    local lib = require("lib.nvim.cache.disk")
    local data = lib.load("translate_markdown", { dir = dir })
    table.insert(data.e, { "foreign", "fremd" })
    lib.save("translate_markdown", data, { dir = dir })
    cache.set("mine", "meins")
    cache.flush()
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("foreign"), "fremd", "the other instance's entry is not lost")
    H.eq(cache.get("mine"), "meins")
    H.eq(cache.get("persist1"), "gespeichert")
  end

  -- disk: size cap, the oldest go first ----------------------------------------------------------------------------
  do
    cache.clear({ disk = true })
    cache._reset()
    cache.configure({ disk = true, dir = dir, max_kb = 16, max_units = 20000 })
    local blob = ("x"):rep(1000)
    for i = 1, 60 do
      cache.set(("size%03d"):format(i), blob .. i)
    end
    cache.flush()
    local size = vim.fn.getfsize(dir .. "/translate_markdown.json")
    H.ok(size > 0 and size <= 16 * 1024 + 2048, "the file respects the cap: " .. size)
    cache._reset()
    cache.configure({ disk = true, dir = dir, max_kb = 16 })
    H.eq(cache.get("size060"), blob .. 60, "the newest entry survived the cut")
    H.eq(cache.get("size001"), nil, "the oldest did not")
  end

  -- disk: untrusted input -------------------------------------------------------------------------------------------
  do
    local path = dir .. "/translate_markdown.json"
    vim.fn.writefile({ "this is { not json" }, path)
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("anything"), nil, "a damaged file is ignored")
    cache.set("fresh", "neu")
    cache.flush()
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("fresh"), "neu", "and the next write repairs it")

    require("lib.nvim.cache.disk").save("translate_markdown", {
      v = 1,
      e = {
        { "ok", "gut" },
        { 5, "zahl" },
        { "novalue" },
        "text",
        { "arr", { 1 } },
      },
    }, { dir = dir })
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("ok"), "gut", "well-formed entries are read")
    H.eq(cache.get("novalue"), nil, "malformed entries are dropped")
    H.eq(cache.get("arr"), nil)

    require("lib.nvim.cache.disk").save(
      "translate_markdown",
      { v = 2, e = { { "k", "v" } } },
      { dir = dir }
    )
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    H.eq(cache.get("k"), nil, "an unknown file version is ignored")
  end

  -- clear with disk ---------------------------------------------------------------------------------------------------------
  do
    cache._reset()
    cache.configure({ disk = true, dir = dir })
    cache.set("gone", "bald")
    cache.flush()
    cache.clear({ disk = true })
    H.eq(
      vim.fn.filereadable(dir .. "/translate_markdown.json"),
      0,
      "clear({disk=true}) removes the file"
    )
  end

  cache._reset()
  cleanup()
end

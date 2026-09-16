-- TESTS/cache_spec.lua — language.spell.core.cache: per-buffer cache of native
-- whole-buffer scan results, keyed by changedtick.

return function(H)
  local cache = require("language.spell.core.cache")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })

  H.eq(cache.get(buf), nil, "nothing cached yet")

  local issues = { { word = "one" } }
  cache.set(buf, issues)
  H.eq(cache.get(buf), issues, "a fresh entry is returned as-is")

  -- An edit bumps changedtick, which must invalidate the entry automatically.
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "changed" })
  H.eq(cache.get(buf), nil, "an edit invalidates the cached entry")

  cache.set(buf, issues)
  cache.invalidate(buf)
  H.eq(cache.get(buf), nil, "invalidate() drops the entry directly")

  -- An invalid buffer is never a hit, even if it was cached before deletion.
  local buf2 = vim.api.nvim_create_buf(false, true)
  cache.set(buf2, issues)
  vim.api.nvim_buf_delete(buf2, { force = true })
  H.eq(cache.get(buf2), nil, "a deleted buffer is never a cache hit")

  vim.api.nvim_buf_delete(buf, { force = true })
end

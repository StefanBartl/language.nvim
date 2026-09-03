---@module 'language.hover'
---@brief The word under the cursor, translated, inside a hover.nvim float.
---@description
--- Reading English documentation and wanting one word in your own language is
--- the smallest possible translation, and it was the one shape this plugin
--- could not do: `:Translate` takes a *scope* -- a buffer, a selection, a
--- directory -- and a single word is none of those. The scope word `cword`
--- (see `language.scope`) fixed that half; this module is the other half, and
--- the difference is who asks. `:Translate DE cword` is you naming a language;
--- this is `:Hover show` over a word, with the language coming from the
--- configuration.
---
--- This registers a **position** preview with
--- [hover.nvim](https://github.com/StefanBartl/hover.nvim), and it is
--- `on_request` -- asked only for `:Hover show` or a key bound to it, never on
--- the automatic trigger.
---
--- **That flag is the whole reason this integration is allowed to exist.**
--- Every answer here is a request from this machine to a translation endpoint,
--- carrying the word the cursor is on. On the automatic trigger -- which fires
--- after every keystroke followed by quiet -- that would turn reading a
--- document into a stream of disclosures about what is being read, one word at
--- a time. It is the same class of thing hover.nvim's own `links.fetch` is off
--- by default for, and the same answer: only when asked, in as many words.
---
--- **It blocks, and that is a deliberate trade rather than an oversight.**
--- `hover.registry.position_at` is synchronous: a contribution returns its
--- content or it does not answer. There is no way to hand back a placeholder
--- and fill it in later, so a translation is waited for. Measured against the
--- keyless Google endpoint on 2026-09-03, one word, five words times two runs:
---
---     hover           929 ms / 452 ms
---     threshold       514 ms / 663 ms
---     ambiguous       448 ms / 465 ms
---     deliberately    590 ms / 452 ms
---     measurement     676 ms / 582 ms
---
--- 448-929 ms, which is the same order as sandbox.nvim's container lookups
--- (286-754 ms) and is only bearable because nobody arrives here by accident.
--- The wait is capped well below `translate.timeout_ms`: that budget is for a
--- command, which runs in the background and can be cancelled, and this one
--- holds the editor. See `HOVER_TIMEOUT_MS`.
---
--- **What that measurement also found, and it is the more important half:**
--- every one of those requests came back **HTTP 429** with Google's "your
--- computer or network may be sending automated queries" page, with and
--- without a browser user agent, while `api.datamuse.com` answered 200 from
--- the same machine at the same minute. So the numbers above are the cost of
--- the round trip, not proof that the answer arrives. The keyless endpoint is
--- an endpoint nobody promised, and this module reports what came back rather
--- than pretending it parsed -- see `explain_failure`.
---
---@see language.scope
---@see language.translate.providers.registry

require("language.@types")
-- The translate config shape lives with its own domain; without this the
-- `LanguageTranslateCfg` annotations below are names nothing defines.
require("language.translate.@types")

local M = {}

--- How long a hover may hold the editor waiting for a translation.
---
--- Deliberately not `translate.timeout_ms` (8 s by default). That budget
--- belongs to `:Translate`, which runs asynchronously and can be superseded by
--- the next run; this one is spent inside `position_at`, with the editor
--- unable to redraw. Measured worst case above is 929 ms, so this is roughly
--- twice the slowest observed answer and a fifth of what a command would wait.
---@type integer
local HOVER_TIMEOUT_MS = 2000

---@type boolean
local _registered = false

---@internal
---@return LanguageTranslateCfg
local function translate_cfg()
  local ok, config = pcall(require, "language.config")
  if not ok then
    return {}
  end
  local c = config.get()
  return (type(c) == "table" and type(c.translate) == "table") and c.translate or {}
end

--- The language this hover translates into.
---
--- `translate.default_target` when it is set, and English otherwise. The
--- fallback is here rather than in `DEFAULTS` because `nil` already means
--- something there: "ask", which is what the operator and visual maps do when
--- no target is fixed. A hover has nowhere to ask from -- it is handed a
--- cursor position and must return content -- so it needs an answer rather
--- than a question, and English is the one a reader of an unfamiliar language
--- most often wants. Setting `default_target` moves both.
---@return string
function M.target()
  local t = translate_cfg().default_target
  if type(t) == "string" and t ~= "" then
    return t
  end
  return "EN"
end

---@internal
--- Turn a provider failure into something a reader can act on.
---
--- The keyless Google endpoint answers an over-quota request with an HTML
--- page, and `vim.json.decode` on an HTML page says only "invalid translation
--- response" -- true, useless, and indistinguishable from a genuine parse bug.
--- Measured 2026-09-03: that is exactly what a 429 looks like from inside this
--- plugin. Naming the shape of what came back is the difference between "the
--- feature is broken" and "the endpoint is rate-limiting you".
---@param err any Whatever the provider passed as its failure value.
---@return string
local function explain_failure(err)
  local text = tostring(err)
  if text:lower():find("<html", 1, true) or text:find("invalid translation response", 1, true) then
    return "the endpoint answered with a page, not a translation (rate limit or block)"
  end
  return text
end

---@internal
--- Ask the configured provider for one word, and wait for it.
---
--- `vim.wait` with a predicate rather than a busy loop: it processes events, so
--- the job's exit callback runs while this waits. A timeout cancels the job --
--- leaving it running would land its answer in a float that has since been
--- dismissed, or in the next one.
---@param word string
---@param target string
---@return string[]|nil lines
---@return string|nil err
local function translate_blocking(word, target)
  local ok_registry, registry = pcall(require, "language.translate.providers.registry")
  if not ok_registry then
    return nil, "translate providers unavailable"
  end

  local c = translate_cfg()
  local provider, resolve_err = registry.resolve(c)
  if not provider then
    return nil, resolve_err or "no translate engine available"
  end

  local done, answered_ok, answer = false, false, nil
  local ok_call, job = pcall(provider.translate, { word }, target, nil, c, function(ok, result)
    done, answered_ok, answer = true, ok, result
  end)
  if not ok_call then
    return nil, tostring(job)
  end

  vim.wait(HOVER_TIMEOUT_MS, function()
    return done
  end, 20)

  if not done then
    if type(job) == "table" and type(job.cancel) == "function" then
      pcall(job.cancel)
    end
    return nil, ("no answer within %d ms"):format(HOVER_TIMEOUT_MS)
  end

  if not answered_ok then
    return nil, explain_failure(answer)
  end
  if type(answer) ~= "table" or #answer == 0 then
    return nil, "the endpoint answered with nothing"
  end
  return answer, nil
end

--- The position preview hover.nvim asks for.
---
--- Declines -- returns `nil` -- rather than answering with an error whenever
--- there is nothing to translate: no word under the cursor, or the word is
--- what the target language already is. Declining is not the same as failing,
--- and hover.nvim treats it differently: a declined contribution is not a page
--- the reader has to step past with `<M-n>`.
---
--- A failure *after* a word was found does answer, because by then the reader
--- asked a question and silence would read as "hover.nvim is broken".
---@param bufnr integer
---@param row integer 1-based
---@param col integer 0-based
---@return { lines: string[], title?: string, highlight?: string }|nil content hover.nvim's `Hover.Content`, written out rather than referenced: hover.nvim is an optional dependency and its types are not on this workspace's path.
function M.position(bufnr, row, col)
  local word = require("language.scope").cword_at(bufnr, row, col)
  if not word then
    return nil
  end

  local target = M.target()
  local lines, err = translate_blocking(word, target)
  if not lines then
    return {
      lines = { ("%s: %s"):format(word, err or "translation failed") },
      title = ("translate -> %s"):format(target),
      highlight = "HoverError",
    }
  end

  return {
    lines = lines,
    title = ("%s -> %s"):format(word, target),
  }
end

--- Whether the contribution is registered with hover.nvim right now.
---
--- For `:checkhealth language`, and for the one question anyone asks after
--- wiring a contribution up: did mine arrive. Read back out of hover.nvim's
--- own registry rather than from a flag this module sets, so a hover.nvim that
--- dropped the registration reports honestly.
---@return boolean
function M.registered()
  local ok, registry = pcall(require, "hover.registry")
  if not ok or type(registry.contributors) ~= "function" then
    return _registered
  end
  for _, c in ipairs(registry.contributors() or {}) do
    if c.name == "language.nvim" and (c.positions or 0) > 0 then
      return true
    end
  end
  return false
end

--- Register with hover.nvim, if it is installed and the switch is on.
---
--- Soft in both directions and silent about it: no hover.nvim is not a
--- failure, it is a machine without the optional half. `:checkhealth language`
--- is where the four possible states are told apart.
---@return boolean registered
function M.setup()
  local config_ok, config = pcall(require, "language.config")
  if config_ok and config.get().hover == false then
    _registered = false
    return false
  end

  local ok, registry = pcall(require, "hover.registry")
  if not ok or type(registry.register) ~= "function" then
    _registered = false
    return false
  end

  registry.register("language.nvim", {
    -- `on_request` is not decoration here: without it every quiet moment over
    -- a word becomes a request to a translation endpoint. An older hover.nvim
    -- that ignores the flag would do exactly that, which is why health reports
    -- the flag rather than assuming it.
    positions = { { fn = M.position, on_request = true } },
  })
  _registered = true
  return true
end

return M

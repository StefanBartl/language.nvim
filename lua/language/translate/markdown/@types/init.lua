---@meta
---@module 'language.translate.markdown.@types'
---@brief Types of `translate_markdown` (see language/translate/markdown/init.lua).

---@class LanguageMdToken
---@field generation any
---@field current? fun(): any            -- the run is stale once `current() ~= generation`
---@field cancelled? boolean             -- or once this is set

---@class LanguageMdTranslateOpts
---@field target string                  -- target language, e.g. "EN"
---@field source? string                 -- source language; nil = engine auto-detect
---@field engine? string                 -- overrides `translate.engine` for this call
---@field model? string                  -- part of the cache key (AI engines)
---@field token? LanguageMdToken         -- a stale run is abandoned: `cb(false, "stale")`
---@field max_chars? integer             -- bytes of masked text per request (default `translate.markdown.max_chars`)
---@field max_units? integer             -- units per request (default 40)
---@field concurrency? integer           -- requests in flight (default `translate.markdown.concurrency`)
---@field keep? string[]                 -- words that are never translated (proper names)
---@field cache? boolean                 -- false: bypass the cache (read and write)
---@field cache_only? boolean            -- never ask the engine: a cached unit is translated, the rest stays original (`info.pending`)
---@field on_unit? fun(ev: LanguageMdUnitEvent) -- progress, once per finished block
---@field provider? LanguageTranslateProvider -- test seam: use this engine instead of the registry
---@field cfg? table                     -- test seam: use this translate config instead of the live one

---@class LanguageMdUnitEvent
---@field first integer                  -- source lines of the block (1-based, inclusive)
---@field last integer
---@field lines string[]                 -- the block's new lines, `last - first + 1` of them
---@field status "translated"|"cached"|"partial"
---@field done integer                   -- blocks finished so far
---@field total integer                  -- blocks with something to translate

---@class LanguageMdTranslateInfo
---@field units integer                  -- units of the document
---@field translated integer             -- units answered by the engine
---@field cached integer                 -- units answered by the cache
---@field failed integer                 -- units that stayed original after validation/retry
---@field skipped integer                -- units with nothing to translate (only code, links, numbers)
---@field pending integer                -- `cache_only`: units that are not translated yet
---@field reflow_failed integer          -- translated units that could not be wrapped safely (kept original)
---@field requests integer
---@field retries integer
---@field anchors_changed integer        -- in-page link targets that were rewritten
---@field errors string[]                -- the first few engine/validation messages
---@field ms number

---@alias LanguageMdTranslateCb fun(ok: boolean, result: string[]|string, info?: LanguageMdTranslateInfo)

return {}

.pragma library

// Favorites persistence and local matching for the GIF picker. Kept out of
// Gifs.qml so the parsing rules stay testable with plain node.

// Every provider the picker can talk to, in the order Ctrl+P cycles them.
var PROVIDERS = ["giphy", "klipy"]

// How Shift+Enter puts the GIF on the clipboard. wl-copy serves one MIME type
// per invocation, so each mode is a different bet about what the receiving app
// asks for: "html" is what a browser offers when you copy an image and is the
// only one that animates in Chromium/Electron apps like Teams; "png" always
// pastes but cannot animate; "gif" is the real bytes, which those apps never
// request; "file" is a file-manager style reference.
var SHIFT_PASTE_MODES = ["html", "png", "gif", "file"]

function isProvider(value) {
  return PROVIDERS.indexOf(String(value || "")) >= 0
}

function parseConfig(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return defaultConfig()

    // Keys are stored per provider so switching does not discard the other
    // one. A flat "apiKey" from an older config seeds the active provider.
    var keys = {}
    if (data.apiKeys && typeof data.apiKeys === "object") {
      for (var i = 0; i < PROVIDERS.length; i++) {
        var name = PROVIDERS[i]
        if (typeof data.apiKeys[name] === "string") keys[name] = data.apiKeys[name]
      }
    }
    var provider = isProvider(data.provider) ? data.provider : "giphy"
    if (!keys[provider] && typeof data.apiKey === "string" && data.apiKey)
      keys[provider] = data.apiKey

    return {
      provider: provider,
      apiKeys: keys,
      contentFilter: String(data.contentFilter || "medium"),
      pasteUrl: data.pasteUrl === "gif" ? "gif" : "page",
      shiftPaste: SHIFT_PASTE_MODES.indexOf(data.shiftPaste) >= 0 ? data.shiftPaste : "html",
      showTags: data.showTags === true,
      limit: Number(data.limit) > 0 ? Number(data.limit) : 50
    }
  } catch (e) {
    return defaultConfig()
  }
}

function defaultConfig() {
  return { provider: "giphy", apiKeys: {}, contentFilter: "medium",
           pasteUrl: "page", shiftPaste: "html", showTags: false, limit: 50 }
}

function serializeConfig(config) {
  var cfg = config || defaultConfig()
  return JSON.stringify({
    provider: cfg.provider,
    apiKeys: cfg.apiKeys || {},
    contentFilter: cfg.contentFilter,
    pasteUrl: cfg.pasteUrl,
    shiftPaste: cfg.shiftPaste,
    showTags: cfg.showTags === true,
    limit: cfg.limit
  }, null, 2) + "\n"
}

function apiKeyFor(config, provider) {
  var cfg = config || {}
  var keys = cfg.apiKeys || {}
  return String(keys[provider || cfg.provider] || "")
}

// Cycle through PROVIDERS, wrapping in both directions.
function nextProvider(current, delta) {
  var at = PROVIDERS.indexOf(String(current || ""))
  if (at < 0) at = 0
  var step = Number(delta) || 1
  var next = (at + step) % PROVIDERS.length
  if (next < 0) next += PROVIDERS.length
  return PROVIDERS[next]
}

function providerCount() {
  return PROVIDERS.length
}

// Display name and key-signup location per provider, for the badge and the
// first-run screen. Tenor is gone (Google decommissioned it 2026-06-30), so
// there is no entry for it.
function providerLabel(provider) {
  return provider === "klipy" ? "KLIPY" : "GIPHY"
}

function providerSignupHint(provider) {
  if (provider === "klipy")
    return "klipy.com \u2192 Partner Panel \u2192 create an app key"
  return "developers.giphy.com \u2192 sign in \u2192 Create an API Key"
}

function parseFavorites(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var items = data && Array.isArray(data.items) ? data.items : (Array.isArray(data) ? data : [])
    var out = []
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      if (!it || !it.id) continue
      out.push(normalizeItem(it))
    }
    return out
  } catch (e) {
    return []
  }
}

function serializeFavorites(items) {
  var list = Array.isArray(items) ? items : []
  return JSON.stringify({ version: 1, items: list }, null, 2) + "\n"
}

// Past this length a keyword is a description sentence rather than a name or a
// typed word. Two things turn on that: scattered-subsequence matching over a
// sentence hits almost anything ("shoe" and "dog" both "match" a sentence
// about a man nodding by a river), and the tag editor leaves such a keyword
// alone rather than splitting it at its commas.
var LOOSE_MATCH_MAX = 40

// A list that has crossed the QML model boundary -- a favorite handed to a
// GridView delegate and read back as modelData -- comes back as a QVariantList
// rather than a JS array: indexable and with a length, but Array.isArray says
// no. Everything here reads keyword lists through this, because the picker
// labels and favorites tiles from exactly that side of the boundary.
function asList(value) {
  if (!value || typeof value !== "object" || typeof value.length !== "number") return []
  return value
}

// The words a favorite is remembered by: the query that turned it up, plus
// however the provider described the GIF. Titles alone are a thin handle --
// plenty of GIFs have none, and the thing you remember months later is what
// you typed to find it.
//
// Accepts an array or a plain string (a query is one keyword, not one per
// word). Deduped case-insensitively and bounded, because these come from a
// provider response and end up written to favorites.json. The 200-character
// ceiling is sized for a provider description sentence, which runs to about
// 140; anything longer is a provider being unreasonable.
function normalizeKeywords(raw) {
  var input = raw
  if (typeof input === "string") input = input.split(/[,\n]/)
  input = asList(input)

  var out = []
  var seen = {}
  for (var i = 0; i < input.length && out.length < 12; i++) {
    var value = input[i]
    // A provider sending objects gets nothing rather than "[object Object]".
    if (typeof value !== "string" && typeof value !== "number") continue
    var word = String(value).replace(/\s+/g, " ").replace(/^ | $/g, "")
    if (!word) continue
    if (word.length > 200) word = word.substring(0, 200)
    var key = word.toLowerCase()
    if (seen[key]) continue
    seen[key] = true
    out.push(word)
  }
  return out
}

// The tag editor is for words you typed, and it separates them with commas --
// which is exactly what a provider description is full of. So the editor only
// ever shows and rewrites the short ones; a description is carried through
// untouched rather than being shredded at its own punctuation.
function editableKeywords(keywords) {
  var list = asList(keywords)
  var out = []
  for (var i = 0; i < list.length; i++) {
    var word = String(list[i])
    if (word.length <= LOOSE_MATCH_MAX) out.push(word)
  }
  return out
}

// What the editor hands back: the field's words, then whatever it was never
// shown. Re-normalized, so the result is deduped and bounded like any other.
function applyTagEdit(keywords, text) {
  var list = asList(keywords)
  var kept = []
  for (var i = 0; i < list.length; i++) {
    var word = String(list[i])
    if (word.length > LOOSE_MATCH_MAX) kept.push(word)
  }
  return normalizeKeywords(normalizeKeywords(text).concat(kept))
}

// The tag editor's field shows one keyword per comma; what comes back out of
// it is parsed by normalizeKeywords, which splits on commas the same way.
function keywordsToText(keywords) {
  var list = asList(keywords)
  var out = []
  for (var i = 0; i < list.length; i++) out.push(String(list[i]))
  return out.join(", ")
}

// What a tile shows when tags are turned on. Favorites carry keywords and
// often no title; a fresh search result is usually the other way round, so
// either one stands in for the other.
function tagLabel(item) {
  var it = item || {}
  var keywords = asList(it.keywords)
  if (keywords.length) {
    var words = []
    for (var i = 0; i < keywords.length; i++) words.push(String(keywords[i]))
    return words.join(" \u00b7 ")
  }
  return String(it.title || "")
}

// Turn a search result into the favorite that gets written to disk: whatever
// the provider said about the GIF, with the query that found it in front --
// but only when the provider's own words do not already contain it, since a
// description mentioning "nod" is what a later search for "nod" matches
// anyway.
function favoriteEntry(item, query, now) {
  var entry = normalizeItem(item)
  var typed = normalizeKeywords(query)
  var described = entry.keywords


  var extra = []
  for (var i = 0; i < typed.length; i++) {
    var needle = typed[i].toLowerCase()
    var covered = false
    for (var j = 0; j < described.length && !covered; j++)
      covered = described[j].toLowerCase().indexOf(needle) >= 0
    if (!covered) extra.push(typed[i])
  }

  entry.keywords = normalizeKeywords(extra.concat(described))
  entry.addedAt = Number(now) || Math.floor(Date.now() / 1000)
  return entry
}

function normalizeItem(raw) {
  var it = raw || {}
  return {
    id: String(it.id || ""),
    title: String(it.title || ""),
    pageUrl: String(it.pageUrl || ""),
    gifUrl: String(it.gifUrl || ""),
    tinyGifUrl: String(it.tinyGifUrl || ""),
    previewUrl: String(it.previewUrl || ""),
    width: Number(it.width) || 0,
    height: Number(it.height) || 0,
    keywords: normalizeKeywords(it.keywords),
    addedAt: Number(it.addedAt) || 0
  }
}

function parseSearchResponse(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return { ok: false, error: "parse", results: [] }
    if (data.ok !== true) return { ok: false, error: String(data.error || "unknown"), results: [] }
    var results = Array.isArray(data.results) ? data.results : []
    var out = []
    for (var i = 0; i < results.length; i++) {
      var item = normalizeItem(results[i])
      if (item.id && item.tinyGifUrl) out.push(item)
    }
    return { ok: true, error: "", results: out }
  } catch (e) {
    return { ok: false, error: "parse", results: [] }
  }
}

function indexOfId(items, id) {
  var list = Array.isArray(items) ? items : []
  var key = String(id || "")
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].id) === key) return i
  }
  return -1
}

// Subsequence match, the way fuzzy finders behave: "dl" matches "deal with
// it". Falls back to a plain substring test first because an exact run of
// characters should always outrank a scattered one.
function fuzzyMatch(haystack, needle) {
  var text = String(haystack || "").toLowerCase()
  var query = String(needle || "").toLowerCase()
  if (!query) return true
  if (text.indexOf(query) >= 0) return true

  var t = 0
  for (var q = 0; q < query.length; q++) {
    var ch = query.charAt(q)
    if (ch === " ") continue
    t = text.indexOf(ch, t)
    if (t < 0) return false
    t++
  }
  return true
}

function fuzzyScore(haystack, needle) {
  var text = String(haystack || "").toLowerCase()
  var query = String(needle || "").toLowerCase()
  if (!query) return 0
  var exact = text.indexOf(query)
  if (exact === 0) return 0          // prefix match sorts first
  if (exact > 0) return 1 + exact     // substring, earlier is better
  return 1000                         // scattered subsequence sorts last
}

// Best score across the title and the saved keywords, or -1 when none of them
// match. A keyword hit is scored a hair worse than the same hit on the title,
// so a title match still wins a tie.
function itemScore(item, needle) {
  var it = item || {}
  var fields = [String(it.title || "")]
  var keywords = asList(it.keywords)
  for (var k = 0; k < keywords.length; k++) fields.push(String(keywords[k]))

  var best = -1
  for (var i = 0; i < fields.length; i++) {
    var field = fields[i]
    if (!field || !fuzzyMatch(field, needle)) continue
    var score = fuzzyScore(field, needle)
    // The guard is about description sentences, not about length as such: a
    // title is a name however long it runs, and "dwi" has always been allowed
    // to find one.
    if (i > 0 && score >= 1000 && field.length > LOOSE_MATCH_MAX) continue
    if (i > 0) score += 0.5
    if (best < 0 || score < best) best = score
  }
  return best
}

function filterFavorites(favorites, query) {
  var list = Array.isArray(favorites) ? favorites : []
  var needle = String(query || "").trim()
  if (!needle) return list.slice()

  var scored = []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (!item) continue
    var score = itemScore(item, needle)
    if (score < 0) continue
    scored.push({ item: item, score: score, order: i })
  }
  scored.sort(function(a, b) {
    return a.score !== b.score ? a.score - b.score : a.order - b.order
  })

  var out = []
  for (var j = 0; j < scored.length; j++) out.push(scored[j].item)
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    parseConfig: parseConfig,
    defaultConfig: defaultConfig,
    parseFavorites: parseFavorites,
    serializeFavorites: serializeFavorites,
    normalizeItem: normalizeItem,
    asList: asList,
    normalizeKeywords: normalizeKeywords,
    favoriteEntry: favoriteEntry,
    tagLabel: tagLabel,
    keywordsToText: keywordsToText,
    editableKeywords: editableKeywords,
    applyTagEdit: applyTagEdit,
    parseSearchResponse: parseSearchResponse,
    indexOfId: indexOfId,
    fuzzyMatch: fuzzyMatch,
    fuzzyScore: fuzzyScore,
    itemScore: itemScore,
    filterFavorites: filterFavorites,
    providerLabel: providerLabel,
    providerSignupHint: providerSignupHint,
    serializeConfig: serializeConfig,
    apiKeyFor: apiKeyFor,
    nextProvider: nextProvider,
    providerCount: providerCount,
    isProvider: isProvider,
    PROVIDERS: PROVIDERS,
    SHIFT_PASTE_MODES: SHIFT_PASTE_MODES
  }
}

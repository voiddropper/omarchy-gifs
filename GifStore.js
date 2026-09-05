.pragma library

// Favorites persistence and local matching for the GIF picker. Kept out of
// Gifs.qml so the parsing rules stay testable with plain node.

function parseConfig(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return defaultConfig()
    return {
      provider: data.provider === "klipy" ? "klipy" : "giphy",
      apiKey: String(data.apiKey || ""),
      contentFilter: String(data.contentFilter || "medium"),
      pasteUrl: data.pasteUrl === "gif" ? "gif" : "page",
      limit: Number(data.limit) > 0 ? Number(data.limit) : 50
    }
  } catch (e) {
    return defaultConfig()
  }
}

function defaultConfig() {
  return { provider: "giphy", apiKey: "", contentFilter: "medium", pasteUrl: "page", limit: 50 }
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

function filterFavorites(favorites, query) {
  var list = Array.isArray(favorites) ? favorites : []
  var needle = String(query || "").trim()
  if (!needle) return list.slice()

  var scored = []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (!item) continue
    if (!fuzzyMatch(item.title, needle)) continue
    scored.push({ item: item, score: fuzzyScore(item.title, needle), order: i })
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
    parseSearchResponse: parseSearchResponse,
    indexOfId: indexOfId,
    fuzzyMatch: fuzzyMatch,
    fuzzyScore: fuzzyScore,
    filterFavorites: filterFavorites,
    providerLabel: providerLabel,
    providerSignupHint: providerSignupHint
  }
}

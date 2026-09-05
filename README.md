# omarchy-gifs

A GIF picker for the [Omarchy](https://omarchy.org/) shell, built to feel like
the first-party emoji picker: same layer surface, same theme tokens, same
paste-into-the-focused-app trick. Search, hit enter, and the GIF lands in
whatever window you were just in.

Backed by **GIPHY** or **KLIPY**, switchable in config.

> **Why not Tenor?** This started as a Tenor plugin. Google closed Tenor API
> sign-ups on 2026-01-13 and fully decommissioned the API on 2026-06-30, so no
> new key can be obtained. The endpoint still answers `API_KEY_INVALID` rather
> than 404, which is why you'll find threads asking whether it quietly came
> back — it hasn't.

## Install

```bash
omarchy plugin add https://github.com/voiddropper/omarchy-gifs.git --enable
```

The helper scripts live inside the plugin, so that's the whole install. Then
bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + G", "GIFs", "omarchy-shell shell toggle voiddropper.gifs")
```

`SUPER + CTRL + G` sits next to Omarchy's emoji picker on `SUPER + CTRL + E`.
Check the key is free first with `omarchy menu keybindings --print` — note that
plain `SUPER + G` is taken by default (toggle window grouping).

## API key

Create `~/.config/omarchy/gifs/config.json`:

```json
{
  "provider": "giphy",
  "apiKey": "",
  "contentFilter": "medium",
  "pasteUrl": "page",
  "limit": 50
}
```

**GIPHY** (default) — <https://developers.giphy.com> → sign in → Create an API
Key. Free; the beta tier allows 100 calls/hour and 50 results per search. A
search fires at most once per 300ms of typing, so that limit is hard to reach
in normal use.

**KLIPY** — <https://klipy.com> → Partner Panel → create an app key, and set
`"provider": "klipy"`.

Until a key is set the picker still opens and favorites still work — only
search is unavailable, and the empty state tells you where to get a key.

### Options

| key             | default    | meaning                                                       |
|-----------------|------------|---------------------------------------------------------------|
| `provider`      | `"giphy"`  | `giphy` or `klipy`                                            |
| `apiKey`        | `""`       | key for the selected provider                                 |
| `contentFilter` | `"medium"` | `off`, `low`, `medium`, `high` (mapped onto GIPHY's `r`/`pg-13`/`pg`/`g`) |
| `pasteUrl`      | `"page"`   | `page` pastes the shareable page link; `gif` pastes the raw `.gif` URL |
| `limit`         | `50`       | results per search, clamped to 8–50                           |

Edits apply live — no restart.

KLIPY's search response carries no shareable page URL, so under `klipy` the
`page` setting falls back to the direct `.gif` link. Slack and Discord inline
and animate that too; it just renders as an image rather than an unfurled card.

## Keys

| key                          | action                                       |
|------------------------------|----------------------------------------------|
| type                         | search the provider (300ms debounce)         |
| `Tab`                        | toggle Favorites ↔ search, keeping the query |
| arrows / `PageUp` `PageDown` | move the cursor                              |
| `Enter` / left click         | paste into the focused app                   |
| `Ctrl+D` / right click       | toggle favorite                              |
| `Backspace` / `Ctrl+U`       | delete a character / clear the query          |
| `Esc`                        | clear the query, then close                  |

The picker opens on your favorites, so the GIFs you actually reuse are one
keypress away and cost no network call. Typing switches to the provider;
clearing the query drops back.

## How it works

- `bin/gif-search` queries the provider and normalizes both response shapes into
  one. The API key is read from disk inside the script, so it never appears in
  the process table or in the shell's QML. Adding a provider is one `case` arm
  and one jq expression — nothing else knows where GIFs come from.
- `bin/gif-insert` copies the URL and sends `shift+Insert`, the same approach
  `omarchy-menu-emoji-insert` uses. The URL stays on the clipboard afterwards so
  it lands in clipboard history and can be pasted again.
- `bin/gif-cache`, `bin/gif-cached`, `bin/gif-uncache` manage
  `~/.cache/omarchy/gifs`.
- Favorites are plain JSON at `~/.config/omarchy/gifs/favorites.json`.
- Ids are prefixed per provider (`g_`, `k_`), since favorites and the media
  cache are shared between them.

### Only the focused tile animates

A grid of simultaneously decoding GIFs is the one thing that makes a picker like
this feel slow, so tiles show a static frame and only the one under your cursor
plays.

There's a catch worth knowing if you build something similar: **Qt's
`AnimatedImage` will not play a GIF from an `https` URL in Quickshell 0.3.1 /
Qt 6.11.** It loads, reports no error, and sits on frame one. It animates fine
from a local file. So animation is always served from disk — the focused tile
downloads its GIF on the way past (150ms debounced, so arrowing along a row
doesn't fire a download per tile) and starts animating once it lands, with the
static frame standing in until then.

That cache is also why favorites render with no network at all. It prunes back
to 300 entries once it passes 400, oldest first, and never removes anything a
favorite still points at.

## Hacking

The overlay is `keepLoaded: true`, which means editing `Gifs.qml` logs
`Local plugin changed, reloading` **without** actually rebuilding the live
component. Run `omarchy restart shell` to pick up QML edits — otherwise you'll
spend a while testing code that isn't running.

`GifStore.js` is dependency-free and runs under node if you strip the
`.pragma library` line, which makes the parsing and fuzzy-matching easy to test:

```bash
sed '1{/^\.pragma library$/d}' GifStore.js > /tmp/gifstore.js
node -e 'const g=require("/tmp/gifstore.js"); console.log(g.fuzzyMatch("deal with it","dl"))'
```

## Requirements

Omarchy with the Quickshell-based shell, plus `curl`, `jq`, `wl-copy`
(wl-clipboard) and `wtype` — all present on a stock Omarchy install.

## License

MIT

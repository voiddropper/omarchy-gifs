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

You don't have to edit any JSON. Open the picker, start typing, and if there's
no key yet it shows you where to get one and gives you a field to paste it
into:

```
                            ⚿
              Add a GIPHY API key to search
        developers.giphy.com → sign in → Create an API Key.

        ┌──────────────────────────────────┐  ┌──────┐
        │ Paste your GIPHY API key         │  │ Save │
        └──────────────────────────────────┘  └──────┘
                Enter to focus · Ctrl+K anytime
```

`Enter` focuses the field, `Ctrl+K` reaches it any time. The key is **checked
against the provider before it is saved**, so a bad paste never displaces a
working key — you get "That key was rejected by GIPHY" instead of a silently
broken picker. The field is masked; the check is better proof than reading the
string back anyway.

Where to get one:

- **GIPHY** (default) — <https://developers.giphy.com> → sign in → Create an
  API Key. Free; the beta tier allows 100 calls/hour and 50 results per search.
  A search fires at most once per 300ms of typing, so that's hard to reach.
- **KLIPY** — <https://klipy.com> → Partner Panel → create an app key.

`Ctrl+P` switches provider without leaving the picker. Keys are stored **per
provider**, so switching never discards the other one — set both up once and
flip between them freely.

Until a key is set the picker still opens and favorites still work; only search
is unavailable.

### Options

`~/.config/omarchy/gifs/config.json`, written for you when you save a key:

| key             | default    | meaning                                                       |
|-----------------|------------|---------------------------------------------------------------|
| `provider`      | `"giphy"`  | `giphy` or `klipy`                                            |
| `apiKeys`       | `{}`       | `{"giphy": "...", "klipy": "..."}` — one key per provider     |
| `contentFilter` | `"medium"` | `off`, `low`, `medium`, `high` (mapped onto GIPHY's `r`/`pg-13`/`pg`/`g`) |
| `pasteUrl`      | `"page"`   | plain paste: `page` sends the shareable page link, `gif` the raw `.gif` URL |
| `shiftPaste`    | `"gif"`    | shift paste: `gif` copies the image bytes, `file` copies a file reference |
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
| `Enter` / left click         | paste a link to the GIF                      |
| `Shift+Enter` / Shift+click  | paste the GIF **itself**                     |
| `Ctrl+D` / right click       | toggle favorite                              |
| `Ctrl+P` / `Ctrl+Shift+P`    | next / previous provider                     |
| `Ctrl+K`                     | focus the API key field                      |
| `Backspace` / `Ctrl+U`       | delete a character / clear the query          |
| `Esc`                        | clear the query, then close                  |

The picker opens on your favorites, so the GIFs you actually reuse are one
keypress away and cost no network call. Typing switches to the provider;
clearing the query drops back.

## Link or the GIF itself

`Enter` pastes a link. Chat clients that unfurl one — Slack, Discord, Signal —
turn it into a playing GIF, and the message stays small.

Some clients don't. Teams renders a link as a flat preview, which rather misses
the point of sending a GIF. **`Shift+Enter` (or Shift+click) pastes the GIF
itself**: the full-size file is downloaded and put on the clipboard as
`image/gif`, so it uploads as a real animated image.

The first shift-paste of a given GIF downloads it (originals run a few MB);
after that it's cached and instant.

If a client refuses pasted image data but accepts pasted *files*, set
`"shiftPaste": "file"` and the clipboard carries a `text/uri-list` pointing at
the cached file instead — the same thing a file manager puts there when you
copy a file.

> Whether a given client keeps the animation on paste is up to that client:
> some Electron apps re-encode clipboard images to a static PNG. The clipboard
> itself carries the GIF intact — verified byte-identical, all frames present —
> so if one client flattens it, try `"shiftPaste": "file"`.

## How it works

- `bin/gif-search` queries the provider and normalizes both response shapes into
  one. The API key is read from disk inside the script, so it never appears in
  the process table or in the shell's QML. Adding a provider means one `case`
  arm in `gif-providers.sh` and adding it to `PROVIDERS` in `GifStore.js` —
  the UI, the key field, and `Ctrl+P` pick it up from there.
- `bin/gif-check` verifies a key before it is written to disk. The key arrives
  on **stdin, never argv**, so it stays out of the process table — the same
  reason Omarchy's wifi panel pipes passphrases in rather than passing them as
  arguments.
- `bin/gif-providers.sh` holds the per-provider request building and response
  normalization shared by both.
- `bin/gif-insert` copies the URL and sends `shift+Insert`, the same approach
  `omarchy-menu-emoji-insert` uses. The URL stays on the clipboard afterwards so
  it lands in clipboard history and can be pasted again. With `--media` it
  downloads the full-size GIF and copies that instead.
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

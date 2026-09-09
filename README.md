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

## Remove

```bash
omarchy plugin remove voiddropper.gifs
```

That leaves your API key, favorites, and cached stills on disk in case you
reinstall. To clear those too:

```bash
rm -rf ~/.config/omarchy/gifs ~/.cache/omarchy/gifs
```

Then drop the keybinding you added to `~/.config/hypr/bindings.lua`.

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
| `shiftPaste`    | `"html"`   | shift paste: `html`, `png`, `gif` or `file` — see below       |
| `limit`         | `50`       | results per search, clamped to 8–50                           |
| `allowedMediaDomains` | `[]` | extra domains media may be downloaded from, on top of `giphy.com` and `klipy.com` |

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

### Why there's a `shiftPaste` setting

`wl-copy` serves exactly **one** MIME type per invocation, and apps disagree
about which one they'll read. Chromium and Electron apps — Teams, Discord's
desktop client, most webmail — only ever ask the clipboard for `image/png`.
Offer them `image/gif` and the paste does nothing at all: the data is right
there, nobody asks for it.

So each mode is a different bet:

| `shiftPaste` | clipboard offers | notes                                                        |
|--------------|------------------|--------------------------------------------------------------|
| `html`       | `text/html`      | **default.** `<img src="…">` — exactly what a browser puts on the clipboard when you copy an image. Rich compose boxes fetch the URL, so the GIF animates. No download, instant. |
| `png`        | `image/png`      | The one format everything accepts — it's what a screenshot uses. Static first frame only. Needs imagemagick. |
| `gif`        | `image/gif`      | The real bytes. Correct, and right for apps that ask for it — but Chromium/Electron never do. |
| `file`       | `text/uri-list`  | A file-manager style reference, for apps that accept pasted files. |

Try `html` first. If your client pastes the literal `<img src="…">` text, it
took the plain-text fallback rather than the HTML, so fall back to `png` for a
static image that definitely lands.

Modes that download cache the file, so only the first shift-paste of a given
GIF waits; originals run a few MB.

## How it works

- `bin/gif-search` queries the provider and normalizes both response shapes into
  one. The API key is read from disk inside the script and handed to curl on
  stdin, so it never appears in the process table or in the shell's QML.
  Adding a provider means one `case` arm in `gif-providers.sh` and adding it to
  `PROVIDERS` in `GifStore.js` — the UI, the key field, and `Ctrl+P` pick it up
  from there.
- `bin/gif-check` verifies a key before it is written to disk. The key arrives
  on **stdin, never argv**, so it stays out of the process table — the same
  reason Omarchy's wifi panel pipes passphrases in rather than passing them as
  arguments.
- `bin/gif-providers.sh` holds the per-provider request building and response
  normalization shared by both.
- `bin/gif-net.sh` holds the network policy both of them and the cache scripts
  go through — see [Network limits](#network-limits).
- `bin/gif-preview` pulls result previews into the cache through the same
  bounded downloader, so the picker can render local files instead of letting
  Qt fetch provider URLs.
- `bin/gif-secure-config` keeps `~/.config/omarchy/gifs` at mode 700, since
  that is where the API key is stored.
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

The static frames come from disk too, and for a different reason: a remote URL
handed to `Image` is fetched on Qt's terms, with none of our limits on it. See
[Network limits](#network-limits).

That cache is also why favorites render with no network at all. It prunes back
to 300 entries once it passes 400, oldest first, and never removes anything a
favorite still points at.

### Network limits

Two rules apply to every request the plugin makes, and they are worth knowing
if you change this code.

**Credentials never reach curl's argv.** `/proc/<pid>/cmdline` is world
readable, so a key passed as an argument is readable by any process on the
machine for as long as the request runs. `gif-search` and `gif-check` build the
whole request — endpoint, key, search term — into a curl `--config` document
and feed it to curl on **stdin**. `gif-check` additionally takes the key on
stdin from the picker, so an unsaved key never touches disk either. Keys are
also checked against `[A-Za-z0-9._~-]{8,128}` before use, which is what makes it
safe to interpolate KLIPY's key into a URL path — their API takes it as a path
segment and offers no header or query form, so that one URL is kept out of argv
and out of any diagnostic output rather than being made harmless.

**Responses and downloads are capped while they arrive, and hosts are
checked.** Search responses and media are attacker-influenced — a hostile
redirect, a compromised CDN, or just a provider bug — so nothing is parsed,
cached, or handed to ImageMagick before its size and origin have been checked:

| limit                     | default | override                    |
|---------------------------|---------|-----------------------------|
| search response           | 2 MB    | `GIF_MAX_RESPONSE_BYTES`    |
| full GIF download         | 16 MB   | `GIF_MAX_MEDIA_BYTES`       |
| preview / thumbnail       | 8 MB    | `GIF_MAX_PREVIEW_BYTES`     |
| search timeout            | 12 s    | `GIF_MAX_RESPONSE_SECONDS`  |
| media timeout             | 45 s    | `GIF_MAX_MEDIA_SECONDS`     |
| connect timeout           | 8 s     | `GIF_CONNECT_TIMEOUT`       |

`GIF_CA_BUNDLE` verifies against *only* the bundle you name, replacing the
system trust store rather than adding to it — curl's `--cacert` semantics. It
is there for the test suite's local HTTPS server; pointing it at a corporate
proxy's CA will fail verification for the real providers.

The caps are enforced **on the arriving bytes**, not on the finished file. Each
transfer is piped through `head -c`, which closes the pipe one byte past the
limit; curl takes SIGPIPE and the transfer stops there, so at most `cap + 1`
bytes ever reach the disk. `--max-filesize` is still passed as a cheap
early-out that refuses a *declared* oversized transfer before its first byte,
and a response that never ends while staying under the cap is ended by the
timeouts instead.

Worth being accurate about, since it decides how much the `head -c` is really
doing: **`--max-filesize` alone would already hold here.** Aborting an
unknown-size transfer once it reaches the limit is curl's documented behaviour —
"such transfers thus are then aborted first when they actually reach that
limit" — and on curl 8.21 it is exact, stopping at the cap with no overshoot
for every piece size and cap tried. `tests/run-tests.sh` measures that and
prints it.

So this is belt and braces, not a hole being closed. It is written this way
because the bound is then ours rather than a flag's: `--max-filesize` has had
edge cases where it did not mean what it appeared to (curl#14899 counted
response bodies that redirect handling discards), and the test can assert a
byte count instead of trusting an option. The refactor also paid for itself by
surfacing a real bug — the write side's exit status was being dropped, so a
truncated file could be published as a complete one.

Media is downloaded over HTTPS only, from `giphy.com` and `klipy.com`
subdomains. The host is checked before the request and the **post-redirect**
URL is checked again afterwards, so a redirect off those domains is refused
even though the bytes already arrived; a download that fails either check, or
the byte cap, is deleted rather than left in the cache. If your provider serves
media from somewhere else, add it with `allowedMediaDomains` in `config.json`
rather than loosening the check.

The same allowlist is applied to the **results** in `gif-search`, so a result
carrying an off-allowlist URL is dropped before the picker ever sees it.

**The picker never fetches a URL itself.** Qt's `Image`, pointed at a remote
URL, will fetch whatever the provider names for as long as the provider cares
to send it: no byte cap, no timeout of ours, no origin check, and `sourceSize`
bounds only the decode, not the transfer. So every tile renders a **local
file**. `bin/gif-preview` pulls the previews for a result set through
`gif_fetch_media` — same cap, same origin checks, a few at a time — and a tile
shows its placeholder until its file is on disk. `sourceSize` is still set, to
bound what decoding a local file can cost.

`shiftPaste=png` pins the ImageMagick reader to `gif:` instead of letting
ImageMagick choose a coder by sniffing the file. The bytes came off the
network, so the format is ours to declare — otherwise a response that is not
really a GIF gets decoded by whichever coder matches it, and some of those
reach delegates. ImageMagick also runs under explicit memory, map and area
limits.

The API key is stored in `~/.config/omarchy/gifs/config.json`, and that
directory is kept at mode **700** (the file at 600). Tightening the directory
rather than just the file is deliberate: the picker saves through Quickshell's
`FileView`, whose atomic write replaces the file with a fresh inode created
under the process umask, so a mode on the file alone would not survive a save.

## Tests

```bash
tests/run-tests.sh
```

No network and no API key: `tests/serve.py` serves the response shapes the byte
cap has to survive over local HTTPS — chunked with no `Content-Length`, exactly
the cap, one byte over, a declared-oversized length, and one that trickles
forever without ever closing. The oversized cases assert on **how many bytes
the server actually managed to send**, because a cap checked only after the
transfer looks identical to one enforced during it if all you check is whether
the file exists at the end.

The suite refuses to run if its own test host is not on the media allowlist —
otherwise every fetch would be refused at the URL check before a byte was
requested, and the cap assertions would all pass without testing anything.

It also asserts the byte bound directly, by measuring the file a transfer in
progress has written, rather than only checking that an oversized download was
rejected. Those are different claims, and only the first one distinguishes a
cap enforced while bytes arrive from one checked afterwards.

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

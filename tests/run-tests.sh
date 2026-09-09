#!/bin/bash

# Tests for the network policy in bin/gif-net.sh.
#
#   tests/run-tests.sh
#
# No network access and no API key: every request goes to a local HTTPS server
# (tests/serve.py) that serves the hostile response shapes the byte cap has to
# survive. Nothing here touches the real config or cache -- XDG_CONFIG_HOME and
# XDG_CACHE_HOME are pointed at a temp directory for the duration.
#
# The group that matters most is "streaming byte cap". A cap that is only
# checked after curl exits looks identical to one enforced while bytes arrive
# if all you check is whether the file is there at the end -- so those tests
# assert on how many bytes the server actually managed to send.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
BIN="$ROOT/bin"

pass=0; fail=0; skip=0
FAILED=()

ok()   { pass=$((pass+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no()   { fail=$((fail+1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '         %s\n' "$2"; }
skipt(){ skip=$((skip+1)); printf '  \033[33mskip\033[0m %s (%s)\n' "$1" "$2"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- sandbox ---------------------------------------------------------------
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

export XDG_CONFIG_HOME="$TMP/config"
export XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$XDG_CONFIG_HOME/omarchy/gifs" "$XDG_CACHE_HOME/omarchy/gifs"

# The test server is "localhost", so allowlist it the same way a user would
# add a CDN -- through config, not by loosening the check.
cat > "$XDG_CONFIG_HOME/omarchy/gifs/config.json" << 'JSON'
{ "provider": "giphy", "allowedMediaDomains": ["localhost"] }
JSON
export GIF_CONFIG_PATH="$XDG_CONFIG_HOME/omarchy/gifs/config.json"

# --- a certificate the server can present and curl can verify --------------
if ! command -v openssl >/dev/null; then
  echo "openssl is required to run these tests" >&2
  exit 2
fi
openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" \
  >/dev/null 2>&1 || { echo "could not generate a test certificate" >&2; exit 2; }

# Verification stays on; the test CA is simply added as a trust anchor.
export GIF_CA_BUNDLE="$TMP/cert.pem"

python3 "$HERE/serve.py" "$TMP/cert.pem" "$TMP/key.pem" > "$TMP/port" 2>"$TMP/server.log" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [[ -s $TMP/port ]] && break
  sleep 0.05
done
PORT="$(cat "$TMP/port" 2>/dev/null)"
[[ $PORT =~ ^[0-9]+$ ]] || { echo "test server did not start:"; cat "$TMP/server.log"; exit 2; }
BASE="https://localhost:$PORT"

# shellcheck source=../bin/gif-net.sh
source "$BIN/gif-net.sh"

sent() {  # bytes the server actually managed to write for a path
  curl --silent --cacert "$GIF_CA_BUNDLE" "$BASE/report" \
    | jq -r --arg p "$1" '.sent[$p] // 0'
}
now_ms() { date +%s%3N; }
hb() {  # bytes, readably -- "0 MiB" hides the difference that matters here
  local n=${1:-0}
  if (( n >= 1048576 )); then printf '%d.%02d MiB' "$(( n / 1048576 ))" "$(( n % 1048576 * 100 / 1048576 ))"
  elif (( n >= 1024 )); then printf '%d.%02d KiB' "$(( n / 1024 ))" "$(( n % 1024 * 100 / 1024 ))"
  else printf '%d B' "$n"; fi
}

printf '\033[1mgif-net.sh\033[0m  server on %s\n' "$BASE"

# ===========================================================================
group "streaming byte cap (the response-size finding)"
# ===========================================================================
CAP=65536

# Everything below depends on the test host being allowlisted. If it is not,
# each fetch is refused at the URL check before a single byte is requested --
# and every "is refused" assertion below passes without exercising the cap at
# all. So prove it first, loudly.
if gif_url_allowed "$BASE/ok-small"; then
  ok "the test host is allowlisted (so the cap tests are not vacuous)"
else
  no "the test host is allowlisted (so the cap tests are not vacuous)" \
     "localhost is not on the allowlist; every cap assertion below would pass without testing anything"
  printf '\n\033[31maborting: the suite cannot test what it claims to\033[0m\n'
  exit 2
fi

# A cap enforced only after the transfer cannot pass this: the endpoint offers
# 256 MiB with no Content-Length, so the only thing that can stop it early is a
# limit applied to the bytes as they arrive.
start=$(now_ms)
if gif_fetch_media "$BASE/chunked-oversized" "$TMP/cache/chunked.gif" "$CAP"; then
  no "chunked oversized (no Content-Length) is refused"
else
  ok "chunked oversized (no Content-Length) is refused"
fi
elapsed=$(( $(now_ms) - start ))
[[ -e $TMP/cache/chunked.gif ]] && no "chunked oversized leaves no file" || ok "chunked oversized leaves no file"
if compgen -G "$TMP/cache/*.part" >/dev/null || compgen -G "$TMP/cache/*.meta" >/dev/null; then
  no "chunked oversized leaves no temp files" "$(ls "$TMP/cache")"
else
  ok "chunked oversized leaves no temp files"
fi
served=$(sent /chunked-oversized)
# Generous: sockets and curl both buffer. The point is that it is nowhere near
# the 256 MiB the endpoint was willing to send.
if (( served < 8 * 1024 * 1024 )); then
  ok "chunked oversized was cut off mid-stream (server sent $(hb "$served") of 256 MiB)"
else
  no "chunked oversized ran on past the cap" "server sent $(hb "$served"); the cap is not stopping the transfer"
fi
if (( elapsed < 15000 )); then
  ok "chunked oversized aborted promptly (${elapsed}ms)"
else
  no "chunked oversized took too long" "${elapsed}ms"
fi

# The cap has to be exact, with no Content-Length to lean on.
if gif_fetch_media "$BASE/sized?n=$CAP" "$TMP/cache/exact.gif" "$CAP"; then
  size=$(stat -c %s "$TMP/cache/exact.gif" 2>/dev/null || echo 0)
  (( size == CAP )) && ok "a response of exactly the cap is accepted whole ($size B)" \
    || no "a response of exactly the cap is accepted whole" "got $size B, wanted $CAP"
else
  no "a response of exactly the cap is accepted whole" "refused a response that is within the cap"
fi
if gif_fetch_media "$BASE/sized?n=$(( CAP + 1 ))" "$TMP/cache/over.gif" "$CAP"; then
  no "a response one byte over the cap is refused"
else
  ok "a response one byte over the cap is refused"
fi
[[ -e $TMP/cache/over.gif ]] && no "one-byte-over leaves no file" || ok "one-byte-over leaves no file"

# A declared length lets curl refuse before reading a body at all.
gif_fetch_media "$BASE/declared-oversized" "$TMP/cache/declared.gif" "$CAP" \
  && no "declared oversized is refused" || ok "declared oversized is refused"
served=$(sent /declared-oversized)
if (( served < 1024 * 1024 )); then
  ok "declared oversized was refused before the body streamed (server sent $(hb "$served"))"
else
  no "declared oversized still streamed" "server sent $(hb "$served")"
fi

# Bytes below the cap, forever, never closing: only a timeout ends this one.
GIF_MAX_MEDIA_SECONDS=3
start=$(now_ms)
gif_fetch_media "$BASE/never-ending" "$TMP/cache/never.gif" "$CAP" \
  && no "never-ending response is refused" || ok "never-ending response is refused"
elapsed=$(( $(now_ms) - start ))
if (( elapsed >= 2500 && elapsed < 12000 )); then
  ok "never-ending response ended at the request timeout (${elapsed}ms, limit 3s)"
else
  no "never-ending response did not end at the timeout" "${elapsed}ms with a 3s limit"
fi
[[ -e $TMP/cache/never.gif ]] && no "never-ending leaves no file" || ok "never-ending leaves no file"
GIF_MAX_MEDIA_SECONDS=45

# ===========================================================================
group "the byte bound is ours, not curl's"
# ===========================================================================
# The assertion the reported finding really turns on: how many bytes reach the
# disk. --max-filesize is not enough on its own -- recent curl does abort a
# chunked transfer once the limit is passed, but only after handing over a
# buffer, so the file overshoots by whatever that buffer held, and older curl
# does not check an undeclared length at all.
#
# A small cap against a large trickled response makes the difference visible:
# one buffer of overshoot is many times the cap.
TINY=1024
TRICKLE="$BASE/sized?n=1048576&piece=65536&delay=30"

gif_stream_capped "$TRICKLE" "$TMP/bounded.part" "$TMP/bounded.meta" "$TINY"
bounded=$(stat -c %s "$TMP/bounded.part" 2>/dev/null || echo 0)
if (( bounded <= TINY + 1 )); then
  ok "our pipeline wrote at most cap+1 bytes ($bounded B, cap $TINY)"
else
  no "our pipeline wrote at most cap+1 bytes" "wrote $bounded B for a cap of $TINY"
fi

# Same response, same limit, curl left to enforce it by itself.
curl --silent --fail --cacert "$GIF_CA_BUNDLE" --max-filesize "$TINY" \
  --output "$TMP/curlonly.part" "$TRICKLE" >/dev/null 2>&1
curlonly=$(stat -c %s "$TMP/curlonly.part" 2>/dev/null || echo 0)
if (( curlonly > TINY + 1 )); then
  ok "--max-filesize alone overshot the cap ($curlonly B), so the bound is doing work"
else
  skipt "--max-filesize alone overshoots the cap" \
    "this curl stopped at $curlonly B; the bound still holds on curl that does not"
fi

# ===========================================================================
group "origin checks survive the streaming rewrite"
# ===========================================================================
gif_fetch_media "$BASE/ok-small" "$TMP/cache/ok.gif" "$CAP" \
  && ok "a well-formed response is accepted" || no "a well-formed response is accepted"
[[ -s $TMP/cache/ok.gif ]] && ok "the accepted file is published to its final name" \
  || no "the accepted file is published to its final name"

gif_fetch_media "$BASE/redirect-onsite" "$TMP/cache/redir-ok.gif" "$CAP" \
  && ok "a redirect inside the allowlist is followed" || no "a redirect inside the allowlist is followed"

gif_fetch_media "$BASE/redirect-offsite" "$TMP/cache/redir-bad.gif" "$CAP" \
  && no "a redirect off the allowlist is refused" || ok "a redirect off the allowlist is refused"
[[ -e $TMP/cache/redir-bad.gif ]] && no "off-allowlist redirect leaves no file" \
  || ok "off-allowlist redirect leaves no file"

gif_fetch_media "http://localhost:$PORT/ok-small" "$TMP/cache/plain.gif" "$CAP" \
  && no "a non-https URL is refused" || ok "a non-https URL is refused"
gif_fetch_media "https://localhost@evil.example/x.gif" "$TMP/cache/spoof.gif" "$CAP" \
  && no "a userinfo-spoofed host is refused" || ok "a userinfo-spoofed host is refused"
gif_fetch_media "https://evil.example/x.gif" "$TMP/cache/off.gif" "$CAP" \
  && no "an off-allowlist host is refused" || ok "an off-allowlist host is refused"

# ===========================================================================
group "search response path (gif_http_get)"
# ===========================================================================
GIF_MAX_RESPONSE_BYTES=$CAP
gif_http_get "url = \"$BASE/json-oversized\"" >/dev/null 2>&1
rc=$?
(( rc == 2 )) && ok "an oversized chunked JSON response reports too-large (rc=2)" \
  || no "an oversized chunked JSON response reports too-large" "rc=$rc, wanted 2"
served=$(sent /json-oversized)
if (( served < 8 * 1024 * 1024 )); then
  ok "oversized JSON was cut off mid-stream (server sent $(hb "$served") of 256 MiB)"
else
  no "oversized JSON ran on past the cap" "server sent $(hb "$served")"
fi

body=$(gif_http_get "url = \"$BASE/ok-json\"")
rc=$?
(( rc == 0 )) && [[ ${body##*$'\n'} == "200" ]] \
  && ok "a normal response comes back with its status" \
  || no "a normal response comes back with its status" "rc=$rc"
GIF_MAX_RESPONSE_BYTES=2000000

# ===========================================================================
group "picker previews go through the bounded downloader"
# ===========================================================================
# Gifs.qml must never hand a provider URL to an Image: Qt applies no byte cap,
# no timeout of ours and no origin check.
if grep -qE 'source:.*(modelData|previewUrl|gifUrl)' "$ROOT/Gifs.qml"; then
  no "no Image in Gifs.qml renders a provider URL" "$(grep -nE 'source:.*(modelData|previewUrl|gifUrl)' "$ROOT/Gifs.qml")"
else
  ok "no Image in Gifs.qml renders a provider URL"
fi

out=$("$BIN/gif-preview" p_ok "$BASE/ok-small" p_off "https://evil.example/x.gif" 2>/dev/null)
[[ $out == *p_ok* ]] && ok "gif-preview reports an allowlisted preview it fetched" \
  || no "gif-preview reports an allowlisted preview it fetched" "got: $out"
[[ $out != *p_off* ]] && ok "gif-preview does not report an off-allowlist preview" \
  || no "gif-preview does not report an off-allowlist preview" "got: $out"
[[ -s $XDG_CACHE_HOME/omarchy/gifs/p_ok.preview ]] \
  && ok "gif-preview writes the preview into the cache" \
  || no "gif-preview writes the preview into the cache"
[[ -e $XDG_CACHE_HOME/omarchy/gifs/p_off.preview ]] \
  && no "gif-preview writes nothing for an off-allowlist host" \
  || ok "gif-preview writes nothing for an off-allowlist host"

out=$(GIF_MAX_PREVIEW_BYTES=$CAP "$BIN/gif-preview" p_big "$BASE/chunked-oversized" 2>/dev/null)
[[ $out != *p_big* ]] && ok "gif-preview refuses an oversized preview" \
  || no "gif-preview refuses an oversized preview"
[[ -e $XDG_CACHE_HOME/omarchy/gifs/p_big.preview ]] \
  && no "gif-preview leaves no file for an oversized preview" \
  || ok "gif-preview leaves no file for an oversized preview"

out=$("$BIN/gif-preview" '../escape' "$BASE/ok-small" 2>/dev/null)
[[ -e $XDG_CACHE_HOME/omarchy/gifs/../escape.preview ]] \
  && no "gif-preview refuses an id that escapes the cache dir" \
  || ok "gif-preview refuses an id that escapes the cache dir"

# ===========================================================================
group "host allowlist"
# ===========================================================================
host_case() { # <expect 0|1> <url>
  if gif_url_allowed "$2"; then got=0; else got=1; fi
  (( got == $1 )) && ok "host: $2" || no "host: $2" "wanted $1 got $got"
}
host_case 0 "https://media0.giphy.com/media/x/giphy.gif"
host_case 0 "https://giphy.com/gifs/abc"
host_case 0 "https://api.klipy.com/x.gif"
host_case 0 "https://media0.giphy.com:443/x.gif"
host_case 1 "https://evil.example/x.gif"
host_case 1 "https://media0.giphy.com@evil.example/x.gif"
host_case 1 "https://notgiphy.com/x.gif"
host_case 1 "https://evilgiphy.com/x.gif"
host_case 1 "http://media0.giphy.com/x.gif"
host_case 1 "file:///etc/passwd"
host_case 1 "//media0.giphy.com/x.gif"
host_case 1 ""

# ===========================================================================
group "credentials never reach argv"
# ===========================================================================
# shellcheck source=../bin/gif-providers.sh
source "$BIN/gif-providers.sh"
SECRET="abcdef0123456789abcdef"
gif_build_request giphy "$SECRET" search "dance" 50 medium
if [[ $REQ_REQUEST == *"$SECRET"* ]]; then
  ok "the key is in the curl config document"
else
  no "the key is in the curl config document"
fi
# A regression guard for the shape of the bug that was reported: the request
# builder must not hand anything back for the caller to put in argv.
if [[ -n ${REQ_ARGS+x} ]]; then
  no "the request builder exposes no argv array" "REQ_ARGS is set again"
else
  ok "the request builder exposes no argv array"
fi
gif_build_request klipy 'abc/../evil?x=1' search "dance" 8 medium
(( $? == 2 )) && ok "a key with URL metacharacters is refused" || no "a key with URL metacharacters is refused"
gif_build_request klipy 'short' search "dance" 8 medium
(( $? == 2 )) && ok "an implausibly short key is refused" || no "an implausibly short key is refused"

# A newline in a value would end the config line and inject a curl option.
inj=$(gif_cfg_quote $'x\noutput = /tmp/pwned')
[[ $inj != *$'\n'* ]] && ok "config values escape newlines" || no "config values escape newlines" "$inj"
[[ $(gif_cfg_quote 'a"b') == '"a\"b"' ]] && ok "config values escape quotes" \
  || no "config values escape quotes" "$(gif_cfg_quote 'a"b')"
[[ $(gif_cfg_quote 'a\b') == '"a\\b"' ]] && ok "config values escape backslashes" \
  || no "config values escape backslashes" "$(gif_cfg_quote 'a\b')"

# ===========================================================================
group "result filtering"
# ===========================================================================
DOMS=$(gif_media_domains_json)
row() { # <preview> <tiny> <gif> <page>
  jq -cn --arg p "$1" --arg t "$2" --arg g "$3" --arg pg "$4" \
    '{id:"x",previewUrl:$p,tinyGifUrl:$t,gifUrl:$g,pageUrl:$pg}'
}
kept() {
  jq -c --argjson doms "$DOMS" "$GIF_RESULT_DEFS . | $GIF_RESULT_FILTER" \
    <<<"{\"results\":[$1]}" | jq -r '.results | length'
}
G=https://media0.giphy.com/x.gif
[[ $(kept "$(row $G $G $G https://giphy.com/p)") == 1 ]] && ok "filter keeps an all-allowlisted result" || no "filter keeps an all-allowlisted result"
[[ $(kept "$(row $G $G $G '')") == 1 ]] && ok "filter allows an empty pageUrl" || no "filter allows an empty pageUrl"
[[ $(kept "$(row https://evil.example/x.gif $G $G '')") == 0 ]] && ok "filter drops an off-allowlist previewUrl" || no "filter drops an off-allowlist previewUrl"
[[ $(kept "$(row $G https://evil.example/x.gif $G '')") == 0 ]] && ok "filter drops an off-allowlist tinyGifUrl" || no "filter drops an off-allowlist tinyGifUrl"
[[ $(kept "$(row $G $G $G https://evil.example/p)") == 0 ]] && ok "filter drops an off-allowlist pageUrl" || no "filter drops an off-allowlist pageUrl"
[[ $(kept "$(row 'https://media0.giphy.com@evil.example/x' $G $G '')") == 0 ]] && ok "filter drops a userinfo-spoofed host" || no "filter drops a userinfo-spoofed host"
[[ $(kept "$(row http://media0.giphy.com/x.gif $G $G '')") == 0 ]] && ok "filter drops a non-https URL" || no "filter drops a non-https URL"
[[ $(kept "$(row https://sub.api.klipy.com/x $G $G '')") == 1 ]] && ok "filter keeps a deep provider subdomain" || no "filter keeps a deep provider subdomain"

# ===========================================================================
group "clipboard HTML escaping"
# ===========================================================================
# bash 5.2's patsub_replacement expands a bare & in a replacement to the text
# that matched, which silently turned "<" into "<lt;" here once.
eval "$(awk '/^html_escape\(\)/{f=1} f{print} /^}/{if(f)exit}' "$BIN/gif-insert")"
[[ $(html_escape 'a&b') == 'a&amp;b' ]] && ok "escape: &" || no "escape: &" "$(html_escape 'a&b')"
[[ $(html_escape '<x>') == '&lt;x&gt;' ]] && ok "escape: < >" || no "escape: < >" "$(html_escape '<x>')"
[[ $(html_escape '"q"') == '&quot;q&quot;' ]] && ok "escape: quotes" || no "escape: quotes" "$(html_escape '"q"')"
[[ $(html_escape 'https://x/a.gif?a=1&b=2') == 'https://x/a.gif?a=1&amp;b=2' ]] \
  && ok "escape: a real URL" || no "escape: a real URL" "$(html_escape 'https://x/a.gif?a=1&b=2')"

# ===========================================================================
group "ImageMagick reader is pinned"
# ===========================================================================
if command -v magick >/dev/null; then
  printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>' \
    > "$TMP/notreally.gif"
  if magick "gif:$TMP/notreally.gif[0]" png:- >/dev/null 2>&1; then
    no "an SVG named .gif is refused by the pinned reader"
  else
    ok "an SVG named .gif is refused by the pinned reader"
  fi
  if magick "gif:$TMP/cache/ok.gif[0]" png:- >/dev/null 2>&1; then
    ok "a real GIF still converts through the pinned reader"
  else
    no "a real GIF still converts through the pinned reader"
  fi
  if grep -q '"gif:\$dest\[0\]"' "$BIN/gif-insert"; then
    ok "gif-insert pins the reader to gif:"
  else
    no "gif-insert pins the reader to gif:" "the gif: prefix is missing"
  fi
else
  skipt "ImageMagick reader is pinned" "magick not installed"
fi

# ===========================================================================
group "a failed write is never published"
# ===========================================================================
# curl can flush a short body into the pipe and exit 0 while the write to the
# temp file fails. ulimit -f reproduces that precisely: head writes up to the
# limit, then dies of EFBIG holding a partial file, with curl none the wiser.
mkdir -p "$TMP/cache/limited"
(
  ulimit -f 1 2>/dev/null || exit 3   # 1 block = 512 bytes
  gif_fetch_media "$BASE/sized?n=8192" "$TMP/cache/limited/part.gif" "$CAP"
) >/dev/null 2>&1
rc=$?
if (( rc == 3 )); then
  skipt "a truncated write is not published" "ulimit -f unavailable"
else
  (( rc != 0 )) && ok "a truncated write reports failure" \
    || no "a truncated write reports failure" "gif_fetch_media returned 0 on a short write"
  [[ -e $TMP/cache/limited/part.gif ]] \
    && no "a truncated write leaves no file at the final name" "$(stat -c %s "$TMP/cache/limited/part.gif") B was published" \
    || ok "a truncated write leaves no file at the final name"
  if compgen -G "$TMP/cache/limited/*.part" >/dev/null; then
    no "a truncated write leaves no temp file"
  else
    ok "a truncated write leaves no temp file"
  fi
fi

gif_curl_base
(( $? == 0 )) && ok "gif_curl_base succeeds with no CA bundle set" \
  || no "gif_curl_base succeeds with no CA bundle set" "returns nonzero; a set -e caller would die"

# ===========================================================================
group "cache bookkeeping"
# ===========================================================================
# The preview and the animation fail independently, so gif-cache has to say
# which it got: the picker renders local files only, and recording a still that
# is not on disk points a tile at a missing file with nothing to fall back to.
out=$("$BIN/gif-cache" c_both "$BASE/ok-small" "$BASE/ok-small" 2>/dev/null)
rc=$?
[[ $out == *anim* && $out == *preview* ]] && ok "gif-cache reports both files when both land" \
  || no "gif-cache reports both files when both land" "got: $out"
(( rc == 0 )) && ok "gif-cache exits 0 when the animation lands" || no "gif-cache exits 0 when the animation lands"

out=$("$BIN/gif-cache" c_anim "https://evil.example/p.gif" "$BASE/ok-small" 2>/dev/null)
rc=$?
[[ $out == *anim* ]] && ok "gif-cache reports the animation when only it lands" \
  || no "gif-cache reports the animation when only it lands" "got: $out"
[[ $out != *preview* ]] && ok "gif-cache does not report a preview it failed to fetch" \
  || no "gif-cache does not report a preview it failed to fetch" "got: $out"
(( rc == 0 )) && ok "gif-cache still exits 0 when only the animation lands" \
  || no "gif-cache still exits 0 when only the animation lands"

# Two results can normalize to the same id; two jobs writing one destination
# would race on the same temp paths.
out=$("$BIN/gif-preview" dup1 "$BASE/ok-small" dup1 "$BASE/ok-small" 2>/dev/null)
[[ $(printf '%s\n' "$out" | grep -c '^dup1$') == 1 ]] && ok "gif-preview reports a duplicated id once" \
  || no "gif-preview reports a duplicated id once" "got: $(printf '%s' "$out" | tr '\n' ' ')"
[[ -s $XDG_CACHE_HOME/omarchy/gifs/dup1.preview ]] && ok "a duplicated id still produces its file" \
  || no "a duplicated id still produces its file"

# ===========================================================================
group "cache pruning"
# ===========================================================================
PRUNE="$TMP/prunedir"
mkdir -p "$PRUNE"
for i in $(seq 1 450); do : > "$PRUNE/f$i.preview"; sleep 0; done
touch -d "1970-01-01" "$PRUNE/f1.preview"        # oldest, and a favorite
: > "$PRUNE/inflight.$$.part"
: > "$PRUNE/inflight.$$.meta"
mkdir -p "$XDG_CONFIG_HOME/omarchy/gifs"
jq -n '{version:1,items:[{id:"f1"}]}' > "$XDG_CONFIG_HOME/omarchy/gifs/favorites.json"

gif_prune_cache "$PRUNE"
left=$(find "$PRUNE" -maxdepth 1 -type f ! -name '*.part' ! -name '*.meta' | wc -l)
(( left <= 400 && left >= 250 )) && ok "pruning trims the cache back ($left files left of 450)" \
  || no "pruning trims the cache back" "$left files left"
[[ -e $PRUNE/f1.preview ]] && ok "pruning keeps a file a favorite points at" \
  || no "pruning keeps a file a favorite points at" "the oldest file was a favorite and was deleted"
[[ -e $PRUNE/inflight.$$.part && -e $PRUNE/inflight.$$.meta ]] \
  && ok "pruning leaves in-flight temp files alone" \
  || no "pruning leaves in-flight temp files alone"
rm -f "$XDG_CONFIG_HOME/omarchy/gifs/favorites.json"

# ===========================================================================
group "the API key's directory is private"
# ===========================================================================
"$BIN/gif-secure-config"
mode=$(stat -c %a "$XDG_CONFIG_HOME/omarchy/gifs")
[[ $mode == 700 ]] && ok "config dir is 700" || no "config dir is 700" "is $mode"
mode=$(stat -c %a "$GIF_CONFIG_PATH")
[[ $mode == 600 ]] && ok "config.json is 600" || no "config.json is 600" "is $mode"

# ===========================================================================
printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$pass" "$fail" "$skip"
if (( fail > 0 )); then
  printf '\nfailed:\n'
  for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0

#!/bin/bash

# Network policy shared by every script here: what we are willing to talk to,
# and how many bytes we are willing to take from it.
#
# Two rules, both load-bearing:
#
#   1. Credentials never reach curl's argv. /proc/<pid>/cmdline is world
#      readable, so a key passed as an argument is readable by any process on
#      the machine for as long as the request runs. Requests are handed to curl
#      through --config on stdin instead.
#
#   2. Every response is capped and every host is checked. Search responses and
#      media downloads are attacker-influenced -- a hostile redirect, a
#      compromised CDN, or just a provider bug -- so nothing is parsed, cached,
#      or handed to ImageMagick before its size and origin have been checked.

# A 50-result search response measures ~480 KB, so 2 MB is generous. GIPHY
# renditions run 200 KB - 5 MB, so 16 MB leaves room for a large original
# without letting a download run away; previews are much smaller than that.
GIF_MAX_RESPONSE_BYTES="${GIF_MAX_RESPONSE_BYTES:-2000000}"
GIF_MAX_MEDIA_BYTES="${GIF_MAX_MEDIA_BYTES:-16777216}"
GIF_MAX_PREVIEW_BYTES="${GIF_MAX_PREVIEW_BYTES:-8388608}"
GIF_MAX_RESPONSE_SECONDS="${GIF_MAX_RESPONSE_SECONDS:-12}"
GIF_MAX_MEDIA_SECONDS="${GIF_MAX_MEDIA_SECONDS:-45}"
GIF_CONNECT_TIMEOUT="${GIF_CONNECT_TIMEOUT:-8}"

# Verify against *only* this CA bundle, instead of the system trust store.
# curl's --cacert replaces the default store rather than adding to it, so
# setting this to a corporate proxy's CA will fail verification for giphy.com
# and klipy.com and stop the plugin working. It exists for the test suite,
# which serves the oversized and never-ending responses over local HTTPS.
# Verification is never switched off either way.
GIF_CA_BUNDLE="${GIF_CA_BUNDLE:-}"

# Curl options common to every request we make.
gif_curl_base() {
  GIF_CURL_BASE=(--silent --location
    --proto '=https' --proto-redir '=https' --max-redirs 3
    --connect-timeout "$GIF_CONNECT_TIMEOUT")
  [[ -n $GIF_CA_BUNDLE ]] && GIF_CURL_BASE+=(--cacert "$GIF_CA_BUNDLE")
  # Not the status of that test: a caller under set -e must not trip over the
  # ordinary no-bundle case.
  return 0
}

GIF_CONFIG_PATH="${GIF_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/gifs/config.json}"

# Registrable domains we accept media from. Both providers serve renditions
# from their own domain -- GIPHY spreads them over media0-media4.giphy.com --
# so a suffix match at the domain level is tight enough to refuse a redirect to
# somewhere else entirely while surviving the provider adding another numbered
# CDN host. A deployment whose media really does live on a third-party CDN can
# add hosts with "allowedMediaDomains": ["cdn.example.net"] in config.json.
# A single-label entry is accepted, for a LAN host or "localhost"; it is the
# user's own config, so the breadth of what they add is their call.
GIF_MEDIA_DOMAINS=()

gif_load_media_domains() {
  (( ${#GIF_MEDIA_DOMAINS[@]} )) && return 0
  GIF_MEDIA_DOMAINS=(giphy.com klipy.com)

  [[ -f $GIF_CONFIG_PATH ]] || return 0
  local extra domain
  extra=$(jq -r '
    (.allowedMediaDomains // [])[]?
    | select(type == "string")
    | ascii_downcase
    | select(test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"))
  ' "$GIF_CONFIG_PATH" 2>/dev/null) || return 0

  while IFS= read -r domain; do
    [[ -n $domain ]] && GIF_MEDIA_DOMAINS+=("$domain")
  done <<<"$extra"
}

# Print the hostname of an https URL, or fail. Anything that is not plainly
# https://host/... is refused rather than guessed at: no other scheme, and no
# userinfo -- https://media0.giphy.com@evil.example/x points at evil.example,
# and a suffix match on the wrong half of that is exactly the bug to avoid.
gif_url_host() {
  local url="$1" authority host
  [[ $url == https://?* ]] || return 1
  authority=${url#https://}
  authority=${authority%%/*}
  authority=${authority%%\?*}
  authority=${authority%%#*}
  [[ $authority == *@* ]] && return 1
  host=${authority%%:*}
  [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  printf '%s' "${host,,}"
}

gif_host_allowed() {
  local host="$1" domain
  [[ -n $host ]] || return 1
  gif_load_media_domains
  for domain in "${GIF_MEDIA_DOMAINS[@]}"; do
    [[ $host == "$domain" || $host == *".$domain" ]] && return 0
  done
  return 1
}

gif_url_allowed() {
  local host
  host=$(gif_url_host "$1") || return 1
  gif_host_allowed "$host"
}

# The allowlist as JSON, for the jq filter below.
gif_media_domains_json() {
  gif_load_media_domains
  printf '%s\n' "${GIF_MEDIA_DOMAINS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# Drop results carrying a URL we would not fetch. The picker's own Image
# elements load previewUrl directly, which does not go through gif_fetch_media,
# so filtering here is what keeps the shell process from being pointed at an
# arbitrary host by a hostile response. Host parsing matches gif_url_host:
# https only, and no userinfo, so media0.giphy.com@evil.example does not pass.
#
# Expects the allowlist in $doms. pageUrl is allowed to be empty because the
# picker falls back to gifUrl for it.
GIF_RESULT_DEFS='
  def gif_host:
    (capture("^https://(?<h>[A-Za-z0-9.-]+)(?::[0-9]+)?(?:/|$)").h | ascii_downcase)? // null;
  def gif_allowed:
    gif_host as $h
    | ($h != null)
      and ($doms | map(. as $d | ($h == $d) or ($h | endswith("." + $d))) | any);
'
GIF_RESULT_FILTER='
  .results |= map(select(
    (.previewUrl | gif_allowed)
    and (.tinyGifUrl | gif_allowed)
    and (.gifUrl | gif_allowed)
    and ((.pageUrl // "") == "" or (.pageUrl | gif_allowed))
  ))
'

# Quote a value for curl's --config format, which understands \\ \" \t \r \n
# inside double quotes. Escaping the backslash first matters, and escaping the
# real control characters matters because a literal newline inside a value
# would end the config line and let a crafted key inject a curl option.
gif_cfg_quote() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

# Run a request whose options -- including the credential -- arrive on stdin,
# and ask for the status code on its own last line so an auth failure can be
# reported as such instead of collapsing into a generic network error.
#
# Prints "<body>\n<http_code>".
# Exit: 0 fetched, 2 the response hit the byte cap, 1 any other failure.
gif_http_get() {
  local request="$1" cap="$GIF_MAX_RESPONSE_BYTES" raw rc

  gif_curl_base

  raw=$(
    printf '%s\n' "$request" \
      | curl --config - "${GIF_CURL_BASE[@]}" \
          --max-time "$GIF_MAX_RESPONSE_SECONDS" \
          --max-filesize "$cap" \
          --write-out $'\n%{http_code}' 2>/dev/null \
      | head -c "$(( cap + 64 ))"
    exit "${PIPESTATUS[1]}"
  )
  rc=$?

  # 63 is curl refusing a response bigger than --max-filesize. 141 is curl
  # killed by head closing the pipe at the cap, which is what happens when the
  # server sent no Content-Length for --max-filesize to check -- head is what
  # makes the cap hold for a chunked or never-ending response.
  (( rc == 63 || rc == 141 )) && return 2
  # The status line rides along on the last line, so measure the body alone.
  (( $(printf '%s' "${raw%$'\n'*}" | wc -c) > cap )) && return 2
  (( rc == 0 )) || return 1

  printf '%s' "$raw"
}

# Trim the media cache back when it gets large. The picker caches a preview for
# every result and an animation for every tile the cursor rests on, so this
# would otherwise grow without limit. Oldest first, and never touching either
# something a favorite still points at or an in-flight temp file -- deleting a
# .part out from under a running download would publish nothing and cost a
# retry, and counting them would prune on a number that is not the cache size.
gif_prune_cache() {
  local dir="$1" keep=300 max=400 favorites count
  favorites="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/gifs/favorites.json"
  [[ -d $dir ]] || return 0

  local -a only=(-maxdepth 1 -type f ! -name '*.part' ! -name '*.meta')
  count=$(find "$dir" "${only[@]}" -printf '.' 2>/dev/null | wc -c)
  (( count > max )) || return 0

  local protected=""
  if [[ -f $favorites ]]; then
    protected=$(jq -r '.items[]?.id // empty' "$favorites" 2>/dev/null)
  fi

  local removed=0 target=$(( count - keep )) file base id
  while IFS= read -r file; do
    (( removed < target )) || break
    base=${file##*/}
    # Every suffix the cache uses, so a favorite's id is recognised whichever
    # of its files this is.
    id=${base%.tiny.gif}
    id=${id%.full.gif}
    id=${id%.preview}
    if [[ -n $protected ]] && grep -qxF "$id" <<<"$protected"; then continue; fi
    rm -f "$file" && removed=$(( removed + 1 ))
  done < <(find "$dir" "${only[@]}" -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-)
}

# Stream $url into $tmp, writing at most cap + 1 bytes, and leave the file
# where it is for the caller to judge. Separate from gif_fetch_media so that
# "never more than cap + 1 bytes reach the disk" is a property a test can
# measure directly, on a transfer still in progress.
#
# head is what makes that bound exact. Recent curl does abort a chunked
# transfer once --max-filesize is passed, but it notices only after handing us
# a buffer, so the file overshoots by however much that buffer held; older curl
# does not check an undeclared length at all. Closing the pipe at cap + 1 puts
# the limit on our side of the boundary either way.
#
# Sets GIF_STREAM_RC (curl) and GIF_STREAM_WRITE_RC (the write side). Both
# matter: curl can flush a short body into the pipe and exit 0 while the write
# to $tmp fails -- a full disk, a quota, a tmpfs cache dir -- and a truncated
# file must not then be published as a complete one.
gif_stream_capped() {
  local url="$1" tmp="$2" meta="$3" cap="$4"
  local -a status

  gif_curl_base

  # %{stderr} puts the effective URL on stderr, keeping it out of the body
  # stream so the caller's origin check still has it to check.
  # -- so a URL beginning with "-" is a URL and not an option.
  curl "${GIF_CURL_BASE[@]}" --fail \
    --max-time "$GIF_MAX_MEDIA_SECONDS" \
    --max-filesize "$cap" \
    --write-out '%{stderr}%{url_effective}' \
    --output - -- "$url" 2>"$meta" \
    | head -c "$(( cap + 1 ))" >"$tmp"

  # In one go: reading PIPESTATUS is itself a command, which replaces it, so
  # the second element has to come from the same copy.
  status=("${PIPESTATUS[@]}")
  GIF_STREAM_RC=${status[0]}
  GIF_STREAM_WRITE_RC=${status[1]:-0}
  return 0
}

# Download provider-controlled media to $dest, or fail without leaving a
# partial file behind. $dest only appears once the byte cap, the origin of the
# request and the origin it redirected to have all passed -- so a reader that
# treats the file's existence as "this is a usable GIF" is right.
#
# The cap is enforced *while the bytes arrive*, not afterwards. head closes the
# pipe one byte past the limit, curl dies of SIGPIPE, and the transfer stops
# there; at most cap + 1 bytes are ever written to disk. This is the part that
# --max-filesize cannot do on its own: it can only act on a Content-Length the
# server chose to send, so a chunked or never-ending response would otherwise
# stream until --max-time and fill the disk before any post-download check ran.
# --max-filesize is kept as the cheap early-out for when a length *is*
# declared, which refuses an oversized transfer before its first byte.
gif_fetch_media() {
  local url="$1" dest="$2" cap="${3:-$GIF_MAX_MEDIA_BYTES}"
  local final tmp meta rc write_rc size

  gif_url_allowed "$url" || return 1

  # $BASHPID, not $$: gif-preview fetches in background subshells, which all
  # share $$, so two jobs racing on one $dest would share both temp paths.
  tmp="$dest.$BASHPID.part"
  meta="$dest.$BASHPID.meta"
  gif_curl_base

  gif_stream_capped "$url" "$tmp" "$meta" "$cap"
  rc=$GIF_STREAM_RC
  write_rc=$GIF_STREAM_WRITE_RC

  size=$(stat -c %s "$tmp" 2>/dev/null) || size=0

  # One byte past the cap is the proof that the response was over it, whether
  # or not the server ever declared a length.
  if (( size > cap )); then rm -f "$tmp" "$meta"; return 1; fi
  if (( rc != 0 || write_rc != 0 || size == 0 )); then rm -f "$tmp" "$meta"; return 1; fi

  # Only the last line: --silent keeps curl quiet, but anything it does put on
  # stderr would otherwise be glued to the front of the effective URL and fail
  # the origin check on a download that was actually fine.
  final=$(tail -n1 "$meta" 2>/dev/null) || final=""
  rm -f "$meta"
  gif_url_allowed "$final" || { rm -f "$tmp"; return 1; }

  mv -f "$tmp" "$dest"
}

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

GIF_CONFIG_PATH="${GIF_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/gifs/config.json}"

# Registrable domains we accept media from. Both providers serve renditions
# from their own domain -- GIPHY spreads them over media0-media4.giphy.com --
# so a suffix match at the domain level is tight enough to refuse a redirect to
# somewhere else entirely while surviving the provider adding another numbered
# CDN host. A deployment whose media really does live on a third-party CDN can
# add hosts with "allowedMediaDomains": ["cdn.example.net"] in config.json.
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
    | select(test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"))
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

  raw=$(
    printf '%s\n' "$request" \
      | curl --config - \
          --silent --show-error --location \
          --proto '=https' --proto-redir '=https' --max-redirs 3 \
          --max-time "$GIF_MAX_RESPONSE_SECONDS" \
          --max-filesize "$cap" \
          --write-out $'\n%{http_code}' 2>/dev/null \
      | head -c "$(( cap + 64 ))"
    exit "${PIPESTATUS[1]}"
  )
  rc=$?

  # 63 is curl refusing a response bigger than --max-filesize. 141 is curl
  # killed by head closing the pipe at the cap, which is what happens when the
  # server sent no Content-Length for --max-filesize to check.
  (( rc == 63 || rc == 141 )) && return 2
  (( $(printf '%s' "$raw" | wc -c) > cap )) && return 2
  (( rc == 0 )) || return 1

  printf '%s' "$raw"
}

# Download provider-controlled media to $dest, or fail without leaving a
# partial file behind. The URL's host, the host it redirected to, and the byte
# count are all checked, and $dest only appears once all three pass -- so a
# reader that treats the file's existence as "this is a usable GIF" is right.
gif_fetch_media() {
  local url="$1" dest="$2" cap="${3:-$GIF_MAX_MEDIA_BYTES}"
  local host final tmp rc size

  gif_url_allowed "$url" || return 1

  tmp="$dest.$$.part"
  # -- so a URL beginning with "-" is a URL and not an option.
  final=$(curl --silent --fail --location \
    --proto '=https' --proto-redir '=https' --max-redirs 3 \
    --max-time "$GIF_MAX_MEDIA_SECONDS" \
    --max-filesize "$cap" \
    --write-out '%{url_effective}' \
    --output "$tmp" -- "$url" 2>/dev/null)
  rc=$?
  (( rc == 0 )) || { rm -f "$tmp"; return 1; }

  # A redirect that left the allowlist is refused even though the bytes are
  # already on disk, and the cap is re-checked against the file itself because
  # --max-filesize can only act on a Content-Length the server chose to send.
  gif_url_allowed "$final" || { rm -f "$tmp"; return 1; }

  size=$(stat -c %s "$tmp" 2>/dev/null) || size=0
  (( size > 0 && size <= cap )) || { rm -f "$tmp"; return 1; }

  mv -f "$tmp" "$dest"
}

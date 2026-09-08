#!/bin/bash

# Shared provider definitions for gif-search and gif-check.
#
# gif_build_request <provider> <key> <mode> <query> <limit> <content_filter>
#   sets REQ_REQUEST (a curl --config document) and REQ_NORMALIZE (a jq
#   program). Returns 1 for an unknown provider, 2 for a key we will not put
#   into a request.
#
# The whole request lives in REQ_REQUEST and is fed to curl on stdin by
# gif_http_get, so neither the key nor the search term ever reaches an argv.

HERE_PROVIDERS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gif-net.sh
source "$HERE_PROVIDERS/gif-net.sh"

GIF_PROVIDERS=(giphy klipy)

gif_build_request() {
  local provider="$1" key="$2" mode="$3" query="$4" limit="$5" content_filter="$6"
  local endpoint rating

  # Both providers issue alphanumeric keys. Insisting on that is what makes it
  # safe to interpolate KLIPY's key into a URL path: a key containing "/", "?"
  # or ".." would otherwise be able to retarget the request.
  [[ $key =~ ^[A-Za-z0-9._~-]{8,128}$ ]] || return 2

  case "$provider" in
    giphy)
      # GIPHY ratings are g / pg / pg-13 / r; map the shared filter names on.
      case "$content_filter" in
        off)    rating="r" ;;
        low)    rating="pg-13" ;;
        medium) rating="pg" ;;
        high)   rating="g" ;;
        *)      rating="pg" ;;
      esac

      if [[ $mode == "featured" ]]; then
        endpoint="https://api.giphy.com/v1/gifs/trending"
      else
        endpoint="https://api.giphy.com/v1/gifs/search"
      fi

      REQ_REQUEST="url = $(gif_cfg_quote "$endpoint")
get
data-urlencode = $(gif_cfg_quote "api_key=$key")
data-urlencode = $(gif_cfg_quote "limit=$limit")
data-urlencode = $(gif_cfg_quote "rating=$rating")"
      [[ -n $query ]] && REQ_REQUEST+="
data-urlencode = $(gif_cfg_quote "q=$query")"

      REQ_NORMALIZE='
        {
          ok: true,
          results: [
            .data[]?
            | select((.images.fixed_width.url // .images.downsized.url // .images.original.url) != null)
            | {
                id: ("g_" + ((.id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "-"))),
                title: (.title // ""),
                pageUrl: (.url // ""),
                gifUrl: (.images.original.url // .images.downsized.url // .images.fixed_width.url),
                tinyGifUrl: (.images.fixed_width.url // .images.downsized.url // .images.original.url),
                previewUrl: (.images.fixed_width_still.url // .images.original_still.url // .images.fixed_width.url),
                width:  (((.images.fixed_width.width  // "0") | tostring | tonumber?) // 0),
                height: (((.images.fixed_width.height // "0") | tostring | tonumber?) // 0)
              }
          ]
        }'
      ;;

    klipy)
      # KLIPY takes the key as a path segment and uses the same filter names.
      # The path is the one place a credential unavoidably sits in a URL --
      # their API has no header or query form -- so the mitigation is to keep
      # that URL out of argv and out of any diagnostic output.
      if [[ $mode == "featured" ]]; then
        endpoint="https://api.klipy.com/api/v1/$key/gifs/trending"
      else
        endpoint="https://api.klipy.com/api/v1/$key/gifs/search"
      fi

      REQ_REQUEST="url = $(gif_cfg_quote "$endpoint")
get
data-urlencode = $(gif_cfg_quote "per_page=$limit")
data-urlencode = $(gif_cfg_quote "page=1")
data-urlencode = $(gif_cfg_quote "content_filter=$content_filter")
data-urlencode = $(gif_cfg_quote "format_filter=gif,jpg")"
      [[ -n $query ]] && REQ_REQUEST+="
data-urlencode = $(gif_cfg_quote "q=$query")"

      # KLIPY nests the item list at .data.data and offers hd/md/sm renditions.
      # There is no shareable page URL in the response, so pageUrl is the direct
      # GIF link; the picker's pasteUrl:"page" setting falls back to it.
      REQ_NORMALIZE='
        {
          ok: true,
          results: [
            (.data.data // .data // [])[]?
            | select((.file.sm.gif.url // .file.md.gif.url // .file.hd.gif.url) != null)
            | {
                id: ("k_" + ((.slug // .id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "-"))),
                title: (.title // ""),
                pageUrl: (.file.hd.gif.url // .file.md.gif.url // .file.sm.gif.url),
                gifUrl: (.file.hd.gif.url // .file.md.gif.url // .file.sm.gif.url),
                tinyGifUrl: (.file.sm.gif.url // .file.md.gif.url // .file.hd.gif.url),
                previewUrl: (.file.sm.jpg.url // .file.md.jpg.url // .file.sm.gif.url // .file.md.gif.url),
                width:  (((.file.sm.gif.width  // 0) | tostring | tonumber?) // 0),
                height: (((.file.sm.gif.height // 0) | tostring | tonumber?) // 0)
              }
          ]
        }'
      ;;

    *)
      return 1
      ;;
  esac
}

# Translate an HTTP status into one of the picker's error codes, or "" for OK.
gif_status_error() {
  local provider="$1" status="$2"

  # KLIPY carries the key as a path segment, so a bad key does not resolve to a
  # route at all and comes back 404 rather than 401.
  if [[ $provider == "klipy" && $status == "404" ]]; then
    echo "bad-key"; return
  fi

  case "$status" in
    200)     echo "" ;;
    401|403) echo "bad-key" ;;
    429)     echo "rate-limit" ;;
    "")      echo "network" ;;
    *)       echo "http-$status" ;;
  esac
}

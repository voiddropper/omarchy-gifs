#!/bin/bash

# Shared provider definitions for gif-search and gif-check.
#
# gif_build_request <provider> <key> <mode> <query> <limit> <content_filter>
#   sets REQ_ARGS (curl argv) and REQ_NORMALIZE (jq program), or returns 1 for
#   an unknown provider. The key is only ever placed in the request itself --
#   callers keep it out of their own argv.

GIF_PROVIDERS=(giphy klipy)

gif_build_request() {
  local provider="$1" key="$2" mode="$3" query="$4" limit="$5" content_filter="$6"
  local endpoint rating

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

      REQ_ARGS=(--get "$endpoint"
        --data-urlencode "api_key=$key"
        --data-urlencode "limit=$limit"
        --data-urlencode "rating=$rating")
      [[ -n $query ]] && REQ_ARGS+=(--data-urlencode "q=$query")

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
      if [[ $mode == "featured" ]]; then
        endpoint="https://api.klipy.com/api/v1/$key/gifs/trending"
      else
        endpoint="https://api.klipy.com/api/v1/$key/gifs/search"
      fi

      REQ_ARGS=(--get "$endpoint"
        --data-urlencode "per_page=$limit"
        --data-urlencode "page=1"
        --data-urlencode "content_filter=$content_filter"
        --data-urlencode "format_filter=gif,jpg")
      [[ -n $query ]] && REQ_ARGS+=(--data-urlencode "q=$query")

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

# Ask curl for the status code on its own last line, so an auth failure can be
# reported as such instead of collapsing into a generic network error.
gif_http_get() {
  curl --silent --show-error --location --max-time 12 \
    --write-out $'\n%{http_code}' "$@" 2>/dev/null
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

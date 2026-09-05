import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "GifStore.js" as GifStore

// GIF picker overlay. Modelled on the first-party emoji picker: same layer
// surface, same [menu] theme tokens, same insert-into-focused-app trick.
// What differs is the source (a GIF provider over the network) and the favorites list,
// which is the default view because reused reaction GIFs outnumber new ones.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string home: Quickshell.env("HOME")
  property var shell: null
  property var manifest: null

  readonly property string configDir: home + "/.config/omarchy/gifs"
  readonly property string cacheDir: home + "/.cache/omarchy/gifs"

  // Resolve our own directory rather than assuming an install location, so the
  // helper scripts travel with the plugin and `omarchy plugin add` is a
  // complete install.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.substring(7)
    while (u.length > 1 && u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1)
    return u
  }
  readonly property string binDir: pluginDir + "/bin"

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false

  // "favorites" reads from disk and never touches the network; "search" is
  // whatever the provider last returned for filterText.
  property string mode: "favorites"

  property var config: GifStore.defaultConfig()
  property var favorites: []
  property var favoriteIds: ({})
  property var searchResults: []
  property var displayItems: []

  property bool searching: false
  property string searchError: ""
  property string lastRequestedQuery: ""

  // Qt's AnimatedImage will not play a GIF straight off an https URL in this
  // Quickshell build -- it loads, reports no error, and sits on frame one. It
  // animates fine from a local file, so every animation is served from disk and
  // the cursor tile pulls its GIF down on the way past. Ids that have landed
  // are tracked here; the still frame covers the gap.
  property var cachedIds: ({})
  property var cachedStillIds: ({})
  property var failedIds: ({})
  property string cachingId: ""

  readonly property bool hasApiKey: String(config.apiKey || "").length > 0
  readonly property string providerLabel: GifStore.providerLabel(config.provider)
  readonly property string providerHint: GifStore.providerSignupHint(config.provider)

  // ---------------------------------------------------------------- theming
  // Shares the [menu] surface tokens, so any theme that styles the menu and
  // the emoji picker styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Math.max(Style.space(18), Style.font.caption + Style.spacing.xs * 2)
  property int contentSpacing: Style.spacing.md

  property int cardWidth: Math.min(Style.space(920), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)
  readonly property int gridWidth: cardWidth - contentMargin * 2

  // Aim for roughly 250px tiles and divide the row evenly, so the grid never
  // leaves a ragged gutter on the right regardless of card width.
  property int columns: Math.max(2, Math.floor(gridWidth / Style.space(250)))
  property int cellWidth: Math.max(Style.space(80), Math.floor(gridWidth / columns))
  property int cellHeight: Math.round(cellWidth * 3 / 4)

  // ------------------------------------------------------------- lifecycle
  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.mode = "favorites"
    root.searchError = ""
    root.searchResults = []
    root.rebuildDisplay()
    root.scanCache()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function scanCache() {
    if (cacheListProc.running) return
    cacheListProc.command = [root.binDir + "/gif-cached"]
    cacheListProc.running = true
  }

  function applyCacheListing(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      var anim = ({})
      var still = ({})
      var a = Array.isArray(data.anim) ? data.anim : []
      var s = Array.isArray(data.still) ? data.still : []
      for (var i = 0; i < a.length; i++) anim[a[i]] = true
      for (var j = 0; j < s.length; j++) still[s[j]] = true
      root.cachedIds = anim
      root.cachedStillIds = still
    } catch (e) {
      // A cache we cannot read is the same as an empty one: everything falls
      // back to the remote still and downloads on demand.
    }
  }

  function close() {
    root.opened = false
    searchDebounce.stop()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mbw.gifs")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------- data load
  function loadConfig(raw) {
    root.config = GifStore.parseConfig(raw)
    if (root.opened && root.mode === "search" && root.filterText) root.runSearch()
  }

  function loadFavorites(raw) {
    var items = GifStore.parseFavorites(raw)
    root.favorites = items

    var ids = ({})
    for (var i = 0; i < items.length; i++) ids[items[i].id] = true
    root.favoriteIds = ids

    if (root.opened && root.mode === "favorites") root.rebuildDisplay()
  }

  function saveFavorites() {
    favoritesFile.setText(GifStore.serializeFavorites(root.favorites))
  }

  // ---------------------------------------------------------------- search
  function runSearch() {
    var query = root.filterText
    if (!query) return
    if (!root.hasApiKey) {
      root.searchError = "no-key"
      root.searchResults = []
      root.rebuildDisplay()
      return
    }

    root.lastRequestedQuery = query
    root.searching = true
    root.searchError = ""

    // A query that arrives while the previous one is still in flight replaces
    // it; the stale response is discarded on arrival anyway.
    if (searchProc.running) searchProc.running = false
    searchProc.command = [root.binDir + "/gif-search", query]
    searchProc.running = true
  }

  function applySearchResponse(raw) {
    root.searching = false

    // Ignore a response for a query the user has already typed past.
    if (root.lastRequestedQuery !== root.filterText) return

    var parsed = GifStore.parseSearchResponse(raw)
    if (!parsed.ok) {
      root.searchError = parsed.error
      root.searchResults = []
    } else {
      root.searchError = ""
      root.searchResults = parsed.results
    }
    root.selectedIndex = 0
    root.cursorActive = parsed.results.length > 0
    root.rebuildDisplay()
  }

  // ---------------------------------------------------------------- display
  function rebuildDisplay() {
    var out = root.mode === "favorites"
      ? GifStore.filterFavorites(root.favorites, root.filterText)
      : root.searchResults
    root.displayItems = out

    if (out.length === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= out.length) root.selectedIndex = out.length - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
    root.cursorActive = out.length > 0

    Qt.callLater(function() {
      if (root.displayItems.length > 0) resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    })
  }

  function setFilter(nextFilter) {
    var wasEmpty = root.filterText.length === 0
    root.filterText = nextFilter
    root.selectedIndex = 0

    if (!nextFilter) {
      // Clearing the query always drops back to the offline favorites view.
      searchDebounce.stop()
      root.mode = "favorites"
      root.searching = false
      root.searchError = ""
      root.searchResults = []
      root.rebuildDisplay()
      return
    }

    if (root.mode === "favorites" && wasEmpty) root.mode = "search"

    if (root.mode === "search") searchDebounce.restart()
    else root.rebuildDisplay()
  }

  function toggleMode() {
    searchDebounce.stop()
    if (root.mode === "favorites") {
      root.mode = "search"
      root.selectedIndex = 0
      if (root.filterText) root.runSearch()
      else root.rebuildDisplay()
    } else {
      root.mode = "favorites"
      root.selectedIndex = 0
      root.rebuildDisplay()
    }
  }

  // ------------------------------------------------------------ navigation
  function select(delta) {
    if (root.displayItems.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.displayItems.length - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + root.displayItems.length) % root.displayItems.length
    }
    resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
  }

  function selectRow(delta) {
    if (root.displayItems.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.displayItems.length - 1 : 0
      resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
      return
    }
    var next = root.selectedIndex + delta * root.columns
    if (next < 0) next = 0
    if (next >= root.displayItems.length) next = root.displayItems.length - 1
    root.selectedIndex = next
    resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
  }

  function selectPage(delta) {
    if (root.displayItems.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.displayItems.length - 1 : 0
      resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
      return
    }
    var visibleRows = Math.max(1, Math.floor(resultGrid.height / root.cellHeight))
    var next = root.selectedIndex + delta * root.columns * visibleRows
    if (next < 0) next = 0
    if (next >= root.displayItems.length) next = root.displayItems.length - 1
    root.selectedIndex = next
    resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
  }

  // ------------------------------------------------------------- favorites
  function isFavorite(id) {
    return root.favoriteIds[String(id || "")] === true
  }

  function toggleFavoriteAt(index) {
    if (index < 0 || index >= root.displayItems.length) return
    root.toggleFavorite(root.displayItems[index])
  }

  function toggleFavorite(item) {
    if (!item || !item.id) return
    var list = root.favorites.slice()
    var at = GifStore.indexOfId(list, item.id)

    if (at >= 0) {
      list.splice(at, 1)
      Quickshell.execDetached([root.binDir + "/gif-uncache", String(item.id)])
    } else {
      var entry = GifStore.normalizeItem(item)
      entry.addedAt = Math.floor(Date.now() / 1000)
      // Newest first, so a GIF you just saved is the first thing you see next
      // time the picker opens.
      list.unshift(entry)
      // Pull the media down now so the favorites view still renders offline.
      Quickshell.execDetached([root.binDir + "/gif-cache",
        String(entry.id), String(entry.previewUrl), String(entry.tinyGifUrl)])
    }

    root.favorites = list
    var ids = ({})
    for (var i = 0; i < list.length; i++) ids[list[i].id] = true
    root.favoriteIds = ids

    root.saveFavorites()
    if (root.mode === "favorites") {
      // Removing from the favorites view shortens the list under the cursor.
      var keep = root.selectedIndex
      root.rebuildDisplay()
      root.selectedIndex = Math.min(keep, Math.max(0, root.displayItems.length - 1))
    }
  }

  // ----------------------------------------------------------------- insert
  function activateIndex(index) {
    if (index < 0 || index >= root.displayItems.length) return
    root.applySelected(root.displayItems[index])
  }

  function applySelected(item) {
    if (!item) return
    var url = root.config.pasteUrl === "gif"
      ? (item.gifUrl || item.pageUrl)
      : (item.pageUrl || item.gifUrl)
    if (!url) return
    root.dismiss()
    Quickshell.execDetached([root.binDir + "/gif-insert", String(url)])
  }

  // ------------------------------------------------------------------ state
  function ensureCursorCached() {
    if (!root.opened || !root.cursorActive) return
    var item = root.displayItems[root.selectedIndex]
    if (!item || !item.id || !item.tinyGifUrl) return
    if (root.cachedIds[item.id] === true) return
    // A GIF whose download failed is not retried on every cursor pass; the
    // still frame stands in for it until the picker is reopened.
    if (root.failedIds[item.id] === true) return
    if (root.cachingId === item.id) return

    if (cacheProc.running) cacheProc.running = false
    root.cachingId = item.id
    cacheProc.command = [root.binDir + "/gif-cache",
      String(item.id), String(item.previewUrl), String(item.tinyGifUrl)]
    cacheProc.running = true
  }

  function markCached(id) {
    if (!id) return
    var next = ({})
    for (var k in root.cachedIds) next[k] = root.cachedIds[k]
    next[id] = true
    root.cachedIds = next

    var stills = ({})
    for (var s in root.cachedStillIds) stills[s] = root.cachedStillIds[s]
    stills[id] = true
    root.cachedStillIds = stills
  }

  function markFailed(id) {
    if (!id) return
    var next = ({})
    for (var k in root.failedIds) next[k] = root.failedIds[k]
    next[id] = true
    root.failedIds = next
  }

  onSelectedIndexChanged: cacheDebounce.restart()
  onDisplayItemsChanged: cacheDebounce.restart()

  // Scrubbing through a row with the arrow keys should not fire a download per
  // tile passed over -- only where the cursor comes to rest.
  Timer {
    id: cacheDebounce
    interval: 150
    repeat: false
    onTriggered: root.ensureCursorCached()
  }

  Process {
    id: cacheListProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCacheListing(text)
    }
  }

  Process {
    id: cacheProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) root.markCached(root.cachingId)
      else root.markFailed(root.cachingId)
      root.cachingId = ""
      // The cursor may have moved on while this one was downloading.
      cacheDebounce.restart()
    }
  }

  Timer {
    id: searchDebounce
    interval: 300
    repeat: false
    onTriggered: root.runSearch()
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySearchResponse(text)
    }
  }

  FileView {
    id: configFile
    path: root.configDir + "/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
    onFileChanged: reload()
  }

  FileView {
    id: favoritesFile
    path: root.configDir + "/favorites.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadFavorites(text())
    onLoadFailed: root.loadFavorites("")
    onFileChanged: reload()
  }

  // ------------------------------------------------------------------- view
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-gifs"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      // Swallow clicks that land on the card itself so they don't reach the
      // dismiss handler behind it.
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_D && (event.modifiers & Qt.ControlModifier)) {
            if (root.cursorActive) root.toggleFavoriteAt(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.toggleMode()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.selectRow(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.selectRow(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.selectPage(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.selectPage(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (root.displayItems.length > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: queryText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: modeBadge.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || (root.mode === "favorites" ? "Search favorites…" : "Search " + root.providerLabel + "…")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: modeBadge
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.searching
              ? "searching…"
              : (root.mode === "favorites" ? "★ Favorites" : root.providerLabel)
            color: root.selectedText
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // -------------------------------------------------------------- grid
        Item {
          id: gridArea
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          GridView {
            id: resultGrid
            anchors.fill: parent
            model: root.displayItems
            visible: root.displayItems.length > 0
            clip: true
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: root.cellHeight * 2

            delegate: Item {
              id: tile
              required property int index
              required property var modelData

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
              readonly property bool favorite: root.favoriteIds[modelData.id] === true

              // A favorited GIF has its still frame on disk, so the favorites
              // view renders with no network at all. If the cache file is
              // missing the Image falls back to the remote URL on its own.
              readonly property string localStill: root.cachedStillIds[modelData.id] === true
                ? "file://" + root.cacheDir + "/" + modelData.id + ".preview" : ""
              readonly property string localAnim: "file://" + root.cacheDir + "/" + modelData.id + ".tiny.gif"
              readonly property bool animAvailable: root.cachedIds[modelData.id] === true

              property bool stillFellBack: false
              property bool animReady: false

              // Drop the decoded animation as soon as the cursor leaves, so
              // scrubbing through a long result list does not accumulate one
              // live GIF per tile visited.
              onHasCursorChanged: if (!hasCursor) animReady = false

              width: root.cellWidth
              height: root.cellHeight

              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.spacing.xs
                radius: root.cornerRadius
                color: tile.hasCursor ? root.selectedBackground : "transparent"
                border.width: tile.hasCursor ? Math.max(1, Style.space(1)) : 0
                border.color: tile.hasCursor ? root.selectedText : "transparent"
                clip: true

                // Static first frame. Always present, so there is something to
                // look at before the animation has downloaded.
                Image {
                  id: still
                  anchors.fill: parent
                  anchors.margins: Style.spacing.xs
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  cache: true
                  visible: !tile.animReady
                  source: (tile.localStill !== "" && !tile.stillFellBack) ? tile.localStill : tile.modelData.previewUrl
                  onStatusChanged: {
                    if (status === Image.Error && !tile.stillFellBack && tile.localStill !== "")
                      tile.stillFellBack = true
                  }
                }

                // The animation is instantiated only for the tile under the
                // cursor. A grid full of decoding GIFs is the one thing that
                // makes this picker feel slow.
                Loader {
                  id: anim
                  anchors.fill: parent
                  anchors.margins: Style.spacing.xs
                  active: tile.hasCursor && tile.animAvailable
                  sourceComponent: AnimatedImage {
                    fillMode: Image.PreserveAspectFit
                    cache: false
                    playing: true
                    speed: 1.0
                    source: tile.localAnim
                    onStatusChanged: tile.animReady = (status === Image.Ready)
                  }
                }

                // Favorite marker, top-right, over the image.
                Text {
                  textFormat: Text.PlainText
                  anchors.top: parent.top
                  anchors.right: parent.right
                  anchors.margins: Style.spacing.sm
                  visible: tile.favorite
                  text: "★"
                  color: root.selectedText
                  style: Text.Outline
                  styleColor: root.background
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onContainsMouseChanged: if (containsMouse) {
                    root.cursorActive = true
                    root.selectedIndex = tile.index
                  }
                  onClicked: function(mouse) {
                    root.cursorActive = true
                    root.selectedIndex = tile.index
                    if (mouse.button === Qt.RightButton) root.toggleFavorite(tile.modelData)
                    else root.activateIndex(tile.index)
                  }
                }
              }
            }
          }

          // ------------------------------------------------------ empty states
          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(40)
            spacing: Style.space(10)
            visible: root.displayItems.length === 0 && !root.searching

            readonly property bool needsKey: root.searchError === "no-key" || root.searchError === "bad-key"
              || (!root.hasApiKey && root.mode === "search")
            readonly property bool failed: root.searchError !== "" && !needsKey

            Text {
              textFormat: Text.PlainText
              text: parent.needsKey ? "󰌆" : (parent.failed ? "󰅚" : "󰈉")
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              text: {
                if (parent.needsKey) {
                  return root.searchError === "bad-key"
                    ? "That " + root.providerLabel + " key was rejected"
                    : "Add a " + root.providerLabel + " API key to search"
                }
                if (parent.failed) {
                  if (root.searchError === "network")
                    return "Could not reach " + root.providerLabel + " — check your connection"
                  if (root.searchError === "rate-limit")
                    return root.providerLabel + " rate limit reached — try again shortly"
                  if (root.searchError === "bad-provider")
                    return "Unknown provider in config.json — use \"giphy\" or \"klipy\""
                  return root.providerLabel + " request failed (" + root.searchError + ")"
                }
                if (root.mode === "favorites" && root.filterText)
                  return "No favorite matches “" + root.filterText + "”"
                if (root.mode === "favorites")
                  return "No favorites yet"
                if (root.filterText)
                  return "No GIFs for “" + root.filterText + "”"
                return "Start typing to search " + root.providerLabel
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              visible: text.length > 0
              text: {
                if (parent.needsKey)
                  return root.providerHint + ",\n"
                       + "then put it in " + root.configDir + "/config.json as \"apiKey\"."
                if (root.mode === "favorites" && !root.filterText)
                  return "Type to search " + root.providerLabel + ", then press Ctrl+D on a GIF to save it here."
                return ""
              }
            }
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            visible: root.searching && root.displayItems.length === 0
            text: "Searching " + root.providerLabel + "…"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }

        // ------------------------------------------------------------ footer
        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            elide: Text.ElideRight
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: "Enter or click paste   ·   Ctrl+D or right-click favorite   ·   Tab "
                + (root.mode === "favorites" ? "search " + root.providerLabel : "favorites")
                + "   ·   Esc close"
          }
        }
      }
    }
  }
}

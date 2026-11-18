import SwiftUI

// AppsSheet.swift — the Apps page. v1.0.63 it was a sheet off a
// floating "Apps" pill; v1.0.64 it is a tab in the bottom nav bar
// (Remote / Apps), in place of the pad — no sheet, no pill. It
// shows the TV's installed apps as a grid of branded tiles — tap
// one and it launches on the TV immediately.
//
// App list + launch per brand:
//   Roku: ECP /query/apps + /query/icon/<id> (the TV's own icons),
//         launch via POST /launch/<id>.
//   LG webOS: listLaunchPoints (the TV's own icons), launch via the
//         launcher API.
//   Samsung Tizen: the installed-apps API lists apps, launch by app
//         id. The API gives NO icon, so Samsung tiles are bundled
//         brand tiles (matched by name) or a generic initial tile.
//   Android TV: the remote protocol cannot list installed apps, so
//         the sheet shows a curated set of popular apps
//         (AndroidTVAppCatalog, deep links verified against the
//         open-tv-remote fork) and launches each by its deep link —
//         the app opens if it is installed. The sheet says so in a
//         footnote; it never pretends the list came from the TV.
//
// Customization (v1.0.63): Edit mode hides apps and drags them into
// the order the user picks; the set + order persist per TV
// (AppsCustomization, keyed by host). Hidden apps are not deleted —
// they stay in Edit mode's Hidden section and can be shown again.
// Newly installed apps appear visible at the end of the list.
// Bulk select (v1.0.63) is gone in v1.0.65: first-run setup
// means the user only ever picks the apps they want, so Select
// all / Deselect all / Hide selected were dead weight. Edit mode
// now uses a Toggle per row instead of the eye (ON = shown,
// OFF = hidden).
//
// First-run setup (v1.0.64): the first time the Apps tab opens for
// a TV, a setup screen asks which apps the user wants visible — a
// searchable checklist, Done to finish. The grid starts with only
// what they picked, never 50+ apps to deselect. v1.0.63 users who
// already configured a TV skip setup (their saved prefs count).
//
// Reload (v1.0.64): every Apps open reloads fresh, failed loads
// retry automatically a few times with a short backoff, and the
// last good list is cached per TV and shown immediately while a
// reload runs — the page is never empty while refreshing, and the
// user never has to tap Retry.
//
// Duplicates (v1.0.64): the list is deduplicated before display —
// same launch id, or the same app under two names ("HBO Max" vs
// "Max") — one tile. Brand tiles are matched on a normalized
// name, so renames still get their artwork.

/// One app in the Apps page: the TV's real installed app (Roku /
/// LG / Samsung) or a curated deep-link entry on Android TV, where
/// the protocol cannot list installed apps. `id` is the launch key:
/// the app id on Roku / Samsung / LG, the deep link on Android TV.
struct TVAppItem: Identifiable, Hashable {
    let id: String
    let name: String
    let iconURL: URL?

    init(id: String, name: String, iconURL: URL? = nil) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
    }
}

/// A bundled text-based brand tile (v1.0.63): the brand's wordmark
/// on the brand's color, drawn with text only — no trademarked logo
/// files, the same approach as the existing brand badges in
/// DiscoveryListView.
struct BrandTileStyle {
    let background: Color
    let foreground: Color
    let label: String
}

enum AppBrandArt {
    /// Catalog apps matched by name: exact match, then the longest
    /// name the app's name starts with (ported from open-tv-remote's
    /// AppCatalog, v1.0.63). Sling / ESPN / TikTok are the tiles from
    /// Nick's EVOLLY screenshot that the fork's catalog doesn't have.
    /// v1.0.64 adds the apps Nick named while scrolling (HBO Max
    /// rides the Max tile via the alias below; Discovery+, Fubo,
    /// Stremio, Fandango, Universal Guide get their own tiles).
    static let catalog: [(key: String, style: BrandTileStyle)] = [
        ("netflix", BrandTileStyle(background: Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255), foreground: Color(red: 0xE5 / 255, green: 0x09 / 255, blue: 0x14 / 255), label: "NETFLIX")),
        ("youtube tv", BrandTileStyle(background: .white, foreground: Color(red: 0xCC / 255, green: 0x00 / 255, blue: 0x00 / 255), label: "YouTube TV")),
        ("youtube", BrandTileStyle(background: .white, foreground: Color(red: 0xFF / 255, green: 0x00 / 255, blue: 0x00 / 255), label: "YouTube")),
        ("prime video", BrandTileStyle(background: Color(red: 0x00 / 255, green: 0xA8 / 255, blue: 0xE1 / 255), foreground: .white, label: "prime video")),
        ("disney+", BrandTileStyle(background: Color(red: 0x0B / 255, green: 0x1F / 255, blue: 0x5C / 255), foreground: .white, label: "Disney+")),
        ("hulu", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0xE7 / 255, blue: 0x83 / 255), foreground: Color(red: 0x0B / 255, green: 0x0C / 255, blue: 0x0F / 255), label: "hulu")),
        ("max", BrandTileStyle(background: Color(red: 0x00 / 255, green: 0x2B / 255, blue: 0xE7 / 255), foreground: .white, label: "max")),
        ("apple tv", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: .white, label: "Apple TV")),
        ("peacock", BrandTileStyle(background: .black, foreground: .white, label: "Peacock")),
        ("paramount+", BrandTileStyle(background: Color(red: 0x00 / 255, green: 0x64 / 255, blue: 0xFF / 255), foreground: .white, label: "Paramount+")),
        ("crunchyroll", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255), label: "Crunchyroll")),
        ("tubi", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: .white, label: "Tubi")),
        ("pluto tv", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: .white, label: "Pluto TV")),
        ("twitch", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: .white, label: "Twitch")),
        ("spotify", BrandTileStyle(background: Color(red: 0x1D / 255, green: 0xB9 / 255, blue: 0x54 / 255), foreground: Color(red: 0x0B / 255, green: 0x0C / 255, blue: 0x0F / 255), label: "Spotify")),
        ("plex", BrandTileStyle(background: Color(red: 0x1F / 255, green: 0x23 / 255, blue: 0x26 / 255), foreground: Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255), label: "Plex")),
        ("jellyfin", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: .white, label: "Jellyfin")),
        ("emby", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: .white, label: "Emby")),
        ("sling", BrandTileStyle(background: Color(red: 0x00 / 255, green: 0x2A / 255, blue: 0x5C / 255), foreground: .white, label: "sling")),
        ("espn", BrandTileStyle(background: Color(red: 0xCC / 255, green: 0x00 / 255, blue: 0x00 / 255), foreground: .white, label: "ESPN")),
        ("tiktok", BrandTileStyle(background: .black, foreground: .white, label: "TikTok")),
        ("discovery+", BrandTileStyle(background: Color(red: 0x0E / 255, green: 0x2A / 255, blue: 0x47 / 255), foreground: .white, label: "discovery+")),
        ("fubo", BrandTileStyle(background: Color(red: 0x00 / 255, green: 0xA8 / 255, blue: 0x96 / 255), foreground: .white, label: "fubo")),
        ("stremio", BrandTileStyle(background: Color(red: 0x6C / 255, green: 0x4C / 255, blue: 0xF1 / 255), foreground: .white, label: "Stremio")),
        ("fandango", BrandTileStyle(background: Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x00 / 255), foreground: .white, label: "Fandango")),
        ("universal guide", BrandTileStyle(background: Color(red: 0x23 / 255, green: 0x2B / 255, blue: 0x3E / 255), foreground: .white, label: "Universal Guide")),
    ]

    /// Renames and short forms that mean the same app as a
    /// catalog key (v1.0.64): "HBO Max" IS Max (the app was
    /// renamed twice), "Discovery" is Discovery+.
    static let aliases: [String: String] = [
        "hbo max": "max",
        "hbomax": "max",
        "discovery": "discovery+",
    ]

    /// A name reduced to its canonical key: lowercase, trimmed,
    /// internal whitespace collapsed, aliases resolved. "HBO Max"
    /// and "Max" both become "max"; "  Crunchyroll  " becomes
    /// "crunchyroll". Pure, so tests drive it directly.
    static func canonicalKey(for name: String) -> String {
        let normalized = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return aliases[normalized] ?? normalized
    }

    /// The brand tile for an app name, or nil when no catalog app
    /// matches (the caller falls back to the generic tile).
    /// Matched on the canonical key, so renames and stray spaces
    /// still get their artwork.
    static func match(name: String) -> BrandTileStyle? {
        let key = canonicalKey(for: name)
        if let hit = catalog.first(where: { $0.key == key }) { return hit.style }
        return catalog
            .filter { key.hasPrefix($0.key) }
            .max(by: { $0.key.count < $1.key.count })?.style
    }

    /// Generic tile for an app with no brand match: its initial
    /// letter on a neutral tint — never a blank tile, and only a
    /// last resort for truly unknown apps.
    static func generic(name: String) -> BrandTileStyle {
        let letter = name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
        return BrandTileStyle(background: Color.primary.opacity(0.12), foreground: .primary,
                              label: letter.isEmpty ? "?" : letter)
    }

    static func tile(for name: String) -> BrandTileStyle {
        match(name: name) ?? generic(name: name)
    }
}

/// The Android TV fallback list (v1.0.63): the remote protocol
/// cannot list installed apps, so the Apps page offers these
/// popular apps and launches each by its deep link — the app opens
/// if it is installed on the TV. Deep links from open-tv-remote's
/// AppCatalog, verified against the fork (Nov 17): https links open
/// the app directly, `market://launch?id=<package>` launches any
/// app by package name (Home Assistant deep-link guide).
enum AndroidTVAppCatalog {
    static let apps: [TVApp] = [
        TVApp(name: "Netflix", launchID: "https://www.netflix.com/title", iconURL: nil),
        TVApp(name: "YouTube", launchID: "https://www.youtube.com", iconURL: nil),
        TVApp(name: "Prime Video", launchID: "https://app.primevideo.com", iconURL: nil),
        TVApp(name: "Disney+", launchID: "https://www.disneyplus.com", iconURL: nil),
        TVApp(name: "Hulu", launchID: "https://www.hulu.com", iconURL: nil),
        TVApp(name: "Max", launchID: "https://play.max.com", iconURL: nil),
        TVApp(name: "Apple TV", launchID: "https://tv.apple.com", iconURL: nil),
        TVApp(name: "YouTube TV", launchID: "https://tv.youtube.com", iconURL: nil),
        TVApp(name: "Peacock", launchID: "https://www.peacocktv.com", iconURL: nil),
        TVApp(name: "Paramount+", launchID: "https://www.paramountplus.com", iconURL: nil),
        TVApp(name: "Crunchyroll", launchID: "market://launch?id=com.crunchyroll.crunchyroid", iconURL: nil),
        TVApp(name: "Tubi", launchID: "market://launch?id=com.tubitv", iconURL: nil),
        TVApp(name: "Pluto TV", launchID: "market://launch?id=tv.pluto.android", iconURL: nil),
        TVApp(name: "Twitch", launchID: "market://launch?id=tv.twitch.android.app", iconURL: nil),
        TVApp(name: "Spotify", launchID: "spotify://", iconURL: nil),
        TVApp(name: "Plex", launchID: "plex://", iconURL: nil),
        TVApp(name: "Jellyfin", launchID: "market://launch?id=org.jellyfin.androidtv", iconURL: nil),
        TVApp(name: "Emby", launchID: "market://launch?id=com.mb.android", iconURL: nil),
    ]
}

/// Per-TV Apps customization (v1.0.63): which apps show and in
/// what order, saved in UserDefaults keyed by the TV's host, so
/// the Samsung's arrangement stays separate from the QM7's.
/// Changes save the moment they are made — there is no separate
/// save step to lose; Done just leaves edit mode.
enum AppsCustomization {
    private static func orderKey(host: String) -> String { "apps.order.\(host)" }
    private static func hiddenKey(host: String) -> String { "apps.hidden.\(host)" }
    private static func setupKey(host: String) -> String { "apps.setupDone.\(host)" }

    static func load(host: String) -> (order: [String], hidden: Set<String>) {
        let order = UserDefaults.standard.stringArray(forKey: orderKey(host: host)) ?? []
        let hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey(host: host)) ?? [])
        return (order, hidden)
    }

    static func save(host: String, order: [String], hidden: Set<String>) {
        UserDefaults.standard.set(order, forKey: orderKey(host: host))
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey(host: host))
    }

    /// First-run setup done for this TV (v1.0.64): true once the
    /// user finished setup, OR when this TV already has saved
    /// prefs from v1.0.63 — those users configured their apps
    /// already, so setup must not force them through it again.
    static func setupDone(host: String) -> Bool {
        if UserDefaults.standard.bool(forKey: setupKey(host: host)) { return true }
        let prefs = load(host: host)
        return !prefs.order.isEmpty || !prefs.hidden.isEmpty
    }

    static func markSetupDone(host: String) {
        UserDefaults.standard.set(true, forKey: setupKey(host: host))
    }

    /// The ids to show, in the user's order: the saved order
    /// first, then any app the TV has that isn't in the saved
    /// order yet — newly installed apps appear visible at the
    /// end — minus hidden apps. Pure, so tests drive it directly.
    static func visibleIDs(installedIDs: [String], order: [String], hidden: Set<String>) -> [String] {
        let visible = installedIDs.filter { !hidden.contains($0) }
        let ordered = order.filter { visible.contains($0) }
        let fresh = visible.filter { !ordered.contains($0) }
        return ordered + fresh
    }

    /// Show or hide one app (v1.0.65): the Toggle in Edit mode.
    /// Showing appends the id to the order (it lands at the end
    /// of Shown); hiding drops it from the order and adds it to
    /// hidden. Pure, so tests drive it directly.
    static func setShown(id: String, shown: Bool, order: [String], hidden: Set<String>) -> (order: [String], hidden: Set<String>) {
        if shown {
            let newOrder = order.contains(id) ? order : order + [id]
            return (newOrder, hidden.subtracting([id]))
        }
        return (order.filter { $0 != id }, hidden.union([id]))
    }

    /// Apply a drag move inside the shown section to the saved
    /// order: the moved visible ids take their new positions; ids
    /// not shown (hidden, or no longer installed) keep their
    /// relative order after them. Pure.
    static func move(order: [String], visibleIDs: [String], from: IndexSet, to: Int) -> [String] {
        var moved = visibleIDs
        moved.move(fromOffsets: from, toOffset: to)
        let rest = order.filter { !moved.contains($0) }
        return moved + rest
    }

    /// Collapse duplicate apps (v1.0.64): the same launch id
    /// twice, or the same app under two names ("HBO Max" vs
    /// "Max") — one tile. When the same app appears twice, the
    /// entry with a real icon wins. Pure.
    static func deduplicate(_ items: [TVAppItem]) -> [TVAppItem] {
        var byID: [String: Int] = [:]
        var byName: [String: Int] = [:]
        var out: [TVAppItem] = []
        for item in items {
            let nameKey = AppBrandArt.canonicalKey(for: item.name)
            if let idx = byID[item.id] ?? byName[nameKey] {
                if out[idx].iconURL == nil, item.iconURL != nil { out[idx] = item }
                continue
            }
            byID[item.id] = out.count
            byName[nameKey] = out.count
            out.append(item)
        }
        return out
    }

    /// Search match (v1.0.64): an empty query matches everything;
    /// otherwise a case-insensitive substring of the name. Pure.
    static func matchesSearch(name: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return name.lowercased().contains(q)
    }
}

/// The last good app list, cached per TV (v1.0.64): the Apps page
/// shows it immediately while a reload runs, so the page is never
/// empty on a slow or failed refresh. Saved in UserDefaults keyed
/// by the TV's host, next to the customization prefs.
enum AppsCache {
    private static func key(host: String) -> String { "apps.cache.\(host)" }

    static func save(host: String, items: [TVAppItem]) {
        let dicts = items.map { ["id": $0.id, "name": $0.name, "icon": $0.iconURL?.absoluteString ?? ""] }
        UserDefaults.standard.set(dicts, forKey: key(host: host))
    }

    static func load(host: String) -> [TVAppItem]? {
        guard let dicts = UserDefaults.standard.array(forKey: key(host: host)) as? [[String: String]] else { return nil }
        let items = dicts.compactMap { d -> TVAppItem? in
            guard let id = d["id"], let name = d["name"], !id.isEmpty, !name.isEmpty else { return nil }
            let icon = d["icon"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
            return TVAppItem(id: id, name: name, iconURL: icon)
        }
        return items.isEmpty ? nil : items
    }
}

/// The Apps tab (v1.0.64): the TV's installed apps as a grid of
/// branded tiles — tap one and it launches on the TV immediately,
/// then the tab switches back to the remote (onLaunch). The view
/// is created fresh every time the Apps tab is selected, so the
/// list reloads on every open — leaving the remote and coming
/// back can never leave a stale "couldn't load" state.
struct AppsView: View {
    @ObservedObject var session: RemoteSession
    /// Called after an app launches, so the tab can switch back
    /// to the remote (v1.0.63's sheet dismissed on launch).
    var onLaunch: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    private enum LoadState { case loading, loaded, failed(String) }

    @State private var loadState: LoadState = .loading
    @State private var items: [TVAppItem] = []
    @State private var order: [String] = []
    @State private var hidden: Set<String> = []
    @State private var isEditing = false
    /// Search (v1.0.64): one clean search bar, filters the grid,
    /// the setup checklist, and Edit mode by name as you type.
    @State private var searchText = ""
    /// First-run setup (v1.0.64): per TV — the grid starts with
    /// only what the user picks on first open, never 50+ apps.
    @State private var setupDone = false
    @State private var setupSelection: Set<String> = []
    /// Background refresh (v1.0.64): the last good list shows
    /// while a reload is in flight; a small note says when the
    /// refresh failed and the list is stale.
    @State private var isRefreshing = false
    @State private var showingStaleNote = false
    /// A load already in flight — .task on appear plus the
    /// foreground refresh must never stack two loads.
    @State private var loadInFlight = false

    private var visibleItems: [TVAppItem] {
        let ids = AppsCustomization.visibleIDs(installedIDs: items.map(\.id), order: order, hidden: hidden)
        // First wins on a duplicate id (a TV list shouldn't have
        // one — but a duplicate must never crash the page).
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    private var hiddenItems: [TVAppItem] {
        items.filter { hidden.contains($0.id) }
    }

    /// The lists filtered by the search bar (v1.0.64).
    private var searchedVisibleItems: [TVAppItem] {
        visibleItems.filter { AppsCustomization.matchesSearch(name: $0.name, query: searchText) }
    }

    private var searchedHiddenItems: [TVAppItem] {
        hiddenItems.filter { AppsCustomization.matchesSearch(name: $0.name, query: searchText) }
    }

    private var searchedItems: [TVAppItem] {
        items.filter { AppsCustomization.matchesSearch(name: $0.name, query: searchText) }
    }

    private var isAndroidTV: Bool { session.device.brand == .androidTV }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch loadState {
            case .loading:
                Spacer()
                ProgressView("Loading apps…")
                    .foregroundStyle(.secondary)
                Spacer()
            case .failed(let message):
                Spacer()
                VStack(spacing: 12) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Retry is only the last resort now (v1.0.64):
                    // loads retry automatically first.
                    Button("Retry") { Task { await load() } }
                        .font(.subheadline.bold())
                }
                .padding(24)
                Spacer()
            case .loaded:
                if !setupDone {
                    setupView
                } else {
                    searchBar
                    if showingStaleNote {
                        Text("Couldn't refresh — showing your saved apps.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    if isEditing {
                        editList
                    } else {
                        grid
                    }
                }
            }
        }
        // The view is created fresh on every Apps-tab open, so
        // this fires on every open — never a stale list.
        .task { await load() }
        // Coming back from the background (v1.0.64): the session's
        // driver connection may have gone stale while away — the
        // reload re-connects if needed and refreshes the list, so
        // the user never sees a dead "couldn't load" state.
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await load() } }
        }
    }

    /// Header: "Apps" title plus the Edit control. The Edit
    /// button (v1.0.64) is an unmistakable labeled capsule —
    /// pencil icon + "Edit apps" text (checkmark + "Done" while
    /// editing) — instead of the bare text "Edit" nobody
    /// recognized as a button.
    private var header: some View {
        HStack {
            Text("Apps")
                .font(.title2.bold())
            // A small spinner while a background refresh runs
            // (v1.0.64): the last good list is already showing,
            // so this is just the "still loading" cue.
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            if case .loaded = loadState, setupDone {
                Button {
                    isEditing.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                        Text(isEditing ? "Done" : "Edit apps")
                    }
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isEditing ? remoteAccent.opacity(0.15) : Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(isEditing ? remoteAccent : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// One clean search bar (v1.0.64): magnifier, field, clear
    /// button. Filters the grid, the setup checklist, and Edit
    /// mode by name as you type.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $searchText)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// The grid of shown apps: the TV's own icon where the brand
    /// provides one, else the bundled brand tile.
    private var grid: some View {
        ScrollView {
            if visibleItems.isEmpty {
                VStack(spacing: 8) {
                    Text("All apps are hidden.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tap Edit apps to show them again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)
            } else if searchedVisibleItems.isEmpty {
                VStack(spacing: 8) {
                    Text("No apps match \"\(searchText)\".")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    ForEach(searchedVisibleItems) { item in
                        Button {
                            Task {
                                await session.launchAppItem(item)
                                onLaunch?()
                            }
                        } label: {
                            VStack(spacing: 6) {
                                appTile(item: item)
                                Text(item.name)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            if isAndroidTV {
                Text("Android TV can't list its installed apps — these are popular apps. Tapping one opens it if it's installed on this TV.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
    }

    /// First-run setup (v1.0.64): the first time the Apps tab
    /// opens for a TV, ask which apps the user wants visible — a
    /// searchable checklist, Done to finish. The grid starts with
    /// only what they picked; everything else is hidden (and
    /// recoverable in Edit). Nothing is visible by default, so
    /// nobody has to deselect 50 apps.
    private var setupView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose your apps")
                    .font(.title2.bold())
                Text("Pick the apps you want on this TV. You can change this anytime in Edit apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            searchBar
            HStack(spacing: 20) {
                Button("Select all") { setupSelection = Set(items.map(\.id)) }
                Button("Deselect all") { setupSelection.removeAll() }
                Spacer()
                Text("\(setupSelection.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.bold())
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(searchedItems) { item in
                        Button {
                            if setupSelection.contains(item.id) {
                                setupSelection.remove(item.id)
                            } else {
                                setupSelection.insert(item.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AppBrandTile(name: item.name)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(item.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: setupSelection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(setupSelection.contains(item.id) ? remoteAccent : .secondary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Done") { finishSetup() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(remoteAccent, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    /// Finish setup: the picked apps, in the TV's list order,
    /// become the shown set; everything else is hidden (not
    /// deleted — recoverable in Edit). Setup is done for this TV.
    private func finishSetup() {
        guard let host = session.device.host else { return }
        let picked = items.filter { setupSelection.contains($0.id) }.map(\.id)
        order = picked
        hidden = Set(items.map(\.id)).subtracting(setupSelection)
        // Dismiss first (v1.0.65): the setup screen goes away in
        // the same frame as the tap. The persistence runs on the
        // next runloop turn, after the dismiss has landed — the
        // Done tap used to do its UserDefaults writes and state
        // flips synchronously on the main thread before the first
        // post-tap frame could land, which read as a ~1s freeze.
        setupDone = true
        let orderToSave = order, hiddenToSave = hidden
        DispatchQueue.main.async {
            AppsCustomization.save(host: host, order: orderToSave, hidden: hiddenToSave)
            AppsCustomization.markSetupDone(host: host)
        }
    }

    /// Edit mode: the full installed list, split into Shown (drag
    /// to reorder, toggle off to hide) and Hidden (toggle on to
    /// show again). Changes save immediately; Done just leaves
    /// edit mode. Search filters both sections; dragging is off
    /// while searching (a filtered move would corrupt the order).
    private var editList: some View {
        VStack(spacing: 0) {
            List {
                Section("Shown") {
                    if searchText.isEmpty {
                        ForEach(searchedVisibleItems) { item in
                            editRow(item: item, isHidden: false)
                                .listRowBackground(GlassCardBackground())
                        }
                        .onMove { from, to in
                            order = AppsCustomization.move(order: order, visibleIDs: visibleItems.map(\.id),
                                                           from: from, to: to)
                            savePrefs()
                        }
                    } else {
                        ForEach(searchedVisibleItems) { item in
                            editRow(item: item, isHidden: false)
                                .listRowBackground(GlassCardBackground())
                        }
                    }
                }
                if !searchedHiddenItems.isEmpty {
                    Section("Hidden") {
                        ForEach(searchedHiddenItems) { item in
                            editRow(item: item, isHidden: true)
                                .listRowBackground(GlassCardBackground())
                        }
                    }
                }
            }
            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .environment(\.editMode, .constant(.active))
            .background(AppBackground.color(for: colorScheme))
            // iOS 15 has no scrollContentBackground: clear the table
            // background while editing so the sheet's own background
            // shows through (the app has no other Lists).
            .onAppear { UITableView.appearance().backgroundColor = .clear }
            .onDisappear { UITableView.appearance().backgroundColor = nil }
            VStack {
                Text("Hidden apps stay on the TV — they just don't show here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
    }

    private func editRow(item: TVAppItem, isHidden: Bool) -> some View {
        HStack(spacing: 12) {
            AppBrandTile(name: item.name)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            // Toggle (v1.0.65): ON = shown, OFF = hidden. The eye
            // read as a state, not an action — a shown app wore a
            // slashed eye, so it looked hidden. Toggling moves the
            // app between the sections, exactly like the eye did.
            Toggle("", isOn: Binding(
                get: { !isHidden },
                set: { shown in
                    let result = AppsCustomization.setShown(id: item.id, shown: shown, order: order, hidden: hidden)
                    order = result.order
                    hidden = result.hidden
                    savePrefs()
                }
            ))
            .toggleStyle(.switch)
            .tint(remoteAccent)
            .labelsHidden()
            .accessibilityLabel("Show \(item.name)")
        }
    }

    /// One app tile: the TV's own icon where it has one, over the
    /// bundled brand tile (which shows through while the icon
    /// loads, and stays if the icon fails to load).
    private func appTile(item: TVAppItem) -> some View {
        ZStack {
            AppBrandTile(name: item.name)
            if let url = item.iconURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func savePrefs() {
        guard let host = session.device.host else { return }
        AppsCustomization.save(host: host, order: order, hidden: hidden)
    }

    /// Load the app list (v1.0.64): the last good list shows
    /// immediately while a fresh load runs in the background, so
    /// the page is never empty on a slow refresh. The fresh load
    /// re-connects first if the session dropped (the v1.0.63 bug:
    /// load() fired once, parked on failure, and Retry re-ran the
    /// same fetch against the same dead connection) and retries
    /// automatically a few times with a short backoff before
    /// giving up — the user never has to tap Retry.
    private func load() async {
        guard !loadInFlight else { return }
        loadInFlight = true
        defer { loadInFlight = false }
        guard let host = session.device.host else {
            loadState = .failed("Couldn't load the apps from this TV.")
            return
        }
        let prefs = AppsCustomization.load(host: host)
        order = prefs.order
        hidden = prefs.hidden
        setupDone = AppsCustomization.setupDone(host: host)
        // Last good list first (v1.0.64): show it at once, then
        // refresh behind it. No cache yet → the spinner.
        if let cached = AppsCache.load(host: host), !cached.isEmpty {
            items = AppsCustomization.deduplicate(cached)
            loadState = .loaded
            isRefreshing = true
        } else {
            loadState = .loading
        }
        var ok = false
        for attempt in 1...3 {
            guard !Task.isCancelled else { return }
            if await fetchOnce() { ok = true; break }
            if attempt < 3 {
                // Backoff: 0.5s, then 1s.
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
            }
        }
        isRefreshing = false
        if ok {
            loadState = .loaded
            showingStaleNote = false
        } else if !items.isEmpty {
            // Still showing the last good list — say so quietly
            // instead of swapping it for an error screen.
            loadState = .loaded
            showingStaleNote = true
        } else {
            loadState = .failed("Couldn't load the apps from this TV.")
        }
    }

    /// One fetch attempt: re-connect first when the session
    /// dropped, then pull the brand's list. True when a fresh
    /// (deduplicated) list landed — and it becomes the new cache.
    private func fetchOnce() async -> Bool {
        if !session.isConnected && !session.isBusy {
            await session.connect()
        }
        await session.loadApps()
        let fresh = AppsCustomization.deduplicate(itemsFromSession())
        guard !fresh.isEmpty || isAndroidTV else { return false }
        items = fresh
        if let host = session.device.host {
            AppsCache.save(host: host, items: fresh)
        }
        return true
    }

    /// The session's brand list as sheet items. Android TV's
    /// curated set is never empty, so it never fails a load.
    private func itemsFromSession() -> [TVAppItem] {
        switch session.device.brand {
        case .roku:
            return session.rokuApps.map { TVAppItem(id: $0.id, name: $0.name, iconURL: $0.iconURL) }
        case .samsung:
            // No icon from the Tizen API — brand tiles.
            return session.samsungApps.map { TVAppItem(id: $0.id, name: $0.name) }
        case .lg:
            return session.lgApps.map { TVAppItem(id: $0.id, name: $0.name, iconURL: $0.iconURL) }
        case .androidTV:
            return session.androidTVApps.map { TVAppItem(id: $0.id, name: $0.name) }
        case .airPlay, .other:
            return []
        }
    }
}

/// The bundled brand tile: the brand's wordmark on the brand's
/// color, or the app's initial letter for anything unknown.
struct AppBrandTile: View {
    let name: String

    var body: some View {
        let style = AppBrandArt.tile(for: name)
        ZStack {
            style.background
            Text(style.label)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(style.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

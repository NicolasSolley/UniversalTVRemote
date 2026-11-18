import SwiftUI

// AppsSheet.swift — the Apps page (v1.0.63): a sheet opened from the
// slim "Apps" pill at the bottom of the remote screen. It shows the
// TV's installed apps as a grid of branded tiles — tap one and it
// launches on the TV immediately.
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
// Bulk select (v1.0.63): Select all / Deselect all plus Hide
// selected — select everything, tap the keepers to unselect them,
// hide the rest in one go.

/// One app in the Apps sheet: the TV's real installed app (Roku /
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
        ("crunchyroll", BrandTileStyle(background: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), foreground: .white, label: "Crunchyroll")),
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
    ]

    /// The brand tile for an app name, or nil when no catalog app
    /// matches (the caller falls back to the generic tile).
    static func match(name: String) -> BrandTileStyle? {
        let lower = name.lowercased()
        if let hit = catalog.first(where: { $0.key == lower }) { return hit.style }
        return catalog
            .filter { lower.hasPrefix($0.key) }
            .max(by: { $0.key.count < $1.key.count })?.style
    }

    /// Generic tile for an app with no brand match: its initial
    /// letter on a neutral tint — never a blank tile.
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
/// cannot list installed apps, so the Apps sheet offers these
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

    static func load(host: String) -> (order: [String], hidden: Set<String>) {
        let order = UserDefaults.standard.stringArray(forKey: orderKey(host: host)) ?? []
        let hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey(host: host)) ?? [])
        return (order, hidden)
    }

    static func save(host: String, order: [String], hidden: Set<String>) {
        UserDefaults.standard.set(order, forKey: orderKey(host: host))
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey(host: host))
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

    /// Hide a set of ids in one go (bulk hide, v1.0.63): the ids
    /// join `hidden` and leave `order` — the same state the
    /// per-app eye produces, just for many ids at once (Select
    /// all → unselect the keepers → Hide selected). Pure.
    static func hide(ids: Set<String>, order: [String], hidden: Set<String>) -> (order: [String], hidden: Set<String>) {
        (order.filter { !ids.contains($0) }, hidden.union(ids))
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
}

struct AppsSheet: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private enum LoadState { case loading, loaded, failed(String) }

    @State private var loadState: LoadState = .loading
    @State private var items: [TVAppItem] = []
    @State private var order: [String] = []
    @State private var hidden: Set<String> = []
    @State private var isEditing = false
    /// Bulk selection (v1.0.63): Edit-mode only — which shown
    /// apps are selected for Hide selected. Resets when leaving
    /// Edit mode (and on reload); never persisted.
    @State private var selectedIDs: Set<String> = []

    private var visibleItems: [TVAppItem] {
        let ids = AppsCustomization.visibleIDs(installedIDs: items.map(\.id), order: order, hidden: hidden)
        // First wins on a duplicate id (a TV list shouldn't have
        // one — but a duplicate must never crash the sheet).
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    private var hiddenItems: [TVAppItem] {
        items.filter { hidden.contains($0.id) }
    }

    private var isAndroidTV: Bool { session.device.brand == .androidTV }

    var body: some View {
        VStack(spacing: 0) {
            GlassHeaderPill(title: "Apps") { dismiss() }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            if case .loaded = loadState {
                HStack {
                    Spacer()
                    Button(isEditing ? "Done" : "Edit") {
                        // Leaving Edit mode clears the bulk
                        // selection — it is Edit-mode only.
                        if isEditing { selectedIDs.removeAll() }
                        isEditing.toggle()
                    }
                        .font(.subheadline.bold())
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
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
                    Button("Retry") { Task { await load() } }
                        .font(.subheadline.bold())
                }
                .padding(24)
                Spacer()
            case .loaded:
                if isEditing {
                    editList
                } else {
                    grid
                }
            }
        }
        .background(AppBackground.color(for: colorScheme).ignoresSafeArea())
        .task { await load() }
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
                    Text("Tap Edit to show them again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    ForEach(visibleItems) { item in
                        Button {
                            Task { await session.launchAppItem(item) }
                            dismiss()
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

    /// Edit mode: the full installed list, split into Shown (drag
    /// to reorder, eye to hide) and Hidden (eye to show again).
    /// A bulk bar on top offers Select all / Deselect all plus
    /// Hide selected: tap Select all, tap the apps to keep to
    /// unselect them, then Hide selected moves the rest to Hidden
    /// in one go. Changes save immediately; Done just leaves
    /// edit mode.
    private var editList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Button("Select all") { selectedIDs = Set(visibleItems.map(\.id)) }
                Button("Deselect all") { selectedIDs.removeAll() }
                Spacer()
                Button(selectedIDs.isEmpty ? "Hide selected" : "Hide selected (\(selectedIDs.count))") {
                    hideSelected()
                }
                .disabled(selectedIDs.isEmpty)
            }
            .font(.subheadline.bold())
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            List {
                Section("Shown") {
                    ForEach(visibleItems) { item in
                        Button {
                            // Tapping a shown row toggles its bulk
                            // selection; the eye button inside the
                            // row still hides that one app (the
                            // innermost button wins the tap).
                            if selectedIDs.contains(item.id) {
                                selectedIDs.remove(item.id)
                            } else {
                                selectedIDs.insert(item.id)
                            }
                        } label: {
                            editRow(item: item, isHidden: false)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(GlassCardBackground())
                    }
                    .onMove { from, to in
                        order = AppsCustomization.move(order: order, visibleIDs: visibleItems.map(\.id),
                                                       from: from, to: to)
                        savePrefs()
                    }
                }
                if !hiddenItems.isEmpty {
                    Section("Hidden") {
                        ForEach(hiddenItems) { item in
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
            ZStack(alignment: .topTrailing) {
                AppBrandTile(name: item.name)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                // Bulk selection (v1.0.63): a teal check badge on
                // the tile while it is selected for Hide selected.
                if selectedIDs.contains(item.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.teal)
                        .offset(x: 8, y: -8)
                }
            }
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button {
                if isHidden {
                    hidden.remove(item.id)
                    order.append(item.id)
                } else {
                    hidden.insert(item.id)
                    order.removeAll { $0 == item.id }
                }
                savePrefs()
            } label: {
                Image(systemName: isHidden ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Hide every selected app at once (bulk hide, v1.0.63):
    /// the same hide the eye does, for the whole selection —
    /// the apps move to Hidden and stay recoverable there.
    /// Nothing is deleted from the TV.
    private func hideSelected() {
        let result = AppsCustomization.hide(ids: selectedIDs, order: order, hidden: hidden)
        order = result.order
        hidden = result.hidden
        selectedIDs.removeAll()
        savePrefs()
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

    private func load() async {
        loadState = .loading
        guard session.isConnected else {
            loadState = .failed("Not connected to a TV.")
            return
        }
        await session.loadApps()
        switch session.device.brand {
        case .roku:
            items = session.rokuApps.map { TVAppItem(id: $0.id, name: $0.name, iconURL: $0.iconURL) }
        case .samsung:
            // No icon from the Tizen API — brand tiles.
            items = session.samsungApps.map { TVAppItem(id: $0.id, name: $0.name) }
        case .lg:
            items = session.lgApps.map { TVAppItem(id: $0.id, name: $0.name, iconURL: $0.iconURL) }
        case .androidTV:
            items = session.androidTVApps.map { TVAppItem(id: $0.id, name: $0.name) }
        case .airPlay, .other:
            items = []
        }
        if let host = session.device.host {
            let prefs = AppsCustomization.load(host: host)
            order = prefs.order
            hidden = prefs.hidden
            selectedIDs.removeAll()
        }
        // A Roku / Samsung / LG with no apps at all is a failed
        // load, not an empty TV; Android TV always has its curated
        // list, so it never lands here.
        if items.isEmpty && !isAndroidTV {
            loadState = .failed("Couldn't load the apps from this TV.")
        } else {
            loadState = .loaded
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

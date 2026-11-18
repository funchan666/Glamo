import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation

struct DriveBrowser: View {
    private enum ImportSource { case files, photos, newFolder }
    enum Surface {
        case files(search: () -> Void, profile: () -> Void)
        case search(close: () -> Void)
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var api: APIClient
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .subheadline) private var libraryActionWidth: CGFloat = 152
    @AppStorage("drive.useGrid") private var useGrid = false
    @AppStorage("drive.sortByName") private var sortByName = false
    @AppStorage("drive.recentSearches") private var recentSearchData = Data()
    @SceneStorage("home.linkDraft") private var linkDraft = ""
    @State private var currentFolderID: UUID?
    @State private var query = ""
    @State private var searchRequest: VideoSearchRequest?
    @State private var searchError: String?
    @State private var needsSearchConnection = false
    @State private var showingSearchGuide = false
    @State private var showingAllVideos = false
    @State private var choosingImportSource = false
    @State private var importSource: ImportSource?
    @State private var showImporter = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editingPhoto: PracticeRecording?
    @State private var showNewFolder = false
    @State private var showingPlus = false
    @State private var options: DriveItem?
    @FocusState private var searchFocused: Bool
    let surface: Surface
    @Binding var isSearching: Bool
    let play: (PracticeRecording, [PracticeRecording]) -> Void
    let pausePlayback: () -> Void
    let showActivity: () -> Void
    var folderVisibility: (Bool) -> Void = { _ in }

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var folder: VideoFolder? { library.folders.first { $0.id == currentFolderID } }
    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: recentSearchData)) ?? []
    }

    private var visibleFolders: [VideoFolder] {
        library.folders.filter { entry in
            searchTerm.isEmpty ? entry.parentID == currentFolderID : entry.name.localizedStandardContains(searchTerm)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleFiles: [PracticeRecording] {
        library.movies.filter { movie in
            if !searchTerm.isEmpty { return movie.displayName.localizedStandardContains(searchTerm) }
            return movie.folderID == currentFolderID
        }.sorted { a, b in
            if sortByName {
                let order = a.displayName.localizedStandardCompare(b.displayName)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.date > b.date
        }
    }

    private var remoteFiles: [LessonClip] {
        library.favorites.filter { clip in
            if !searchTerm.isEmpty { return clip.title.localizedStandardContains(searchTerm) }
            return library.savedVideo(clip.id)?.folderID == currentFolderID
        }.sorted { a, b in
            if sortByName { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            return (library.savedVideo(a.id)?.addedAt ?? .distantPast) > (library.savedVideo(b.id)?.addedAt ?? .distantPast)
        }
    }
    private var packageCollections: [DriveCollection] {
        guard currentFolderID == nil || !searchTerm.isEmpty else { return [] }
        return (library.snapshot.packageCollections ?? []).filter {
            searchTerm.isEmpty || $0.title.localizedStandardContains(searchTerm)
        }
    }

    var body: some View {
        GeometryReader { container in
            let pane = drivePaneMargins(in: container, includesHorizontalFold: true)
            let paneWidth = max(0, container.size.width - pane.leading - pane.trailing)
            let paneHeight = max(0, container.size.height - pane.top - pane.bottom)
            let canUseGrid = paneWidth >= 300 && !typeSize.isAccessibilitySize && !driveHasReservedRegion(container)
            let folders = visibleFolders
            let movies = visibleFiles

            Group {
                switch surface {
                case .files(let search, let profile):
                    fileWorkspace(folders: folders, movies: movies, canUseGrid: canUseGrid,
                                  width: paneWidth, height: paneHeight, search: search, profile: profile)
                case .search(let close):
                    searchWorkspace(folders: folders, movies: movies, width: paneWidth,
                                    canUseGrid: canUseGrid, close: close)
                }
            }
            .padding(pane)
        }
        .driveScreenBackground()
        .onChange(of: searchFocused) { _, focused in isSearching = focused }
        .onChange(of: query) { _, value in
            if case .search = surface { linkDraft = value }
            searchError = nil
        }
        .onChange(of: api.session == nil) { _, missing in
            if !missing { needsSearchConnection = false; searchError = nil }
        }
        .onChange(of: folder?.id, initial: true) { _, id in
            if id == nil { currentFolderID = nil }
            folderVisibility(id != nil)
        }
        .onDisappear { isSearching = false }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie], allowsMultipleSelection: true) { selection in
            switch selection {
            case .success(let urls):
                let destination = folder?.id
                Task { await library.importFiles(urls, into: destination) }
            case .failure(let failure):
                showImportError(failure)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto,
                      matching: .videos, photoLibrary: .shared())
        .onChange(of: selectedPhoto) { _, selected in
            guard let selected else { return }
            selectedPhoto = nil
            importPhoto(selected)
        }
        .sheet(isPresented: $choosingImportSource, onDismiss: presentImportPicker) { importSources }
        .sheet(isPresented: $showNewFolder) {
            DriveNameSheet(title: "New folder", startingName: "") { name in
                try library.createFolder(named: name, parentID: currentFolderID)
            }
        }
        .sheet(item: $options) { item in
            DriveItemSheet(item: item, pausePlayback: pausePlayback)
        }
        .sheet(item: $editingPhoto) { EditorSheet(initialMovie: $0) }
        .fullScreenCover(isPresented: $showingPlus) { MembershipView() }
        .fullScreenCover(item: $searchRequest) { request in
            VideoSearchResultsView(search: request.query) { query, clip in
                library.record(link: query, title: clip.title)
            }
        }
        .sheet(isPresented: $showingSearchGuide) { VideoSearchGuideSheet() }
    }

    private func searchWorkspace(folders: [VideoFolder], movies: [PracticeRecording],
                                 width: CGFloat, canUseGrid: Bool, close: @escaping () -> Void) -> some View {
        let hasItems = !folders.isEmpty || !movies.isEmpty || !remoteFiles.isEmpty || !packageCollections.isEmpty
        let showsHistory = searchTerm.isEmpty && !recentSearches.isEmpty && currentFolderID == nil
        let showsLibrary = !searchFocused && searchTerm.isEmpty
        let compact = verticalSizeClass == .compact

        return VStack(spacing: 0) {
            searchBar(compact: width < 360 || typeSize >= .xxLarge, close: close)
                .padding(.horizontal, DriveStyle.pageInset)
                .padding(.top, compact ? 4 : 16).padding(.bottom, 8)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
                .background(DriveStyle.background, ignoresSafeAreaEdges: [.horizontal, .top])

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let searchError { ErrorNote(message: searchError) }
                    if needsSearchConnection, api.session == nil { ConnectionPanel() }
                    if showsLibrary, let folder { filesFolderHeader(folder) }
                    importStatus
                    if !searchTerm.isEmpty {
                        if hasItems { itemList(folders: folders, movies: movies) }
                        else { noSearchResults }
                    } else if showsLibrary {
                        VStack(alignment: .leading, spacing: 12) {
                            if folder == nil { searchLibraryHeading }
                            if hasItems {
                                VStack(alignment: .leading, spacing: 8) {
                                    fileListToolbar(canUseGrid: canUseGrid, includesLibraryActions: true)
                                    if !folders.isEmpty { folderShelf(folders, tile: useGrid && canUseGrid) }
                                    if !movies.isEmpty { videoFiles(movies, canUseGrid: canUseGrid) }
                                    if !remoteFiles.isEmpty { DriveRemoteVideoRows(clips: remoteFiles) }
                                    if !packageCollections.isEmpty { DriveCollectionRows(collections: packageCollections) }
                                }
                            } else if folder != nil {
                                emptyOpenedFolder
                            } else {
                                searchEmptyLibrary(width: width)
                            }
                        }
                        .padding(.top, folder == nil ? 8 : 0)
                    }
                    if showsHistory { recentSearchHistory }
                }
                .padding(.horizontal, DriveStyle.pageInset)
                .padding(.top, compact ? 4 : 12).padding(.bottom, 24)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { query = linkDraft }
        .dismissKeyboardOnOutsideTap($searchFocused, scope: "drive-search-input")
        .accessibilityAction(.escape, close)
    }

    private var searchLibraryHeading: some View {
        HStack(spacing: 12) {
            LocalizedText("On this device")
                .driveFont(20, relativeTo: .title3, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            plusButton.fixedSize()
        }
    }

    private func searchEmptyLibrary(width: CGFloat) -> some View {
        let contentWidth = max(0, min(width, 680) - DriveStyle.pageInset * 2)
        let artworkWidth = min(248, contentWidth * 0.8)
        let stackedActions = contentWidth < libraryActionWidth * 2 + 12 || typeSize >= .xxLarge
        let actionLayout = stackedActions ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))

        return VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image("DriveShelf").resizable().interpolation(.high).scaledToFill()
                    // Crop the asset's transparent margins, keeping the shelf at its original proportions.
                    .frame(width: artworkWidth, height: artworkWidth * 0.46).clipped()
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityHidden(true).allowsHitTesting(false)

                VStack(spacing: 6) {
                    LocalizedText("No videos here yet")
                        .driveFont(20, relativeTo: .title3, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    LocalizedText("Import videos from Files or Photos.")
                        .driveFont(15, relativeTo: .subheadline)
                        .foregroundStyle(GlamoStyle.secondary)
                        .frame(maxWidth: 300)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            }

            actionLayout {
                searchImportButton
                searchLibraryAction("New folder", symbol: .driveFolder, prominent: false) {
                    showNewFolder = true
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var searchImportButton: some View {
        searchLibraryAction("Import videos", symbol: .driveAdd, prominent: true, action: openImportSources)
            .disabled(library.importingVideo || showImporter || showPhotoPicker)
            .accessibilityIdentifier("drive.import")
    }

    private func searchLibraryAction(_ title: String, symbol: GlamoGlyph, prominent: Bool,
                                     action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let label = HStack(spacing: 8) {
            Glyph(symbol: symbol, size: 16, tint: prominent ? .white : DriveStyle.link)
            LocalizedText(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .driveFont(15, relativeTo: .subheadline, weight: .semibold)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: .infinity)
        .foregroundStyle(prominent ? Color.white : DriveStyle.ink)
        .contentShape(shape)

        return Button(action: action) {
            if prominent {
                label.background(DriveStyle.link, in: shape)
            } else {
                label.glamoGlass(in: shape, tint: .white, interactive: true, mediaBackdrop: true)
            }
        }
        .buttonStyle(PressStyle())
    }

    private func fileWorkspace(folders: [VideoFolder], movies: [PracticeRecording], canUseGrid: Bool,
                               width: CGFloat, height: CGFloat, search: @escaping () -> Void,
                               profile: @escaping () -> Void) -> some View {
        let hasItems = !folders.isEmpty || !movies.isEmpty || !remoteFiles.isEmpty || !packageCollections.isEmpty
        return VStack(spacing: 0) {
            Group {
                if let folder {
                    filesFolderHeader(folder)
                } else {
                    DriveWorkspaceHeader(title: "All Files") {
                        IconButton(symbol: .search, label: "Search files and folders", tint: DriveStyle.ink, action: search)
                        addFilesButton
                        DriveProfileButton(action: profile)
                    }
                }
            }
            .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 8)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    importStatus
                    if hasItems {
                        fileListToolbar(canUseGrid: canUseGrid).padding(.top, 4)
                        if useGrid && canUseGrid {
                            if !folders.isEmpty { folderShelf(folders, tile: true) }
                            if !movies.isEmpty { videoFiles(movies, canUseGrid: canUseGrid) }
                            if !remoteFiles.isEmpty { DriveRemoteVideoRows(clips: remoteFiles) }
                            if !packageCollections.isEmpty { DriveCollectionRows(collections: packageCollections) }
                        } else {
                            itemList(folders: folders, movies: movies)
                        }
                    } else if folder != nil {
                        emptyOpenedFolder
                    } else {
                        DriveWorkspaceEmpty(artwork: "DriveShelf", artworkWidth: min(width * 0.64, height * 0.48, 176),
                                            title: "No files yet", message: "Add your first file to keep everything in one place.") {
                            Button(action: openImportSources) {
                                LocalizedText("Add files")
                            }.buttonStyle(DrivePrimaryButtonStyle(fillsWidth: false, radius: 8))
                                .disabled(library.importingVideo || showImporter || showPhotoPicker)
                                .accessibilityIdentifier("drive.import")
                        }
                        .frame(minHeight: max(0, height - 82))
                    }
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.bottom, 24)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                if api.session != nil {
                    await commerce.refresh()
                    if let release = commerce.release { await library.refreshPackageCollections(release.lcList?.us ?? [], api: api) }
                }
            }
        }
    }

    private func filesFolderHeader(_ folder: VideoFolder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                IconButton(symbol: .back, label: "Parent folder", tint: DriveStyle.ink, glass: true, glyphSize: 13) {
                    openParent(of: folder)
                }
                Text(verbatim: folder.name)
                    .driveFont(20, relativeTo: .headline, weight: .medium).lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                IconButton(symbol: .driveMore, label: "Folder options", tint: DriveStyle.ink, glass: true, glyphSize: 15) {
                    options = .folder(folder)
                }
            }
            if library.folderPath(to: folder.id).count > 1 {
                folderBreadcrumb(folder)
            }
        }
    }

    private func itemList(folders: [VideoFolder], movies: [PracticeRecording]) -> some View {
        VStack(spacing: 10) {
            DriveGroupedRows(items: folders.map(DriveItem.folder) + movies.map(DriveItem.file)) { item in
                switch item {
                case .folder(let folder): folderCell(folder, tile: false)
                case .file(let movie): fileCell(movie, queue: movies, tile: false)
                }
            }
            if !remoteFiles.isEmpty { DriveRemoteVideoRows(clips: remoteFiles) }
            if !packageCollections.isEmpty { DriveCollectionRows(collections: packageCollections) }
        }
    }

    private func fileListToolbar(canUseGrid: Bool, includesLibraryActions: Bool = false) -> some View {
        let controls = HStack(spacing: 4) {
            if folder != nil || includesLibraryActions { addFilesButton }
            if includesLibraryActions { newFolderButton }
            if canUseGrid {
                IconButton(symbol: useGrid ? .driveList : .driveGrid,
                           label: useGrid ? "List view" : "Grid view", tint: DriveStyle.secondary,
                           glyphSize: 17) { useGrid.toggle() }
            }
        }

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                compactSortButton.fixedSize()
                Spacer(minLength: 0)
                controls.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                compactSortButton
                controls
            }
        }
    }

    private var compactSortButton: some View {
        let order = sortByName ? "Name A–Z" : "Newest first"
        return Button { sortByName.toggle() } label: {
            HStack(spacing: 6) {
                LocalizedText(order)
                    .driveFont(20, relativeTo: .subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Glyph(symbol: .back, size: 10, tint: DriveStyle.secondary)
                    .rotationEffect(.degrees(layoutDirection == .leftToRight ? -90 : 90))
            }
            .foregroundStyle(DriveStyle.secondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Sort by")
        .accessibilityValue(Text(LocalizedStringKey(order)))
        .accessibilityHint("Change file sort order")
    }

    @ViewBuilder
    private var importStatus: some View {
        if let batch = library.fileImport, library.importingVideo || !batch.failures.isEmpty {
            Button {
                searchFocused = false
                showActivity()
            } label: {
                HStack(spacing: 8) {
                    Glyph(symbol: .driveActivity, size: 16, tint: GlamoStyle.accent)
                    LocalizedText(library.importingVideo ? "Importing…" : "View import results")
                        .font(.glam(.subheadline, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Glyph(symbol: .back, size: 12, tint: GlamoStyle.accent)
                        .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
                }.padding(.horizontal, 12).frame(minHeight: 44)
                    .glamoCard(radius: 12, fill: GlamoStyle.paper).contentShape(Rectangle())
            }.buttonStyle(PressStyle())
        }
    }

    private var plusButton: some View {
        PlusShortcut(isMember: commerce.premium) {
            searchFocused = false
            showingPlus = true
        }
        .disabled(library.importingVideo)
        .accessibilityIdentifier("home.plus")
    }

    private func openParent(of folder: VideoFolder) {
        currentFolderID = folder.parentID
        query = ""
        searchFocused = false
    }

    private func folderBreadcrumb(_ folder: VideoFolder) -> some View {
        let path = library.folderPath(to: folder.id)
        return ScrollView(.horizontal) {
            HStack(spacing: 7) {
                LocalizedText("Files")
                ForEach(path) { component in
                    Glyph(symbol: .back, size: 9, tint: GlamoStyle.secondary)
                        .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
                    Text(verbatim: component.name)
                        .foregroundStyle(component.id == folder.id ? GlamoStyle.accent : GlamoStyle.secondary)
                }
            }
            .font(.glam(.footnote, weight: .medium)).foregroundStyle(GlamoStyle.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 12), tint: GlamoStyle.paper)
    }

    private func openImportSources() {
        searchFocused = false
        choosingImportSource = true
    }

    private var addFilesButton: some View {
        IconButton(symbol: .driveAdd, label: "Add files", tint: DriveStyle.ink, action: openImportSources)
            .disabled(library.importingVideo || showImporter || showPhotoPicker)
            .accessibilityIdentifier("drive.import")
    }

    private var importButton: some View {
        Button(action: openImportSources) {
            HStack(spacing: 7) {
                Glyph(symbol: .driveAdd, size: 15, tint: GlamoStyle.onAccent)
                LocalizedText(library.importingVideo ? "Importing…" : "Import videos")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(GlamoActionStyle(fillsWidth: false))
        .disabled(library.importingVideo || showImporter || showPhotoPicker)
        .accessibilityIdentifier("drive.import")
    }

    private var importSources: some View {
        GeometryReader { container in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SheetHeading(title: "Import videos", inset: false) { choosingImportSource = false }
                    importSourceButton(.files, title: "Import from Files", detail: "Select one or more videos.",
                                       glyph: .driveFolder, tint: GlamoStyle.paperMuted)
                        .accessibilityIdentifier("video.importFiles")
                    importSourceButton(.photos, title: "Import from Photos", detail: "Pick a video to open in the editor.",
                                       glyph: .feed, tint: GlamoStyle.surface)
                        .accessibilityIdentifier("video.importPhotos")
                    if case .files = surface {
                        Button { chooseImportSource(.newFolder) } label: {
                            LocalizedText("New folder")
                        }
                        .buttonStyle(CompactActionStyle())
                    }
                }
                .pageHorizontalMargins().padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(drivePaneMargins(in: container))
        }.glamoScreenBackground().presentationDetents([.medium, .large])
    }

    private func importSourceButton(_ source: ImportSource, title: String, detail: String,
                                    glyph: GlamoGlyph, tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        return Button { chooseImportSource(source) } label: {
            HStack(spacing: 12) {
                Glyph(symbol: glyph, size: 22, tint: GlamoStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText(title)
                        .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                    LocalizedText(detail)
                        .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                }
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Glyph(symbol: .back, size: 12, tint: GlamoStyle.accent)
                    .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
            }
            .padding(12)
            .frame(minHeight: 68)
            .glamoGlass(in: shape, tint: tint, interactive: true, mediaBackdrop: true)
            .contentShape(shape)
        }
        .buttonStyle(PressStyle())
    }

    private func chooseImportSource(_ source: ImportSource) {
        importSource = source
        choosingImportSource = false
    }

    private func presentImportPicker() {
        let source = importSource
        importSource = nil
        switch source {
        case .files: showImporter = true
        case .photos: showPhotoPicker = true
        case .newFolder: showNewFolder = true
        case nil: break
        }
    }

    private func importPhoto(_ selection: PhotosPickerItem) {
        guard library.beginVideoImport() else { return }
        let destination = folder?.id
        Task {
            defer { library.finishVideoImport() }
            do {
                let file = try await library.importPhoto(selection, folderID: destination)
                pausePlayback()
                editingPhoto = file
            } catch { showImportError(error) }
        }
    }

    private func showImportError(_ failure: Error) {
        let error = failure as NSError
        guard !(failure is CancellationError),
              !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError),
              !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        library.error = failure.localizedDescription
    }

    private func searchBar(compact: Bool, close: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                searchField(compact: compact)
                if !compact, !searchTerm.isEmpty {
                    IconButton(symbol: .search, label: "Search videos", tint: .white, glyphSize: 17,
                               action: submitSearch)
                        .background(DriveStyle.link, in: Circle())
                        .disabled(!canSubmitSearch)
                        .accessibilityIdentifier("drive.search.submit")
                }
                Button(action: close) {
                    Glyph(symbol: .close, size: 14, tint: DriveStyle.ink)
                        .frame(width: 46, height: 46)
                        .glamoGlass(in: Circle(), tint: .white, interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Close")
                .accessibilityIdentifier("drive.search.close")
            }
            if compact, !searchTerm.isEmpty {
                ActionButton(title: "Search videos", action: submitSearch)
                    .disabled(!canSubmitSearch)
                    .accessibilityIdentifier("drive.search.submit")
            }
            if searchTerm.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        searchPasteButton.fixedSize()
                        Spacer(minLength: 8)
                        searchHelpButton.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 0) { searchPasteButton; searchHelpButton }
                }
            }
        }
        .keyboardInputRegion("drive-search-input")
    }

    private func searchField(compact: Bool) -> some View {
        let prompt = compact ? "Search" : "Files, video URLs or codes"
        let shape = Capsule()
        return HStack(spacing: 9) {
            Glyph(symbol: .search, size: 17, tint: DriveStyle.ink)
                .padding(.leading, 13)
            TextField("Search files, video URLs or codes", text: $query,
                      prompt: Text(LocalizedStringKey(prompt)).foregroundColor(DriveStyle.secondary))
                .focused($searchFocused)
                .driveFont(15, relativeTo: .subheadline).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit(submitSearch)
                .frame(minHeight: 44)
                .accessibilityLabel("Search files, video URLs or codes")
            if !query.isEmpty {
                IconButton(symbol: .close, label: "Clear search", tint: DriveStyle.secondary, glyphSize: 12) {
                    query = ""
                    searchFocused = true
                }
            }
        }
        .padding(.trailing, 6)
        .frame(minHeight: 46)
        .glamoGlass(in: shape, tint: .white)
        .overlay {
            shape.strokeBorder(searchFocused ? DriveStyle.accent : .white.opacity(0.65))
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("drive.search")
    }

    private var searchPasteButton: some View {
        Button(action: pasteSearch) {
            LocalizedText("Paste").font(.glam(.footnote, weight: .semibold))
                .foregroundStyle(DriveStyle.link).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).disabled(library.importingVideo)
        .accessibilityIdentifier("home.pasteLink")
    }

    private var searchHelpButton: some View {
        Button { showingSearchGuide = true } label: {
            LocalizedText("How to search").font(.glam(.footnote, weight: .medium))
                .foregroundStyle(DriveStyle.link).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("home.linkHelp")
    }

    private var canSubmitSearch: Bool { !searchTerm.isEmpty && searchRequest == nil && !library.importingVideo }

    private func pasteSearch() {
        guard let text = UIPasteboard.general.string, text.nilIfBlank != nil else {
            searchError = "Copy a video URL, then try pasting again."
            return
        }
        query = text
        searchFocused = true
    }

    private func submitSearch() {
        guard let text = query.nilIfBlank, canSubmitSearch else { return }
        searchFocused = false
        rememberSearch()
        guard api.session != nil else {
            needsSearchConnection = true
            searchError = "Connect to Vifol, then search again."
            return
        }
        searchError = nil
        // The existing results flow owns link/code resolution and pagination.
        pausePlayback()
        searchRequest = VideoSearchRequest(query: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var recentSearchHistory: some View {
        let searches = recentSearches
        let heading = LocalizedText("Recent searches").driveFont(20, relativeTo: .subheadline)
            .foregroundStyle(DriveStyle.secondary).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
        let clear = Button {
            recentSearchData = Data()
        } label: {
            LocalizedText("Clear")
                .driveFont(18, relativeTo: .subheadline)
                .foregroundStyle(GlamoStyle.danger)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Clear recent searches")

        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    heading
                    Spacer(minLength: 0)
                    clear
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    clear
                }
            }
            VStack(spacing: 0) {
                ForEach(searches, id: \.self) { term in
                    if term != searches.first { Divider().overlay(DriveStyle.separator).padding(.leading, 44) }
                    HStack(spacing: 4) {
                        Button {
                            query = term
                            rememberSearch()
                            searchFocused = false
                        } label: {
                        HStack(spacing: 8) {
                            Glyph(symbol: .search, size: 15, tint: DriveStyle.secondary)
                                .frame(width: 32, height: 32)
                            Text(verbatim: term).driveFont(15, relativeTo: .subheadline)
                                .foregroundStyle(DriveStyle.ink)
                                .lineLimit(2).truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 56).contentShape(Rectangle())
                        }.buttonStyle(PressStyle())
                        IconButton(symbol: .close, label: "Remove search", tint: DriveStyle.secondary) {
                            if let encoded = try? JSONEncoder().encode(recentSearches.filter { $0 != term }) { recentSearchData = encoded }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
        }
    }

    private func rememberSearch() {
        let term = searchTerm
        guard !term.isEmpty else { return }
        let others = recentSearches.filter { $0.localizedCaseInsensitiveCompare(term) != .orderedSame }
        let history = Array(([term] + others).prefix(20))
        if let encoded = try? JSONEncoder().encode(history) {
            recentSearchData = encoded
        }
    }

    private func filesHeading(_ count: Int) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                                                 : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            LocalizedText("Video files").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            LocalizedText(count == 1 ? "%@ item" : "%@ items", count.formatted(.number.locale(locale)))
                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
        }
    }

    private func folderShelf(_ entries: [VideoFolder], tile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText("Folders").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            if tile, currentFolderID == nil, searchTerm.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(entries) { folderCell($0, tile: true).frame(width: 152) }
                    }.padding(.vertical, 2)
                }.scrollIndicators(.hidden)
            } else if tile {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 220), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    ForEach(entries) { folderCell($0, tile: true) }
                }
            } else {
                DriveGroupedRows(items: entries) { folderCell($0, tile: false) }
            }
        }
    }

    private func folderCell(_ entry: VideoFolder, tile: Bool) -> some View {
        let layout = tile ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                          : AnyLayout(HStackLayout(spacing: 10))
        let open = Button {
            rememberSearch()
            currentFolderID = entry.id
            query = ""
            searchFocused = false
        } label: {
            layout {
                Glyph(symbol: tile ? .driveFolder : .folder, size: tile ? 23 : 30,
                      tint: tile ? GlamoStyle.accent : DriveStyle.folder)
                    .frame(width: 34, height: 34)
                    .background(tile ? GlamoStyle.paperMuted : .clear, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name)
                        .driveFont(15, relativeTo: .subheadline, weight: .medium)
                        .foregroundStyle(DriveStyle.ink).multilineTextAlignment(.leading)
                        .lineLimit(typeSize.isAccessibilitySize || tile ? 2 : 1, reservesSpace: tile)
                        .truncationMode(.middle)
                    if !tile {
                        LocalizedText("Folder").driveFont(12, relativeTo: .caption)
                            .foregroundStyle(DriveStyle.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, tile ? 10 : 6).padding(.trailing, tile ? 10 : 0)
            .padding(.vertical, tile ? 10 : 6)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
        let more = Group {
            if tile {
                IconButton(symbol: .driveMore, label: "Folder options", tint: DriveStyle.secondary,
                           glass: true, glyphSize: 14) { options = .folder(entry) }
            } else {
                DriveListOptionsButton(item: .folder(entry), pausePlayback: pausePlayback) {
                    options = .folder(entry)
                }
            }
        }
        .accessibilityValue(Text(verbatim: entry.name))
        return Group {
            if tile {
                ZStack(alignment: .topTrailing) {
                    open
                    more.padding(4)
                }
                .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.paper)
            } else {
                HStack(spacing: 2) {
                    open
                    more.padding(.trailing, 4)
                }
            }
        }
    }

    private func videoFiles(_ movies: [PracticeRecording], canUseGrid: Bool) -> some View {
        let isOverview = if case .search = surface { currentFolderID == nil && searchTerm.isEmpty } else { false }
        let previewCount = 2
        let canExpand = isOverview && movies.count > previewCount
        let previewing = isOverview && !showingAllVideos
        let entries = previewing ? Array(movies.prefix(previewCount)) : movies
        return VStack(alignment: .leading, spacing: 6) {
            if canExpand {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        filesHeading(movies.count)
                        Spacer(minLength: 0)
                        videoExpansionButton
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        filesHeading(movies.count)
                        videoExpansionButton
                    }
                }
            } else {
                filesHeading(movies.count)
            }
            if !entries.isEmpty {
                if useGrid, canUseGrid {
                    let columns = previewing
                        ? Array(repeating: GridItem(.flexible(maximum: 280), spacing: 12, alignment: .top), count: entries.count)
                        : [GridItem(.adaptive(minimum: 140, maximum: 264), spacing: 12, alignment: .top)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(entries) { fileCell($0, queue: movies, tile: true, compactTile: isOverview) }
                    }
                } else {
                    DriveGroupedRows(items: entries) { movie in
                        fileCell(movie, queue: movies, tile: false)
                    }
                }
            }
        }
    }

    private var videoExpansionButton: some View {
        Button {
            showingAllVideos.toggle()
        } label: {
            HStack(spacing: 6) {
                LocalizedText(showingAllVideos ? "Show fewer videos" : "Show all videos")
                    .font(.glam(.footnote, weight: .semibold))
                Glyph(symbol: .back, size: 10, tint: GlamoStyle.accent)
                    .rotationEffect(.degrees(showingAllVideos ? 90 : -90))
            }.foregroundStyle(GlamoStyle.accent)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    private var emptyOpenedFolder: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                LocalizedText("This folder is empty")
                    .font(.glam(.title2, weight: .semibold)).accessibilityAddTraits(.isHeader)
                LocalizedText("Import videos from Files or Photos.")
                    .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    importButton
                    newFolderButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    importButton
                    newFolderButton
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    private var newFolderButton: some View {
        Button { showNewFolder = true } label: {
            LocalizedText("New folder")
        }.buttonStyle(CompactActionStyle())
    }

    private var noSearchResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalizedText("No matching files")
                .driveFont(20, relativeTo: .title3, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            LocalizedText("Try another file name, or search a video URL or code.")
                .driveFont(15, relativeTo: .subheadline)
                .foregroundStyle(DriveStyle.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
    }

    private func fileCell(_ movie: PracticeRecording, queue: [PracticeRecording], tile: Bool, compactTile: Bool = false) -> some View {
        DriveFileCell(movie: movie, tile: tile, compactTile: compactTile, play: {
            rememberSearch()
            searchFocused = false
            play(movie, queue)
        }, options: { options = .file(movie) }, pauseForMenu: pausePlayback)
    }
}

private struct DriveGroupedRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 0) {
                    if item.id != items.first?.id {
                        Divider().overlay(DriveStyle.separator).padding(.leading, 48).padding(.trailing, 8)
                    }
                    row(item)
                }
            }
        }
        .padding(.horizontal, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
    }
}

struct DriveFileCell: View {
    let movie: PracticeRecording
    var tile = false
    var compactTile = false
    var detail: String? = nil
    let play: () -> Void
    var options: (() -> Void)? = nil
    var pauseForMenu: (() -> Void)? = nil

    var body: some View {
        if let options {
            DriveBrowserFileCard(movie: movie, tile: tile, compactTile: compactTile, detail: detail,
                                 play: play, options: options, pauseForMenu: pauseForMenu)
        } else if tile {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 0) {
                    DriveThumbnail(movie: movie)
                        .aspectRatio(compactTile ? 2 : 1.58, contentMode: .fit)
                        .overlay(alignment: .bottomTrailing) { playMark.padding(8) }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    fileName
                        .frame(minHeight: 44, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
        } else {
            HStack(spacing: 6) {
                Button(action: play) {
                    HStack(spacing: 11) {
                        DriveThumbnail(movie: movie).frame(width: 70, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        fileName
                        Glyph(symbol: .play, size: 14, tint: GlamoStyle.accent)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }.buttonStyle(PressStyle())
            }
        }
    }

    private var fileName: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: movie.displayName)
                .font(.glam(.subheadline, weight: .semibold))
                .multilineTextAlignment(.leading).lineLimit(2)
            DriveFileMetadata(movie: movie, detail: detail)
        }
        .foregroundStyle(GlamoStyle.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playMark: some View {
        Glyph(symbol: .play, size: 14, tint: .white)
            .frame(width: 34, height: 34)
            .background(.black.opacity(0.66), in: Circle())
            .allowsHitTesting(false)
    }
}

private struct DriveBrowserFileCard: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @State private var measuredDuration: Double?
    let movie: PracticeRecording
    let tile: Bool
    let compactTile: Bool
    let detail: String?
    let play: () -> Void
    let options: () -> Void
    let pauseForMenu: (() -> Void)?

    var body: some View {
        Group {
            if tile { gridCard }
            else { listCard }
        }
        .task(id: movie.id) {
            measuredDuration = nil
            guard movie.duration == nil, movie.viewing?.duration == nil else { return }
            let asset = AVURLAsset(url: library.url(for: movie))
            guard let seconds = try? await asset.load(.duration).seconds,
                  !Task.isCancelled, seconds.isFinite, seconds > 0 else { return }
            measuredDuration = seconds
        }
    }

    private var time: String? {
        guard let seconds = movie.duration ?? movie.viewing?.duration ?? measuredDuration,
              seconds.isFinite, seconds > 0 else { return nil }
        return durationLabel(seconds)
    }

    private var gridCard: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        return ZStack(alignment: .bottomTrailing) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 0) {
                    GlamoStyle.raised
                        .aspectRatio(compactTile ? 16.0 / 9.0 : 8.0 / 5.0, contentMode: .fit)
                        .frame(minHeight: 80)
                        .overlay { DriveThumbnail(movie: movie) }
                        .overlay(alignment: .bottomLeading) {
                            previewLabel.padding(7)
                        }
                    title.padding(.horizontal, 10).padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadata.padding(.leading, 10).padding(.trailing, 48)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
            moreButton.padding(.trailing, 3)
        }
        .clipShape(shape)
        .glamoGlass(in: shape, tint: GlamoStyle.surface, mediaBackdrop: true)
    }

    private var listCard: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                  : AnyLayout(HStackLayout(spacing: 12))
        let size = movie.byteCount.map { $0.formatted(.byteCount(style: .file).locale(locale)) }
        return HStack(spacing: 2) {
            Button(action: play) {
                HStack(spacing: 6) {
                    layout {
                        DriveThumbnail(movie: movie)
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: movie.displayName)
                                .driveFont(15, relativeTo: .subheadline, weight: .medium)
                                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.middle)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(DriveStyle.ink)
                            let parts = [detail ?? movie.fileExtension.uppercased(), time].compactMap { $0 }
                            Text(verbatim: parts.joined(separator: " · "))
                                .driveFont(12, relativeTo: .caption).foregroundStyle(DriveStyle.secondary)
                                .lineLimit(2)
                            if typeSize.isAccessibilitySize, let size {
                                Text(verbatim: size).font(.caption).foregroundStyle(DriveStyle.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !typeSize.isAccessibilitySize, let size {
                        Text(verbatim: size)
                            .driveFont(14, relativeTo: .footnote).foregroundStyle(DriveStyle.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                .padding(.leading, 6).padding(.vertical, 5)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
            if let pauseForMenu {
                DriveListOptionsButton(item: .file(movie), pausePlayback: pauseForMenu, fallback: options)
            } else {
                moreButton
            }
        }
    }

    private var title: some View {
        Text(verbatim: movie.displayName)
            .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
            .multilineTextAlignment(.leading).lineLimit(2, reservesSpace: tile)
            .truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
    }

    private var metadata: some View {
        DriveFileMetadata(movie: movie, detail: detail, showsDuration: false)
    }

    private var previewLabel: some View {
        HStack(spacing: 5) {
            Glyph(symbol: .play, size: 12, tint: GlamoStyle.onAccent)
            if let time {
                Text(verbatim: time)
                    .font(.glam(.caption2, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(GlamoStyle.onAccent)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(GlamoStyle.ink.opacity(0.88), in: Capsule())
        .allowsHitTesting(false)
    }

    private var moreButton: some View {
        IconButton(symbol: .driveMore, label: "File options", tint: GlamoStyle.accent, action: options)
            .accessibilityValue(Text(verbatim: movie.displayName))
    }
}

private struct DriveFileMetadata: View {
    let movie: PracticeRecording
    let detail: String?
    var showsDuration = true
    @Environment(\.locale) private var locale
    var body: some View {
        let format = movie.fileExtension.uppercased()
        let size = movie.byteCount.map { $0.formatted(.byteCount(style: .file).locale(locale)) }
        let duration = showsDuration ? movie.duration.map(durationLabel) : nil
        let parts = [format.isEmpty ? nil : format, detail ?? size, duration].compactMap { $0 }
        Text(verbatim: parts.joined(separator: " · "))
            .font(.glam(.caption)).monospacedDigit()
            .foregroundStyle(GlamoStyle.secondary).lineLimit(2)
    }
}

struct DriveThumbnail: View {
    @EnvironmentObject private var library: LibraryStore
    let movie: PracticeRecording
    @State private var frame: UIImage?

    var body: some View {
        GlamoStyle.raised.overlay {
            GeometryReader { size in
                Group {
                    if let frame { Image(uiImage: frame).resizable().scaledToFill() }
                    else { Glyph(symbol: movie.isAudio ? .sound : .feed, size: 23, tint: GlamoStyle.secondary) }
                }
                .frame(width: size.size.width, height: size.size.height)
            }
        }
        .clipped().accessibilityHidden(true)
        .task(id: movie.id) {
            frame = nil
            guard !movie.isAudio else { return }
            frame = await makeLocalThumbnail(library.url(for: movie), edge: 480)
        }
    }
}

struct DriveSharedFilesView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var options: DriveItem?
    let play: (PracticeRecording, [PracticeRecording]) -> Void
    let pausePlayback: () -> Void
    let browse: () -> Void
    let back: () -> Void

    var body: some View {
        let files = library.movies.filter { $0.lastSharedAt != nil }
            .sorted { ($0.lastSharedAt ?? .distantPast) > ($1.lastSharedAt ?? .distantPast) }
        GeometryReader { container in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IconButton(symbol: .back, label: "Back", tint: DriveStyle.ink, glass: true, glyphSize: 13, action: back)
                        .rotationEffect(.degrees(layoutDirection == .rightToLeft ? 180 : 0))
                    DrivePageTitle(title: "My shares")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 8)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)

                ScrollView {
                    if files.isEmpty {
                        DriveWorkspaceEmpty(artwork: "DriveShelf", artworkWidth: min(container.size.width * 0.6, 220),
                                            title: "No sharing history yet", message: "Files you share will appear here.") {
                            Button(action: browse) { LocalizedText("Browse files") }
                                .buttonStyle(CompactActionStyle())
                        }
                        .frame(minHeight: max(0, container.size.height - 88))
                        .padding(.horizontal, DriveStyle.pageInset)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(files) { file in
                                let date = (file.lastSharedAt ?? file.date)
                                    .formatted(.dateTime.day().month().year().locale(locale))
                                DriveFileCell(movie: file,
                                              detail: L10n.format("Shared %@", [date], language: AppLanguage.from(locale)),
                                              play: { play(file, files) }, options: { options = .file(file) },
                                              pauseForMenu: pausePlayback)
                            }
                        }
                        .padding(.horizontal, DriveStyle.pageInset).padding(.top, 12).padding(.bottom, 24)
                        .frame(maxWidth: 680).frame(maxWidth: .infinity)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .driveScreenBackground()
        .sheet(item: $options) { DriveItemSheet(item: $0, pausePlayback: pausePlayback) }
    }
}

struct DriveRecentView: View {
    enum History: String, Hashable {
        case saved = "Saved History"
        case viewed = "View History"

        var title: String { self == .saved ? "Saved" : "Viewed" }
    }

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var options: DriveItem?
    @State private var clearingHistory = false
    let history: History?
    let play: (PracticeRecording, [PracticeRecording]) -> Void
    let pausePlayback: () -> Void
    let browse: () -> Void
    let search: () -> Void
    let showActivity: () -> Void
    let showProfile: () -> Void
    let showHistory: (History) -> Void
    let back: () -> Void

    var body: some View {
        let saved = library.favoriteFiles.sorted { $0.date > $1.date }
        let viewed = library.recentlyPlayedFiles.sorted {
            ($0.viewing?.date ?? .distantPast) > ($1.viewing?.date ?? .distantPast)
        }

        GeometryReader { container in
            VStack(spacing: 0) {
                Group {
                    if let history { historyHeader(history) } else { recentHeader }
                }
                .padding(.horizontal, DriveStyle.pageInset).padding(.vertical, 8)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)

                ScrollView {
                    Group {
                        if let history {
                            historyContent(history, files: history == .saved ? saved : viewed)
                                .padding(.top, 20)
                        } else if saved.isEmpty && viewed.isEmpty && library.favorites.isEmpty && library.recentRemotePlayback.isEmpty {
                            DriveWorkspaceEmpty(artwork: "DriveRecentArtwork",
                                                artworkWidth: min(container.size.width * 0.54, container.size.height * 0.46, 176),
                                                title: "No recent activity", message: "Files you save or open will appear here.") {
                                Button(action: browse) {
                                    LocalizedText("Browse files")
                                        .driveFont(20, relativeTo: .headline, weight: .semibold)
                                        .foregroundStyle(DriveStyle.link)
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }.buttonStyle(PressStyle())
                            }
                            .frame(minHeight: max(0, container.size.height - 82))
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                recentSection(.saved, queue: saved)
                                recentSection(.viewed, queue: viewed)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, DriveStyle.pageInset).padding(.bottom, 24)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .driveScreenBackground()
        .sheet(item: $options) { item in
            DriveItemSheet(item: item, pausePlayback: pausePlayback)
        }
        .overlay {
            if clearingHistory, let history {
                AccountDecisionDialog(title: history == .saved ? "Clear saved videos?" : "Clear playback history?",
                                      message: history == .saved
                                        ? "Saved offline copies will be removed. Your imported videos and playback history stay available."
                                        : "Your videos, saved copies and resume positions will stay available.",
                                      confirmTitle: "Clear", destructive: true, cancel: { clearingHistory = false }) {
                    do {
                        if history == .saved { try library.clearSavedVideos() }
                        else { try library.clearPlaybackHistory() }
                    } catch { library.error = error.localizedDescription }
                    clearingHistory = false
                }
            }
        }
    }

    private var recentHeader: some View {
        DriveWorkspaceHeader(title: "Recents") {
            IconButton(symbol: .search, label: "Search files and folders", tint: DriveStyle.ink, action: search)
            IconButton(symbol: .driveActivity, label: "Transfers", tint: DriveStyle.ink, action: showActivity)
            DriveProfileButton(action: showProfile)
        }
    }

    private func historyHeader(_ section: History) -> some View {
        HStack(spacing: 8) {
            IconButton(symbol: .back, label: "Back", tint: DriveStyle.ink, glass: true, glyphSize: 13, action: back)
            LocalizedText(section.title)
                .driveFont(22, relativeTo: .headline, weight: .medium).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            IconButton(symbol: .close, label: section == .saved ? "Clear saved videos" : "Clear playback history", tint: GlamoStyle.danger) {
                pausePlayback()
                clearingHistory = true
            }
        }
    }

    private func historyContent(_ section: History, files: [PracticeRecording]) -> some View {
        let entries = historyEntries(section, files: files)
        let byDay = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
        return VStack(alignment: .leading, spacing: 16) {
            if entries.isEmpty { historyEmpty(section) }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))
                        .driveFont(15, relativeTo: .subheadline).foregroundStyle(DriveStyle.secondary)
                    historyEntriesRows(byDay[day] ?? [], section: section, queue: files)
                }
            }
        }
    }

    private func recentSection(_ section: History, queue: [PracticeRecording]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showHistory(section) } label: {
                HStack(spacing: 8) {
                    LocalizedText(section.rawValue).driveFont(20, relativeTo: .subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Glyph(symbol: .back, size: 12, tint: DriveStyle.secondary)
                        .rotationEffect(.degrees(180))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(DriveStyle.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityAddTraits(.isHeader)
            let entries = Array(historyEntries(section, files: queue).prefix(3))
            if entries.isEmpty {
                historyEmpty(section)
            } else {
                historyEntriesRows(entries, section: section, queue: queue)
            }
        }
    }

    private func historyEmpty(_ section: History) -> some View {
        LocalizedText(section == .saved ? "No videos here yet" : "No playback history")
            .driveFont(14, relativeTo: .footnote).foregroundStyle(DriveStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
    }

    private struct HistoryEntry: Identifiable {
        let id: String
        let date: Date
        var file: PracticeRecording?
        var clip: LessonClip?
    }
    private func historyEntries(_ section: History, files: [PracticeRecording]) -> [HistoryEntry] {
        let remote = section == .saved ? library.favorites : library.recentRemotePlayback.map(\.clip)
        let entries = files.map { HistoryEntry(id: $0.id.uuidString, date: historyDate($0, section: section), file: $0) }
            + remote.map { clip in
                HistoryEntry(id: "remote-" + clip.id,
                             date: section == .saved ? library.savedVideo(clip.id)?.addedAt ?? .distantPast
                                : library.remotePlayback.first { $0.id == clip.id }?.viewing.date ?? .distantPast,
                             clip: clip)
            }
        let sorted = entries.sorted { $0.date > $1.date }
        return section == .viewed ? Array(sorted.prefix(20)) : sorted
    }
    private func historyEntriesRows(_ entries: [HistoryEntry], section: History, queue: [PracticeRecording]) -> some View {
        VStack(spacing: 4) {
            ForEach(entries) { entry in
                if let file = entry.file {
                    historyRow(file, section: section, queue: queue,
                               detail: entry.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
                        .background(.white, in: RoundedRectangle(cornerRadius: DriveStyle.cardRadius))
                } else if let clip = entry.clip {
                    DriveRemoteVideoRows(clips: [clip], viewingHistory: section == .viewed,
                                         playbackQueue: section == .saved ? library.favorites : library.recentRemotePlayback.map(\.clip))
                }
            }
        }
    }

    private func historyRow(_ file: PracticeRecording, section: History, queue: [PracticeRecording],
                            detail: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
        let viewed = section == .viewed
        let thumbSize: CGFloat = viewed ? 64 : 34
        let resume: FileViewingPosition? = file.viewing.flatMap { position in
            viewed && position.seconds > 0 && position.seconds < position.duration - 1 ? position : nil
        }
        let size = file.byteCount.map { $0.formatted(.byteCount(style: .file).locale(locale)) }
        return HStack(spacing: 2) {
            Button { play(file, queue) } label: {
                HStack(spacing: 6) {
                    layout {
                        DriveThumbnail(movie: file)
                            .frame(width: thumbSize, height: thumbSize)
                            .overlay(alignment: .bottom) {
                                if let resume {
                                    DriveMeter(value: resume.seconds / resume.duration, tint: DriveStyle.accent)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: viewed ? 12 : 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: file.displayName)
                                .driveFont(15, relativeTo: .subheadline, weight: .medium)
                                .foregroundStyle(DriveStyle.ink).multilineTextAlignment(.leading)
                                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                            let duration = (file.duration ?? file.viewing?.duration).map(durationLabel)
                            let parts = [detail, duration, viewed || typeSize.isAccessibilitySize ? size : nil]
                                .compactMap { $0 }
                            Text(verbatim: parts.joined(separator: " · "))
                                .driveFont(12, relativeTo: .caption).foregroundStyle(DriveStyle.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !viewed && !typeSize.isAccessibilitySize, let size {
                        Text(verbatim: size)
                            .driveFont(14, relativeTo: .footnote).foregroundStyle(DriveStyle.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                .padding(.leading, 6).padding(.vertical, viewed ? 8 : 5)
                .frame(minHeight: viewed ? 80 : 56)
                .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
                .accessibilityHint(Text(LocalizedStringKey(resume == nil ? "Play" : "Continue playing")))
            DriveListOptionsButton(item: .file(file), pausePlayback: pausePlayback) {
                options = .file(file)
            }
        }
    }

    private func historyDate(_ file: PracticeRecording, section: History) -> Date {
        switch section {
        case .saved: file.date
        case .viewed: file.viewing?.date ?? file.date
        }
    }
}

private struct DriveDatedFiles<Row: View>: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    let files: [PracticeRecording]
    let date: (PracticeRecording) -> Date
    @ViewBuilder let row: (PracticeRecording, String) -> Row

    var body: some View {
        let byDay = Dictionary(grouping: files) { calendar.startOfDay(for: date($0)) }
        return LazyVStack(alignment: .leading, spacing: 15) {
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                if let items = byDay[day] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))
                            .driveFont(20, relativeTo: .subheadline).foregroundStyle(DriveStyle.secondary)
                            .accessibilityAddTraits(.isHeader)
                        DriveGroupedRows(items: items) { file in
                            row(file, date(file).formatted(
                                Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
                            ))
                        }
                    }
                }
            }
        }
    }
}

enum DriveActivityFilter: String, CaseIterable {
    case all = "All"
    case imports = "Imports"
    case exports = "Exports"
    case downloads = "Downloads"
    case failed = "Failed"

    var emptyTitle: String {
        switch self {
        case .all: "No files in this view"
        case .imports: "No imported videos"
        case .exports: "No exported files"
        case .downloads: "No offline downloads"
        case .failed: "No failed transfers"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Imports, downloads and exports appear here."
        case .imports: "Import videos from Files or Photos."
        case .exports: "Export a video or audio file to see it here."
        case .downloads: "Save an online video to make it available offline."
        case .failed: "Failed imports and downloads appear here."
        }
    }
}

struct DriveActivityView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @Binding var filter: DriveActivityFilter
    let play: (PracticeRecording, [PracticeRecording]) -> Void
    let browse: () -> Void
    let back: () -> Void

    var body: some View {
        let movies = library.movies.filter { movie in
            switch filter {
            case .all: true
            case .imports: !movie.isExport
            case .exports: movie.isExport
            case .downloads: false
            case .failed: false
            }
        }.sorted { $0.date > $1.date }
        let latestExport = movies.first(where: \.isExport)
        let showsImportStatus = (filter == .all || filter == .imports) &&
            (library.importingVideo || library.fileImport != nil)
        let failures = filter == .failed ? (library.fileImport?.failures ?? []) : []
        let downloads = library.savedVideos.filter { filter == .all || filter == .downloads || (filter == .failed && $0.state == .failed) }
        GeometryReader { container in
            ScrollView {
                if movies.isEmpty, !showsImportStatus, failures.isEmpty, downloads.isEmpty {
                    DriveTabEmptyState(artwork: "DriveActivityArtwork", paneSize: container.size,
                                       title: filter.emptyTitle, message: filter.emptyMessage,
                                       browse: browse) {
                        activityHeader
                        if !downloads.isEmpty { OfflineTransfersSection(cache: library.offline, records: downloads) }
                    }
                } else {
                    let otherFiles = movies.filter { $0.id != latestExport?.id }
                    VStack(alignment: .leading, spacing: 17) {
                        activityHeader
                        if showsImportStatus { batchStatus(library.fileImport) }
                        if !failures.isEmpty {
                            importFailures(failures)
                                .padding(12)
                                .glamoCard(radius: 16)
                        }
                        if let latestExport { exportSummary(latestExport, queue: movies) }
                        if !otherFiles.isEmpty {
                            DriveDatedFiles(files: otherFiles, date: \.date) { movie, time in
                                DriveFileCell(movie: movie, detail: time, play: { play(movie, movies) })
                            }
                        }
                    }
                    .padding(.horizontal, DriveStyle.pageInset)
                    .padding(.top, 8).padding(.bottom, 24)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
        }.driveScreenBackground()
    }

    private var activityHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconButton(symbol: .back, label: "Back", tint: DriveStyle.ink, glass: true, glyphSize: 13, action: back)
                DrivePageTitle(title: "Transfers")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(DriveActivityFilter.allCases, id: \.self) { choice in
                        Button { filter = choice } label: {
                            LocalizedText(choice.rawValue)
                                .driveFont(15, relativeTo: .subheadline, weight: .medium)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(filter == choice ? .white : DriveStyle.ink)
                                .background(filter == choice ? DriveStyle.ink : .white, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityAddTraits(filter == choice ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func batchStatus(_ batch: VideoImportBatch?) -> some View {
        let progress = batch.map { Double($0.processed) / Double(max($0.total, 1)) }
        return VStack(alignment: .leading, spacing: 9) {
            importStatusHeading(progress)
            if let batch, let progress {
                if library.importingVideo {
                    DriveMeter(value: progress, thickness: 6)
                    if !batch.currentName.isEmpty {
                        Text(verbatim: batch.currentName).font(.glam(.caption))
                            .foregroundStyle(GlamoStyle.secondary).lineLimit(2)
                    }
                }
                let failureCount = batch.failures.count
                LocalizedText("Imported %@ of %@",
                              max(0, batch.processed - failureCount).formatted(.number.locale(locale)),
                              batch.total.formatted(.number.locale(locale)))
                    .font(.glam(.subheadline, weight: .semibold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if failureCount > 0 {
                    LocalizedText("%@ failed", failureCount.formatted(.number.locale(locale)))
                        .font(.glam(.footnote, weight: .semibold)).foregroundStyle(GlamoStyle.danger)
                    importFailures(batch.failures)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paper)
    }

    private func importStatusHeading(_ progress: Double?) -> some View {
        let title = LocalizedText(library.importingVideo ? "Importing…" : "Import results")
            .font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                importStatusIndicator(progress)
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                importStatusIndicator(progress)
            }
        }
    }

    @ViewBuilder
    private func importStatusIndicator(_ progress: Double?) -> some View {
        if library.importingVideo {
            if let progress {
                Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                    .font(.glam(.headline)).monospacedDigit().foregroundStyle(GlamoStyle.accent)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Image("GlamoLoadingMark").resizable().scaledToFit()
                    .frame(width: 32, height: 6).accessibilityHidden(true)
            }
        }
    }

    private func exportSummary(_ movie: PracticeRecording, queue: [PracticeRecording]) -> some View {
        let date = movie.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        let heading = LocalizedText("Latest export").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
        let time = Text(verbatim: date).font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    heading
                    Spacer(minLength: 8)
                    time
                }
                VStack(alignment: .leading, spacing: 3) {
                    heading
                    time
                }
            }
            DriveFileCell(movie: movie, play: { play(movie, queue) })
                .padding(.horizontal, 12).padding(.vertical, 4)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 18), tint: GlamoStyle.surface)
        }
    }

    private func importFailures(_ failures: [VideoImportBatch.Failure]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(failures) { failure in
                Divider().overlay(GlamoStyle.line)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: failure.name).font(.glam(.subheadline, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    LocalizedText(failure.message).font(.glam(.footnote))
                        .foregroundStyle(GlamoStyle.danger).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct DriveTabEmptyState<Header: View>: View {
    let artwork: String
    let paneSize: CGSize
    let title: String
    let message: String
    let browse: () -> Void
    @ViewBuilder let header: () -> Header
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let artworkWidth = typeSize.isAccessibilitySize ? 0 : min(paneSize.width, 480, paneSize.height * 0.70)
        let artworkHeight = artworkWidth * 0.52
        let overlapFraction: CGFloat = 0.13

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header()
                    .pageHorizontalMargins().padding(.top, 16)
                    .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
                if artworkWidth > 0 {
                    Color.clear.frame(height: artworkHeight * (1 - overlapFraction))
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            .background(alignment: .bottom) {
                if artworkWidth > 0 {
                    Image(artwork).resizable().interpolation(.high).scaledToFit()
                        .frame(width: artworkWidth, height: artworkHeight)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: overlapFraction),
                                .init(color: .white, location: 0.21),
                                .init(color: .white, location: 0.96),
                                .init(color: .clear, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LocalizedText(title).font(.glam(.title2, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                LocalizedText(message).font(.glam(.subheadline))
                    .foregroundStyle(GlamoStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: browse) {
                    Label { LocalizedText("Go to Files") } icon: {
                        Glyph(symbol: .driveFolder, size: 16, tint: GlamoStyle.accent)
                    }
                }.buttonStyle(CompactActionStyle()).padding(.top, 4)
            }
            .pageHorizontalMargins()
            .padding(.top, artworkWidth > 0 ? 4 : 16).padding(.bottom, 24)
            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct DrivePageTitle: View {
    let title: String
    var body: some View {
        LocalizedText(title).driveFont(30, relativeTo: .title, weight: .bold).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DriveWorkspaceHeader<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let heading = DrivePageTitle(title: title)
        let tools = HStack(spacing: 0) { actions() }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                tools.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                heading
                tools
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DriveWorkspaceEmpty<Actions: View>: View {
    let artwork: String
    let artworkWidth: CGFloat
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 6) {
            if !typeSize.isAccessibilitySize {
                Image(artwork).resizable().interpolation(.high).scaledToFit()
                    .frame(width: max(0, artworkWidth), height: max(0, artworkWidth))
                    .padding(.bottom, 20)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
            LocalizedText(title)
                .driveFont(20, relativeTo: .headline, weight: .semibold).accessibilityAddTraits(.isHeader)
            LocalizedText(message)
                .driveFont(14, relativeTo: .footnote).foregroundStyle(DriveStyle.secondary)
                .frame(maxWidth: 238)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions() }.fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) { actions() }
            }.padding(.top, 6)
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

struct DriveProfileAvatar: View {
    let size: CGFloat

    var body: some View {
        Image("GlamoLaunchMark").resizable().scaledToFit()
            .frame(width: size * 0.74, height: size * 0.74)
            .frame(width: size, height: size)
            .background(DriveStyle.ink, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct DriveProfileButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DriveProfileAvatar(size: 36)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityLabel("Profile")
    }
}

struct DriveMeter: View {
    let value: Double
    var tint = GlamoStyle.accent
    var thickness: CGFloat = 3
    var body: some View {
        GeometryReader { track in
            Capsule().fill(tint.opacity(0.2)).overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: track.size.width * CGFloat(value.isFinite ? min(1, max(0, value)) : 0))
            }
        }.frame(height: thickness).accessibilityHidden(true).allowsHitTesting(false)
    }
}

enum DriveItem: Identifiable {
    case file(PracticeRecording)
    case folder(VideoFolder)

    var id: UUID {
        switch self {
        case .file(let file): file.id
        case .folder(let folder): folder.id
        }
    }
}

private struct DriveListOptionsButton: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showingMenu = false
    let item: DriveItem
    let pausePlayback: () -> Void
    let fallback: () -> Void

    var body: some View {
        let metadata: (label: String, name: String) = switch item {
        case .file(let file): ("File options", file.displayName)
        case .folder(let folder): ("Folder options", folder.name)
        }

        IconButton(symbol: .driveMore, label: metadata.label, tint: DriveStyle.secondary, glyphSize: 14) {
            if typeSize.isAccessibilitySize || verticalSizeClass == .compact {
                fallback()
            } else {
                showingMenu = true
            }
        }
        .accessibilityValue(Text(verbatim: metadata.name))
        .popover(isPresented: $showingMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            DriveItemSheet(item: item, pausePlayback: pausePlayback, compactMenu: true)
                .presentationBackground(.regularMaterial)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct DriveItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @ScaledMetric(relativeTo: .subheadline) private var videoActionColumnWidth: CGFloat = 152
    let item: DriveItem
    let pausePlayback: () -> Void
    private let closeVideoOptions: (() -> Void)?
    private let compactMenu: Bool
    private var returnsToVideoOptions = false
    @State private var mode: Mode = .actions
    @State private var videoDetail: Mode?
    @State private var editing = false
    @State private var paywall = false
    @State private var share: SharedFile?
    @State private var sharing = false
    @State private var shareByteCount: Int64?
    @State private var shareError: String?
    @State private var error: String?

    private enum Mode: Hashable, Identifiable {
        case actions, rename, move, remove

        var id: Self { self }
    }

    init(item: DriveItem, pausePlayback: @escaping () -> Void, closeVideoOptions: (() -> Void)? = nil,
         compactMenu: Bool = false) {
        self.item = item
        self.pausePlayback = pausePlayback
        self.closeVideoOptions = closeVideoOptions
        self.compactMenu = compactMenu
    }

    private init(item: DriveItem, pausePlayback: @escaping () -> Void, opening detail: Mode) {
        self.init(item: item, pausePlayback: pausePlayback)
        _mode = State(initialValue: detail)
        returnsToVideoOptions = true
    }

    private struct MoveDestination: Identifiable {
        let folder: VideoFolder
        let path: [VideoFolder]
        var id: UUID { folder.id }
    }

    private var current: DriveItem {
        switch item {
        case .file(let file): .file(library.movies.first { $0.id == file.id } ?? file)
        case .folder(let folder): .folder(library.folders.first { $0.id == folder.id } ?? folder)
        }
    }

    private var currentName: String {
        switch current {
        case .file(let file): file.title
        case .folder(let folder): folder.name
        }
    }

    private var optionsTitle: String {
        switch item {
        case .file: "File options"
        case .folder: "Folder options"
        }
    }

    private var sheetTitle: String {
        switch mode {
        case .actions: optionsTitle
        case .rename: "Rename"
        case .move: "Move to folder"
        case .remove: removalDetails.title
        }
    }

    var body: some View {
        Group {
            if let closeVideoOptions, case .file(let file) = current {
                DriveVideoBottomOverlay(title: optionsTitle, columnWidth: videoActionColumnWidth, close: {
                    if !sharing { closeVideoOptions() }
                }) { columns in
                    let actions = videoActions(for: file, columns: columns)
                    return ViewThatFits(in: .vertical) {
                        actions.fixedSize(horizontal: false, vertical: true)
                        ScrollView { actions }.scrollBounceBehavior(.basedOnSize)
                    }
                }
            } else if compactMenu {
                compactActions
            } else {
                sheetContent
            }
        }
        .allowsHitTesting(!sharing)
        .interactiveDismissDisabled(sharing)
        .sheet(isPresented: $editing) {
            if case .file(let movie) = current { EditorSheet(initialMovie: movie) }
        }
        .fullScreenCover(isPresented: $paywall) { MembershipView(requiredBenefit: .mediaExport) }
        .sheet(item: $share) { file in
            ShareSheet(items: [file.url], onCompletion: { outcome in
                if case .completed = outcome, let id = file.recordingID { library.recordSharedFile(id) }
            })
        }
        .sheet(item: $videoDetail) { detail in
            DriveItemSheet(item: item, pausePlayback: pausePlayback, opening: detail)
        }
    }

    private var sheetContent: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                sheetHeader
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 4)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                switch mode {
                case .actions:
                    sheetScroll { actionsPanel }
                case .rename:
                    DriveNameForm(startingName: currentName) { name in
                        switch current {
                        case .file(let file): try library.renameFile(file.id, to: name)
                        case .folder(let folder): try library.renameFolder(folder.id, to: name)
                        }
                        returnToActions()
                    }
                case .move:
                    sheetScroll { movePanel }
                case .remove:
                    sheetScroll { removalPanel }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            DriveSheetFooter {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 10) { removalActions(disabled: false) }
                                    VStack(spacing: 8) { removalActions(disabled: false) }
                                }
                            }
                        }
                }
            }
            .padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }
        .glamoScreenBackground()
    }

    @ViewBuilder private var sheetHeader: some View {
        if mode == .actions {
            SheetHeading(title: sheetTitle, inset: false) { dismiss() }
        } else {
            HStack(spacing: 10) {
                IconButton(symbol: .back, label: "Back", glass: true, action: returnToActions)
                    .rotationEffect(.degrees(layoutDirection == .leftToRight ? 0 : 180))
                LocalizedText(sheetTitle).font(.glam(.headline))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func sheetScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .file(let file) = current, sharing || shareError != nil || share != nil {
                shareStatus(for: file)
            } else {
                itemSummary
                    .padding(14)
                    .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
            }
            if case .file(let file) = current {
                favoriteOption(file)
                fileActions(file)
            }
            errorMessage
            managementActions
            option(removalDetails.title, glyph: .close, tint: GlamoStyle.danger) { openDetail(.remove) }
                .background(GlamoStyle.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var compactActions: some View {
        let rows = VStack(spacing: 0) {
            if case .file(let file) = current {
                favoriteOption(file)
                if sharing || shareError != nil || share != nil {
                    shareStatus(for: file).padding(.bottom, 8)
                }
                if !file.isAudio {
                    compactOption("Edit video", glyph: .edit, tint: Color(red: 0.95, green: 0.55, blue: 0.22),
                                  action: beginEditing)
                }
                compactOption(shareError == nil ? "Share file" : "Retry sharing", glyph: .driveShare,
                              tint: Color(red: 0.16, green: 0.72, blue: 0.90)) { shareFile(file) }
                    .disabled(sharing)
            }
            compactOption("Rename", glyph: .edit, tint: DriveStyle.accent) { openDetail(.rename) }
            compactOption("Move to folder", glyph: .driveFolder, tint: Color(red: 0.22, green: 0.68, blue: 0.37)) {
                openDetail(.move)
            }
            Divider().overlay(.white.opacity(0.35))
            compactOption("Delete", glyph: .close, tint: GlamoStyle.danger) { openDetail(.remove) }
        }

        return ViewThatFits(in: .vertical) {
            rows.fixedSize(horizontal: false, vertical: true)
            ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
        }
        .padding(10)
        .frame(width: 218)
        .frame(maxHeight: 330)
        .foregroundStyle(DriveStyle.ink)
    }

    private func compactOption(_ title: String, glyph: GlamoGlyph, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Glyph(symbol: glyph, size: 16, tint: .white)
                    .frame(width: 30, height: 30)
                    .background(tint, in: RoundedRectangle(cornerRadius: 9))
                LocalizedText(title)
                    .driveFont(15, relativeTo: .subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 5).padding(.vertical, 6)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func videoActions(for file: PracticeRecording, columns: [GridItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if sharing || shareError != nil || share != nil {
                shareStatus(for: file)
                    .environment(\.colorScheme, .light)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                videoOption(file.isFavorite == true ? "Remove from saved" : "Save video", glyph: .feed) {
                    perform { try library.toggleFileFavorite(file.id) }
                }
                if !file.isAudio {
                    videoOption("Edit video", glyph: .edit, action: beginEditing)
                }
                videoOption(shareError == nil ? "Share file" : "Retry sharing", glyph: .driveShare) {
                    shareFile(file)
                }
                .disabled(sharing)
                videoOption("Rename", glyph: .edit) { openDetail(.rename) }
                videoOption("Move to folder", glyph: .driveFolder) { openDetail(.move) }
            }

            Divider().overlay(Color.white.opacity(0.18)).allowsHitTesting(false).accessibilityHidden(true)
            videoOption(removalDetails.title, glyph: .close, role: .destructive) { openDetail(.remove) }
        }
    }

    private func videoOption(_ title: String, glyph: GlamoGlyph, role: ButtonRole? = nil,
                             action: @escaping () -> Void) -> some View {
        let destructive = role == .destructive
        let tint = destructive ? Color(red: 1, green: 0.72, blue: 0.76) : Color(red: 0.66, green: 0.84, blue: 1)
        return Button(role: role, action: action) {
            HStack(spacing: 10) {
                Glyph(symbol: glyph, size: 16, tint: tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                LocalizedText(title)
                    .font(.glam(.subheadline, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(destructive ? tint : .white)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(destructive ? GlamoStyle.danger.opacity(0.28) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func openDetail(_ detail: Mode) {
        if closeVideoOptions != nil || compactMenu {
            videoDetail = detail
        } else {
            mode = detail
        }
    }

    private func returnToActions() {
        if returnsToVideoOptions {
            dismiss()
            return
        }
        mode = .actions
        error = nil
    }

    private var itemSummary: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                  : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Group {
                switch current {
                case .file(let movie):
                    DriveThumbnail(movie: movie)
                case .folder:
                    Glyph(symbol: .driveFolder, size: 26, tint: GlamoStyle.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(GlamoStyle.paper)
                }
            }
            .frame(width: 76, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true).allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: currentName)
                    .font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                switch current {
                case .file(let movie):
                    DriveFileMetadata(movie: movie, detail: nil)
                case .folder:
                    LocalizedText("Folder").font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func fileActions(_ file: PracticeRecording) -> some View {
        if file.isAudio {
            fileActionButtons(file)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { fileActionButtons(file) }
                VStack(spacing: 8) { fileActionButtons(file) }
            }
        }
    }

    private func favoriteOption(_ file: PracticeRecording) -> some View {
        Button {
            perform { try library.toggleFileFavorite(file.id) }
        } label: {
            HStack(spacing: 10) {
                Image(file.isFavorite == true ? "PlayerSaved" : "PlayerSave").resizable().scaledToFit()
                    .frame(width: 28, height: 28).accessibilityHidden(true)
                LocalizedText(file.isFavorite == true ? "Remove from saved" : "Save video")
                    .font(.glam(.subheadline, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.multilineTextAlignment(.leading).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    @ViewBuilder private func fileActionButtons(_ file: PracticeRecording) -> some View {
        if !file.isAudio {
            Button(action: beginEditing) {
                Label { LocalizedText("Edit video") } icon: {
                    Glyph(symbol: .edit, size: 17, tint: GlamoStyle.onAccent)
                }
            }
            .buttonStyle(GlamoActionStyle())
        }
        Button {
            shareFile(file)
        } label: {
            Label { LocalizedText(shareError == nil ? "Share file" : "Retry sharing") } icon: {
                Glyph(symbol: .driveShare, size: 17, tint: file.isAudio && !sharing ? GlamoStyle.onAccent : GlamoStyle.accent)
            }
        }
        .buttonStyle(GlamoActionStyle(primary: file.isAudio))
        .disabled(sharing)
    }

    private func beginEditing() {
        pausePlayback()
        editing = true
    }

    private func shareStatus(for file: PracticeRecording) -> some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                          : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        let size = shareByteCount?.formatted(.byteCount(style: .file).locale(locale))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Glyph(symbol: .driveShare, size: 18, tint: GlamoStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(GlamoStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                Text(verbatim: share?.url.lastPathComponent ?? file.displayName)
                    .font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            layout {
                shareDetail("Format", value: file.fileExtension.uppercased().nilIfBlank)
                shareDetail("File size", value: size)
            }

            if sharing {
                Divider().overlay(GlamoStyle.line)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(GlamoStyle.accent)
                        .accessibilityHidden(true)
                    LocalizedText("Preparing to share…")
                        .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.accent)
                }
            } else if let shareError {
                Divider().overlay(GlamoStyle.line)
                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText("Share preparation failed")
                        .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.danger)
                        .accessibilityAddTraits(.isHeader)
                    LocalizedText(shareError)
                        .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    private func shareDetail(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LocalizedText(title).font(.glam(.caption, weight: .medium)).foregroundStyle(GlamoStyle.secondary)
            Group {
                if let value { Text(verbatim: value) }
                else { LocalizedText("Unavailable") }
            }
            .font(.glam(.subheadline, weight: .semibold)).monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var managementActions: some View {
        VStack(spacing: 0) {
            option("Rename", glyph: .edit, showsArrow: true) { openDetail(.rename) }
            Divider().overlay(GlamoStyle.line).padding(.horizontal, 12)
            option("Move to folder", glyph: .driveFolder, showsArrow: true) { openDetail(.move) }
        }
        .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.surface)
    }

    private var movePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            moveSummary
            errorMessage
            VStack(alignment: .leading, spacing: 8) {
                LocalizedText("Destination folder")
                    .font(.glam(.headline)).foregroundStyle(GlamoStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(spacing: 0) {
                    destination(nil)
                    ForEach(moveDestinations) { target in
                        Divider().overlay(GlamoStyle.line).padding(.horizontal, 12)
                        destination(target)
                    }
                }
                .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.surface)
            }
        }
    }

    private var currentLocation: UUID? {
        switch current {
        case .file(let file): file.folderID
        case .folder(let folder): folder.parentID
        }
    }

    private var moveSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            itemSummary
            Divider().overlay(GlamoStyle.line)
            VStack(alignment: .leading, spacing: 3) {
                LocalizedText("Current location")
                    .font(.glam(.caption, weight: .semibold)).foregroundStyle(GlamoStyle.secondary)
                Text(verbatim: movePath(library.folderPath(to: currentLocation)))
                    .font(.glam(.subheadline, weight: .medium)).foregroundStyle(GlamoStyle.ink)
            }
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
        .padding(14)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    private var moveDestinations: [MoveDestination] {
        library.folders.filter { canMove(into: $0.id) }
            .map { MoveDestination(folder: $0, path: library.folderPath(to: $0.id)) }
            .sorted { first, second in
                for (left, right) in zip(first.path, second.path) where left.id != right.id {
                    let order = left.name.localizedStandardCompare(right.name)
                    return order == .orderedSame ? left.id.uuidString < right.id.uuidString : order == .orderedAscending
                }
                return first.path.count < second.path.count
            }
    }

    private var filesTitle: String {
        L10n.text("Files", language: AppLanguage.from(locale))
    }

    private func movePath(_ folders: [VideoFolder]) -> String {
        ([filesTitle] + folders.map(\.name)).joined(separator: " / ")
    }

    private var removalPanel: some View {
        let details = removalDetails
        return VStack(alignment: .leading, spacing: 14) {
            itemSummary
                .padding(14)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)

            VStack(alignment: .leading, spacing: 5) {
                LocalizedText(details.containsItems ? "Folder contains items" : "After deletion")
                    .font(.glam(.subheadline, weight: .semibold))
                    .foregroundStyle(details.containsItems ? GlamoStyle.danger : GlamoStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                LocalizedText(details.explanation)
                    .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
            }
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(details.containsItems ? GlamoStyle.danger.opacity(0.08) : GlamoStyle.surface,
                        in: RoundedRectangle(cornerRadius: 14))

            errorMessage
        }
    }

    @ViewBuilder private func removalActions(disabled: Bool) -> some View {
        ActionButton(title: "Cancel", primary: false, action: returnToActions)
        Button(role: .destructive) {
            perform {
                switch current {
                case .file(let file): library.delete(file)
                case .folder(let folder): try library.removeFolder(folder.id)
                }
                dismiss()
            }
        } label: {
            LocalizedText("Delete")
                .font(.glam(.subheadline, weight: .semibold))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(disabled ? GlamoStyle.secondary : GlamoStyle.onAccent)
                .background(disabled ? GlamoStyle.raised : GlamoStyle.danger, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).disabled(disabled)
    }

    @ViewBuilder private var errorMessage: some View {
        if let error { ErrorNote(message: error) }
    }

    private var removalDetails: (title: String, explanation: String, containsItems: Bool) {
        switch current {
        case .file:
            return ("Delete local copy", "This deletes the file from Vifol. Any original in Photos or Files stays there.", false)
        case .folder(let folder):
            let containsItems = library.movies.contains { $0.folderID == folder.id }
                || library.folders.contains { $0.parentID == folder.id }
                || library.savedVideos.contains { $0.folderID == folder.id }
            let explanation = containsItems
                ? "Files and nested folders will move up one level. Your videos will not be deleted."
                : "The empty folder will be removed from Vifol."
            return ("Delete folder", explanation, containsItems)
        }
    }

    private func option(_ title: String, glyph: GlamoGlyph, tint: Color = GlamoStyle.ink, showsArrow: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Glyph(symbol: glyph, size: 18, tint: showsArrow ? GlamoStyle.accent : tint)
                LocalizedText(title).font(.glam(.subheadline, weight: .semibold))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if showsArrow {
                    Glyph(symbol: .back, size: 12, tint: GlamoStyle.secondary)
                        .rotationEffect(.degrees(layoutDirection == .leftToRight ? 180 : 0))
                }
            }.foregroundStyle(tint).padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 50)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    private func destination(_ target: MoveDestination?) -> some View {
        let folderID = target?.id
        let isCurrentLocation = folderID == currentLocation
        let ancestors = target.map { Array($0.path.dropLast()) } ?? []
        let indent = CGFloat(min(ancestors.count, 3)) * 8
        let usesStackedLayout = typeSize >= .xxLarge
        let layout = usesStackedLayout ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                       : AnyLayout(HStackLayout(spacing: 8))
        return Button {
            perform {
                switch current {
                case .file(let file): try library.moveFile(file.id, into: folderID)
                case .folder(let folder): try library.moveFolder(folder.id, into: folderID)
                }
                dismiss()
            }
        } label: {
            layout {
                HStack(spacing: 8) {
                    Glyph(symbol: .driveFolder, size: 18, tint: GlamoStyle.accent)
                        .frame(width: 30, height: 30)
                        .background(GlamoStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: target?.folder.name ?? filesTitle)
                            .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                        if target != nil {
                            Text(verbatim: movePath(ancestors))
                                .font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
                        }
                    }
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LocalizedText(isCurrentLocation ? "Current location" : "Move here")
                    .font(.glam(.footnote, weight: .semibold))
                    .foregroundStyle(isCurrentLocation ? GlamoStyle.secondary : GlamoStyle.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: !usesStackedLayout, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(isCurrentLocation ? GlamoStyle.raised : GlamoStyle.accent.opacity(0.09), in: Capsule())
            }
            .padding(.leading, 12 + indent).padding(.trailing, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).disabled(isCurrentLocation)
    }

    private func canMove(into folderID: UUID) -> Bool {
        guard case .folder(let folder) = current else { return true }
        return !library.folderPath(to: folderID).contains { $0.id == folder.id }
    }

    private func shareFile(_ file: PracticeRecording) {
        guard !sharing else { return }
        shareError = nil
        guard commerce.canExportMedia else {
            pausePlayback()
            paywall = true
            return
        }
        error = nil
        shareByteCount = file.byteCount
            ?? (try? library.url(for: file).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        sharing = true
        Task {
            defer { sharing = false }
            do { share = SharedFile(url: try await library.shareFile(for: file, commerce: commerce), recordingID: file.id) }
            catch { shareError = error.localizedDescription }
        }
    }

    private func perform(_ work: () throws -> Void) {
        error = nil
        do { try work() }
        catch { self.error = error.localizedDescription }
    }
}

struct DriveNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let startingName: String
    let save: (String) throws -> Void

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                SheetHeading(title: title, inset: false) { dismiss() }
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 4)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                DriveNameForm(startingName: startingName, creatingFolder: true) { name in
                    try save(name)
                    dismiss()
                }
            }
            .padding(drivePaneMargins(in: container, includesHorizontalFold: true))
        }.glamoScreenBackground()
    }
}

private struct DriveNameForm: View {
    let creatingFolder: Bool
    let save: (String) throws -> Void
    private let startingName: String
    @State private var name: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(startingName: String, creatingFolder: Bool = false, save: @escaping (String) throws -> Void) {
        self.startingName = startingName
        self.creatingFolder = creatingFolder
        self.save = save
        _name = State(initialValue: startingName)
    }

    private var nameIsEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if creatingFolder {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Glyph(symbol: .driveFolder, size: 19, tint: GlamoStyle.accent)
                                .frame(width: 34, height: 34)
                                .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 9))
                            LocalizedText("Folder name").font(.glam(.subheadline, weight: .semibold))
                        }.accessibilityHidden(true)
                        nameField
                        if let error { ErrorNote(message: error) }
                    }
                    .padding(14)
                    .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
                } else {
                    renameFields
                }
            }
            .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 16)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DriveSheetFooter {
                ActionButton(title: creatingFolder ? "Create folder" : "Save name", action: commit)
                    .disabled(nameIsEmpty)
            }
        }
        .onChange(of: name) { _, _ in error = nil }
    }

    @ViewBuilder private var renameFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            LocalizedText("Current name")
                .font(.glam(.caption, weight: .semibold)).foregroundStyle(GlamoStyle.secondary)
            Text(verbatim: startingName)
                .font(.glam(.headline)).fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
        .accessibilityElement(children: .combine)

        VStack(alignment: .leading, spacing: 6) {
            LocalizedText("New name")
                .font(.glam(.subheadline, weight: .semibold))
                .accessibilityHidden(true)
            nameField
            if let message = nameIsEmpty ? "Enter a new name." : error {
                ErrorNote(message: message)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nameField: some View {
        TextField(LocalizedStringKey(creatingFolder ? "Folder name" : "New name"), text: $name,
                  prompt: Text(verbatim: ""))
            .autocorrectionDisabled().submitLabel(.done)
            .focused($nameFocused)
            .glamoField()
            .overlay {
                if nameFocused {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(GlamoStyle.accent)
                        .allowsHitTesting(false)
                }
            }
            .onSubmit(commit)
    }

    private func commit() {
        guard !nameIsEmpty else { return }
        error = nil
        do { try save(name) }
        catch { self.error = error.localizedDescription }
    }
}

private struct DriveSheetFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .pageHorizontalMargins().padding(.vertical, 8)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .background(.regularMaterial, ignoresSafeAreaEdges: [.horizontal, .bottom])
            .overlay(alignment: .top) { Divider().overlay(GlamoStyle.line).allowsHitTesting(false) }
    }
}

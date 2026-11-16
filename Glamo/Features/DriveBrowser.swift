import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation

struct DriveBrowser: View {
    private enum ImportSource { case files, photos }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .footnote) private var inlineToolbarWidth: CGFloat = 620
    @AppStorage("drive.useGrid") private var useGrid = true
    @AppStorage("drive.sortByName") private var sortByName = false
    @SceneStorage("home.linkDraft") private var linkDraft = ""
    @State private var currentFolderID: UUID?
    @State private var query = ""
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
    @FocusState private var linkFocused: Bool
    @Binding var isSearching: Bool
    let play: (PracticeRecording, [PracticeRecording]) -> Void
    let pausePlayback: () -> Void
    let showActivity: () -> Void

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var folder: VideoFolder? { library.folders.first { $0.id == currentFolderID } }

    private var visibleFolders: [VideoFolder] {
        library.folders.filter { entry in
            searchTerm.isEmpty ? entry.parentID == currentFolderID : entry.name.localizedStandardContains(searchTerm)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleFiles: [PracticeRecording] {
        library.movies.filter { movie in
            if !searchTerm.isEmpty { return movie.displayName.localizedStandardContains(searchTerm) }
            return currentFolderID == nil || movie.folderID == currentFolderID
        }.sorted { a, b in
            if sortByName {
                let order = a.displayName.localizedStandardCompare(b.displayName)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.date > b.date
        }
    }

    var body: some View {
        GeometryReader { container in
            let pane = drivePaneMargins(in: container)
            let paneWidth = max(0, container.size.width - pane.leading - pane.trailing)
            let canUseGrid = paneWidth >= 300 && !typeSize.isAccessibilitySize && !driveHasReservedRegion(container)
            let folders = visibleFolders
            let movies = visibleFiles
            let hasFilesOrFolders = !folders.isEmpty || !movies.isEmpty
            let showsArtwork = !hasFilesOrFolders && searchTerm.isEmpty && !typeSize.isAccessibilitySize
            let artworkWidth = min(paneWidth, verticalSizeClass == .compact ? 280 : 480)

            ScrollView {
                VStack(spacing: 0) {
                    browserTop(artworkWidth: showsArtwork ? artworkWidth : nil,
                               showsFolderImport: hasFilesOrFolders || !searchTerm.isEmpty)
                    VStack(alignment: .leading, spacing: 8) {
                        if !library.movies.isEmpty || !library.folders.isEmpty || !query.isEmpty || searchFocused {
                            fileToolbar(inline: paneWidth >= inlineToolbarWidth && !typeSize.isAccessibilitySize,
                                        showsControls: !movies.isEmpty || (searchTerm.isEmpty && !folders.isEmpty),
                                        canUseGrid: canUseGrid)
                        }
                        importStatus
                        if !searchTerm.isEmpty, hasFilesOrFolders {
                            LocalizedText("Search results").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
                        }
                        if !folders.isEmpty { folderShelf(folders, tile: useGrid && canUseGrid) }
                        if !hasFilesOrFolders {
                            if searchTerm.isEmpty {
                                if folder != nil { emptyOpenedFolder }
                                else { emptyFolder }
                            } else { noSearchResults }
                        } else if searchTerm.isEmpty || !movies.isEmpty {
                            videoFiles(movies, canUseGrid: canUseGrid)
                        }
                    }
                    .pageHorizontalMargins()
                    .padding(.top, showsArtwork ? 4 : 12).padding(.bottom, 24)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }
            .padding(pane)
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnOutsideTap($linkFocused, scope: "home-link-input")
        }
        .glamoScreenBackground()
        .onChange(of: searchFocused || linkFocused) { _, focused in isSearching = focused }
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
        .sheet(isPresented: $showingPlus) { MembershipView() }
    }

    private func browserTop(artworkWidth: CGFloat?, showsFolderImport: Bool) -> some View {
        let artworkHeight = (artworkWidth ?? 0) * 0.44
        let overlapFraction: CGFloat = 0.13

        return VStack(spacing: 0) {
            VStack(spacing: 18) {
                if let folder {
                    folderHeader(folder, showsImport: showsFolderImport)
                } else {
                    header
                }
                if currentFolderID == nil {
                    VideoLinkComposer(link: $linkDraft, focused: $linkFocused, willOpen: pausePlayback)
                        .disabled(library.importingVideo)
                }
            }.pageHorizontalMargins().padding(.top, 16)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
            if artworkWidth != nil {
                Color.clear.frame(height: artworkHeight * (1 - overlapFraction))
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .background(alignment: .bottom) {
            if let artworkWidth {
                Image("DriveShelf").resizable().interpolation(.high).scaledToFill()
                    .frame(width: artworkWidth, height: artworkHeight)
                    .clipped()
                    .mask {
                        // The artwork stays transparent behind the title and URL controls.
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: overlapFraction),
                            .init(color: .white, location: 0.19),
                            .init(color: .white, location: 0.96),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
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
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).frame(minHeight: 44)
                    .glamoCard(radius: 12, fill: GlamoStyle.paper).contentShape(Rectangle())
            }.buttonStyle(PressStyle())
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                location
                Spacer(minLength: 8)
                if currentFolderID == nil { plusButton }
                importButton.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                location
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        importButton
                        if currentFolderID == nil { plusButton }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        importButton
                        if currentFolderID == nil { plusButton }
                    }
                }
            }
        }
    }

    private var plusButton: some View {
        PlusShortcut(isMember: commerce.premium) {
            linkFocused = false
            searchFocused = false
            showingPlus = true
        }
        .disabled(library.importingVideo)
        .accessibilityIdentifier("home.plus")
    }

    private var location: some View {
        HStack(spacing: 6) {
            LocalizedText("Files").font(.glam(.largeTitle, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func folderHeader(_ folder: VideoFolder, showsImport: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    parentFolderButton(folder)
                    Spacer(minLength: 0)
                    if showsImport { importButton }
                }
                VStack(alignment: .leading, spacing: 8) {
                    parentFolderButton(folder)
                    if showsImport { importButton }
                }
            }
            Text(verbatim: folder.name)
                .font(.glam(.largeTitle, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            folderBreadcrumb(folder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parentFolderButton(_ folder: VideoFolder) -> some View {
        Button {
            currentFolderID = folder.parentID
            query = ""
            searchFocused = false
        } label: {
            HStack(spacing: 6) {
                Glyph(symbol: .back, size: 14, tint: GlamoStyle.accent)
                LocalizedText("Parent folder")
            }
        }.buttonStyle(CompactActionStyle())
    }

    private func folderBreadcrumb(_ folder: VideoFolder) -> some View {
        let path = library.folderPath(to: folder.id)
        return ScrollView(.horizontal) {
            HStack(spacing: 7) {
                LocalizedText("Files")
                ForEach(path) { component in
                    Glyph(symbol: .back, size: 9, tint: GlamoStyle.secondary).rotationEffect(.degrees(180))
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

    private var importButton: some View {
        Button {
            searchFocused = false
            linkFocused = false
            choosingImportSource = true
        } label: {
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
                    importSourceButton(.photos, title: "Choose from Photos", detail: "Pick a video to open in the editor.",
                                       glyph: .feed, tint: GlamoStyle.surface)
                        .accessibilityIdentifier("video.importPhotos")
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
                Glyph(symbol: .back, size: 12, tint: GlamoStyle.accent).rotationEffect(.degrees(180))
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

    private func fileToolbar(inline: Bool, showsControls: Bool, canUseGrid: Bool) -> some View {
        let layout = inline ? AnyLayout(HStackLayout(spacing: 8))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            searchField(compact: inline && showsControls && !searchFocused)
                .frame(minWidth: inline ? 152 : nil)
            if showsControls, !searchFocused {
                browserControls(canUseGrid: canUseGrid, fillRow: !inline)
                    .layoutPriority(1)
            }
        }
    }

    private func searchField(compact: Bool) -> some View {
        let prompt = compact ? "Search" : "Search files and folders"
        let shape = RoundedRectangle(cornerRadius: 16)
        return HStack(spacing: 9) {
            Glyph(symbol: .search, size: 17, tint: GlamoStyle.accent)
                .frame(width: 32, height: 32)
                .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 9))
                .padding(.leading, 8)
            TextField("Search files and folders", text: $query,
                      prompt: Text(LocalizedStringKey(prompt)).foregroundColor(GlamoStyle.secondary))
                .focused($searchFocused)
                .font(.glam(.subheadline)).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { searchFocused = false }
                .frame(minHeight: 44)
            if !query.isEmpty {
                IconButton(symbol: .close, label: "Clear search", tint: GlamoStyle.secondary) { query = "" }
            }
        }
        .padding(.trailing, 6)
        .frame(minHeight: 50)
        .glamoGlass(in: shape, tint: searchFocused ? GlamoStyle.paperMuted : GlamoStyle.surface, mediaBackdrop: true)
        .overlay {
            shape.strokeBorder(searchFocused ? GlamoStyle.accent : GlamoStyle.line)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("drive.search")
    }

    private func filesHeading(_ count: Int) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                                                 : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            if searchTerm.isEmpty {
                LocalizedText("Video files").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            }
            LocalizedText(count == 1 ? "%@ item" : "%@ items", count.formatted(.number.locale(locale)))
                .font(.glam(.caption)).foregroundStyle(GlamoStyle.secondary)
        }
    }

    private func browserControls(canUseGrid: Bool, fillRow: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sortAndFolderControls
                if canUseGrid {
                    if fillRow { Spacer(minLength: 0) }
                    fileLayoutControl
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sortAndFolderControls
                if canUseGrid { fileLayoutControl }
            }
        }
    }

    private var sortAndFolderControls: some View {
        let order = sortByName ? "Name A–Z" : "Newest first"
        return HStack(spacing: 6) {
            if searchTerm.isEmpty {
                IconButton(symbol: .driveAdd, label: "New folder", glass: true) { showNewFolder = true }
            }
            Button { sortByName.toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    LocalizedText("Sort by").font(.glam(.caption2)).foregroundStyle(GlamoStyle.secondary)
                    ZStack(alignment: .leading) {
                        LocalizedText("Newest first").opacity(sortByName ? 0 : 1)
                        LocalizedText("Name A–Z").opacity(sortByName ? 1 : 0)
                    }
                    .font(.glam(.footnote, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                    .accessibilityHidden(true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(minWidth: 44, minHeight: 50, alignment: .leading)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 14), tint: GlamoStyle.paper, interactive: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(Text("Sort by"))
            .accessibilityValue(Text(LocalizedStringKey(order)))
            .accessibilityHint(Text("Change file sort order"))
        }
    }

    private var fileLayoutControl: some View {
        HStack(spacing: 2) {
            fileLayoutOption(grid: false)
            fileLayoutOption(grid: true)
        }
        .padding(3)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 14), tint: GlamoStyle.paper)
    }

    private func fileLayoutOption(grid: Bool) -> some View {
        let active = useGrid == grid
        let tint = active ? GlamoStyle.onAccent : GlamoStyle.ink
        return Button { useGrid = grid } label: {
            VStack(spacing: 2) {
                Glyph(symbol: grid ? .driveGrid : .driveList, size: 15, tint: tint)
                LocalizedText(grid ? "Grid" : "List").font(.glam(.caption2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minWidth: 46, minHeight: 44)
            .background(active ? GlamoStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(Text(LocalizedStringKey(grid ? "Grid view" : "List view")))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func folderShelf(_ entries: [VideoFolder], tile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if searchTerm.isEmpty {
                LocalizedText("Folders").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            }
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
                LazyVStack(spacing: 6) {
                    ForEach(entries) { folderCell($0, tile: false) }
                }
            }
        }
    }

    private func folderCell(_ entry: VideoFolder, tile: Bool) -> some View {
        let layout = tile ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                          : AnyLayout(HStackLayout(spacing: 10))
        let open = Button {
            currentFolderID = entry.id
            query = ""
            searchFocused = false
        } label: {
            layout {
                Glyph(symbol: .driveFolder, size: 23, tint: GlamoStyle.accent)
                    .frame(width: 38, height: 36)
                    .background(GlamoStyle.paperMuted, in: RoundedRectangle(cornerRadius: 9))
                Text(verbatim: entry.name)
                    .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.ink)
                    .multilineTextAlignment(.leading).lineLimit(2, reservesSpace: tile)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10).padding(.trailing, tile ? 10 : 0)
            .padding(.vertical, tile ? 10 : 6)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
        let more = IconButton(symbol: .driveMore, label: "Folder options", tint: GlamoStyle.accent, glass: true) {
            options = .folder(entry)
        }
        return Group {
            if tile {
                ZStack(alignment: .topTrailing) {
                    open
                    more.padding(4)
                }
            } else {
                HStack(spacing: 2) {
                    open
                    more.padding(.trailing, 4)
                }
            }
        }
        .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.paper)
    }

    private func videoFiles(_ movies: [PracticeRecording], canUseGrid: Bool) -> some View {
        let isOverview = currentFolderID == nil && searchTerm.isEmpty
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
                    LazyVStack(spacing: 6) {
                        ForEach(entries) { movie in
                            fileCell(movie, queue: movies, tile: false)
                        }
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

    private var emptyFolder: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText("No videos here yet")
                .font(.glam(.title2, weight: .semibold)).accessibilityAddTraits(.isHeader)
            LocalizedText("Import videos from Files or Photos.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
            newFolderButton
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                LocalizedText("No matching files")
                    .font(.glam(.title3, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: searchTerm)
                    .font(.glam(.subheadline, weight: .semibold)).foregroundStyle(GlamoStyle.accent)
                    .lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                LocalizedText("Try a different name or file extension.")
                    .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { query = "" } label: {
                    LocalizedText("Clear search")
                }.buttonStyle(CompactActionStyle())
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize {
                Glyph(symbol: .search, size: 34, tint: GlamoStyle.accent)
                    .frame(width: 48, height: 48)
            }
        }
        .padding(16)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    private func fileCell(_ movie: PracticeRecording, queue: [PracticeRecording], tile: Bool, compactTile: Bool = false) -> some View {
        DriveFileCell(movie: movie, tile: tile, compactTile: compactTile, play: {
            searchFocused = false
            play(movie, queue)
        }, options: { options = .file(movie) })
    }
}

struct DriveFileCell: View {
    let movie: PracticeRecording
    var tile = false
    var compactTile = false
    var detail: String? = nil
    let play: () -> Void
    var options: (() -> Void)? = nil

    var body: some View {
        if let options {
            DriveBrowserFileCard(movie: movie, tile: tile, compactTile: compactTile, detail: detail,
                                 play: play, options: options)
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
    @State private var measuredDuration: Double?
    let movie: PracticeRecording
    let tile: Bool
    let compactTile: Bool
    let detail: String?
    let play: () -> Void
    let options: () -> Void

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
        return ZStack(alignment: .topTrailing) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 0) {
                    GlamoStyle.raised
                        .aspectRatio(compactTile ? 16.0 / 9.0 : 8.0 / 5.0, contentMode: .fit)
                        .frame(minHeight: 80)
                        .overlay { DriveThumbnail(movie: movie) }
                        .overlay(alignment: .bottomLeading) {
                            previewLabel.padding(7)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        metadata
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
            moreButton.padding(4)
        }
        .clipShape(shape)
        .glamoGlass(in: shape, tint: GlamoStyle.surface, mediaBackdrop: true)
    }

    private var listCard: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                  : AnyLayout(HStackLayout(spacing: 10))
        return HStack(spacing: 2) {
            Button(action: play) {
                layout {
                    DriveThumbnail(movie: movie)
                        .frame(width: 82, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        title
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { listMetadata }
                            VStack(alignment: .leading, spacing: 4) { listMetadata }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 8).padding(.vertical, 6)
                .frame(minHeight: 66)
                .contentShape(Rectangle())
            }.buttonStyle(PressStyle())
            moreButton.padding(.trailing, 4)
        }
        .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.surface)
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

    @ViewBuilder private var listMetadata: some View {
        if let time {
            Text(verbatim: time)
                .font(.glam(.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(GlamoStyle.accent)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(GlamoStyle.paperMuted, in: Capsule())
        }
        metadata
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
        IconButton(symbol: .driveMore, label: "File options", tint: GlamoStyle.accent, glass: true, action: options)
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

struct DriveRecentView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    let play: (PracticeRecording, [PracticeRecording]) -> Void
    let browse: () -> Void

    var body: some View {
        let recent = library.movies.filter { $0.viewing != nil }.sorted {
            ($0.viewing?.date ?? .distantPast) > ($1.viewing?.date ?? .distantPast)
        }
        let featured = recent.first { movie in
            movie.viewing.map(canResume) == true
        } ?? recent.first
        GeometryReader { container in
            let showsGrid = container.size.width >= 360 && !typeSize.isAccessibilitySize
                && !driveHasReservedRegion(container)
            ScrollView {
                if let movie = featured, let position = movie.viewing {
                    let history = recent.filter { $0.id != movie.id }
                    VStack(alignment: .leading, spacing: 16) {
                        DrivePageTitle(title: "Recent")
                        featuredPlayback(movie, position: position, queue: recent)
                        if !history.isEmpty {
                            playbackHistory(history, queue: recent, showsGrid: showsGrid)
                        }
                    }.glamoPage()
                } else {
                    DriveTabEmptyState(artwork: "DriveRecentArtwork", paneWidth: container.size.width,
                                       title: "No playback history", message: "Play a file to find it here later.",
                                       browse: browse) {
                        DrivePageTitle(title: "Recent")
                    }
                }
            }
        }.glamoScreenBackground()
    }

    private func canResume(_ position: FileViewingPosition) -> Bool {
        position.seconds > 0 && position.seconds < position.duration - 1
    }

    private func featuredPlayback(_ movie: PracticeRecording, position: FileViewingPosition,
                                  queue: [PracticeRecording]) -> some View {
        let resumes = canResume(position)
        return Button { play(movie, queue) } label: {
            VStack(alignment: .leading, spacing: 0) {
                DriveThumbnail(movie: movie).aspectRatio(16.0 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: movie.displayName).font(.glam(.title3, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if resumes {
                        DriveMeter(value: position.seconds / position.duration, tint: .orange, thickness: 5)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            playLabel(resumes: resumes)
                            Spacer(minLength: 0)
                            playbackStatus(position, resumes: resumes)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            playLabel(resumes: resumes)
                            playbackStatus(position, resumes: resumes)
                        }
                    }
                }.padding(10)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(GlamoStyle.ink)
            .glamoGlass(in: RoundedRectangle(cornerRadius: 22), tint: GlamoStyle.surface)
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(PressStyle())
    }

    private func playLabel(resumes: Bool) -> some View {
        Label {
            LocalizedText(resumes ? "Continue playing" : "Play")
                .font(.glam(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Glyph(symbol: .play, size: 16, tint: GlamoStyle.accent)
        }
        .foregroundStyle(GlamoStyle.accent)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(minHeight: 44)
        .glamoGlass(in: Capsule(), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
    }

    private func playbackStatus(_ position: FileViewingPosition, resumes: Bool) -> some View {
        Group {
            if resumes {
                Text(verbatim: "\(durationLabel(position.seconds)) / \(durationLabel(position.duration))")
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
            } else {
                LocalizedText("Last played")
            }
        }.font(.glam(.footnote)).foregroundStyle(GlamoStyle.secondary)
    }

    private func playbackHistory(_ history: [PracticeRecording], queue: [PracticeRecording],
                                 showsGrid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText("Playback history").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            if showsGrid {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(history) { historyCell($0, queue: queue, tile: true) }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(history) { movie in
                        historyCell(movie, queue: queue, tile: false)
                        Divider().overlay(GlamoStyle.line)
                    }
                }
            }
        }
    }

    private func historyCell(_ movie: PracticeRecording, queue: [PracticeRecording], tile: Bool) -> some View {
        DriveFileCell(movie: movie, tile: tile, compactTile: true, detail: movie.viewing?.date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        ), play: { play(movie, queue) })
    }
}

struct DriveActivityView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @State private var filter = "All"
    let play: (PracticeRecording, [PracticeRecording]) -> Void
    let browse: () -> Void

    var body: some View {
        let movies = library.movies.filter { filter == "All" || $0.isExport == (filter == "Exports") }
        let latestExport = movies.lazy.filter(\.isExport).max { $0.date < $1.date }
        GeometryReader { container in
            ScrollView {
                if movies.isEmpty {
                    DriveTabEmptyState(artwork: library.importingVideo ? nil : "DriveActivityArtwork",
                                       paneWidth: container.size.width,
                                       title: "No files in this view", message: "Imports and exports appear here.",
                                       browse: browse) {
                        VStack(alignment: .leading, spacing: 12) {
                            activityHeader
                            importFailures
                        }
                    }
                } else {
                    let otherFiles = movies.filter { $0.id != latestExport?.id }
                    VStack(alignment: .leading, spacing: 17) {
                        activityHeader
                        if let latestExport { exportSummary(latestExport, queue: movies) }
                        importFailures
                        if !otherFiles.isEmpty {
                            LazyVStack(spacing: 0) {
                                ForEach(otherFiles) { movie in
                                    DriveFileCell(movie: movie, detail: movie.date.formatted(
                                        Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
                                    ), play: { play(movie, movies) })
                                    Divider().overlay(GlamoStyle.line)
                                }
                            }
                        }
                    }.glamoPage()
                }
            }
        }.glamoScreenBackground()
    }

    private var activityHeader: some View {
        VStack(alignment: .leading, spacing: 17) {
            DrivePageTitle(title: "Activity")
            if library.importingVideo || library.fileImport != nil {
                batchStatus(library.fileImport)
            }
            ChipFilter(values: ["All", "Imports", "Exports"], selected: filter) { filter = $0 }
        }
    }

    private func batchStatus(_ batch: VideoImportBatch?) -> some View {
        let progress = batch.map { Double($0.processed) / Double(max($0.total, 1)) }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Glyph(symbol: .driveActivity, size: 18, tint: GlamoStyle.accent)
                LocalizedText(library.importingVideo ? "Importing…" : "Import results")
                    .font(.glam(.headline)).accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if library.importingVideo {
                    if let progress {
                        Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                            .font(.glam(.title2, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(GlamoStyle.accent)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Image("GlamoLoadingMark").resizable().scaledToFit()
                            .frame(width: 32, height: 6).accessibilityHidden(true)
                    }
                }
            }
            if let batch, let progress {
                if library.importingVideo {
                    DriveMeter(value: progress, thickness: 6)
                    if !batch.currentName.isEmpty {
                        Text(verbatim: batch.currentName).font(.glam(.caption))
                            .foregroundStyle(GlamoStyle.secondary).lineLimit(2)
                    }
                }
                let failureCount = batch.failures.count
                LocalizedText("%@ of %@ files imported",
                              max(0, batch.processed - failureCount).formatted(.number.locale(locale)),
                              batch.total.formatted(.number.locale(locale)))
                    .font(.glam(.subheadline, weight: .semibold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if failureCount > 0 {
                    LocalizedText("%@ failed", failureCount.formatted(.number.locale(locale)))
                        .font(.glam(.footnote, weight: .semibold)).foregroundStyle(GlamoStyle.danger)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paper)
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

    @ViewBuilder
    private var importFailures: some View {
        if let failures = library.fileImport?.failures, !failures.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: failure.name).font(.glam(.footnote, weight: .semibold))
                        ErrorNote(message: failure.message)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .glamoCard(radius: 16, fill: GlamoStyle.surface)
        }
    }
}

private struct DriveTabEmptyState<Header: View>: View {
    let artwork: String?
    let paneWidth: CGFloat
    let title: String
    let message: String
    let browse: () -> Void
    @ViewBuilder let header: () -> Header
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let artworkWidth = artwork != nil && !typeSize.isAccessibilitySize
            ? min(paneWidth, verticalSizeClass == .compact ? 280 : 480) : 0
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
                if let artwork, artworkWidth > 0 {
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
                    Label { LocalizedText("Browse files") } icon: {
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
        LocalizedText(title).font(.glam(.largeTitle, weight: .semibold)).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
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

struct DriveItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    let item: DriveItem
    let pausePlayback: () -> Void
    @State private var mode: Mode = .actions
    @State private var editing = false
    @State private var paywall = false
    @State private var share: SharedFile?
    @State private var sharing = false
    @State private var shareByteCount: Int64?
    @State private var shareError: String?
    @State private var error: String?

    private enum Mode: Equatable { case actions, rename, move, remove }

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

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                sheetHeader
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 4)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sheetContent
                    }
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 24)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(drivePaneMargins(in: container))
        }
        .glamoScreenBackground()
        .allowsHitTesting(!sharing)
        .interactiveDismissDisabled(sharing)
        .sheet(isPresented: $editing) {
            if case .file(let movie) = current { EditorSheet(initialMovie: movie) }
        }
        .sheet(isPresented: $paywall) { MembershipView(requiredBenefit: .mediaExport) }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
    }

    @ViewBuilder private var sheetHeader: some View {
        if mode == .actions {
            SheetHeading(title: optionsTitle, inset: false) { dismiss() }
        } else {
            HStack {
                IconButton(symbol: .back, label: "Back", glass: true) {
                    mode = .actions
                    error = nil
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var sheetContent: some View {
        switch mode {
        case .actions:
            if case .file(let file) = current, sharing || shareError != nil || share != nil {
                shareStatus(for: file)
            } else {
                itemSummary
                    .padding(14)
                    .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
            }
            if case .file(let file) = current {
                fileActions(file)
            }
            errorMessage
            managementActions
            option("Delete local copy", glyph: .close, tint: GlamoStyle.danger) { mode = .remove }
                .background(GlamoStyle.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        case .rename:
            DriveNameForm(title: "Rename", startingName: currentName) { name in
                switch current {
                case .file(let file): try library.renameFile(file.id, to: name)
                case .folder(let folder): try library.renameFolder(folder.id, to: name)
                }
                mode = .actions
            }
            errorMessage
        case .move:
            movePanel
        case .remove:
            removalPanel
        }
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

    @ViewBuilder private func fileActionButtons(_ file: PracticeRecording) -> some View {
        if !file.isAudio {
            Button {
                pausePlayback()
                editing = true
            } label: {
                Label { LocalizedText("Edit video") } icon: {
                    Glyph(symbol: .edit, size: 17, tint: GlamoStyle.onAccent)
                }
            }
            .buttonStyle(GlamoActionStyle())
        }
        Button {
            shareFile(file)
        } label: {
            Label { LocalizedText(shareError == nil ? "Share file" : "Try again") } icon: {
                Glyph(symbol: .driveShare, size: 17, tint: file.isAudio && !sharing ? GlamoStyle.onAccent : GlamoStyle.accent)
            }
        }
        .buttonStyle(GlamoActionStyle(primary: file.isAudio))
        .disabled(sharing)
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
            option("Rename", glyph: .edit, showsArrow: true) { mode = .rename }
            Divider().overlay(GlamoStyle.line).padding(.horizontal, 12)
            option("Move to folder", glyph: .driveFolder, showsArrow: true) { mode = .move }
        }
        .glamoGlass(in: RoundedRectangle(cornerRadius: 16), tint: GlamoStyle.surface)
    }

    private var movePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            DrivePageTitle(title: "Move to folder")
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

    private var moveSummary: some View {
        let folderID = switch current {
        case .file(let file): file.folderID
        case .folder(let folder): folder.parentID
        }
        return VStack(alignment: .leading, spacing: 10) {
            itemSummary
            Divider().overlay(GlamoStyle.line)
            VStack(alignment: .leading, spacing: 3) {
                LocalizedText("Current location")
                    .font(.glam(.caption, weight: .semibold)).foregroundStyle(GlamoStyle.secondary)
                Text(verbatim: movePath(library.folderPath(to: folderID)))
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
            DrivePageTitle(title: details.title)
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

            if !details.containsItems { errorMessage }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { removalActions }
                VStack(spacing: 8) { removalActions }
            }
        }
    }

    @ViewBuilder private var removalActions: some View {
        ActionButton(title: "Cancel", primary: false) { mode = .actions }
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
                .foregroundStyle(GlamoStyle.onAccent)
                .background(GlamoStyle.danger, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    @ViewBuilder private var errorMessage: some View {
        if let error { ErrorNote(message: error) }
    }

    private var removalDetails: (title: String, explanation: String, containsItems: Bool) {
        switch current {
        case .file:
            return ("Delete local copy", "This deletes the file from Glamo. Any original in Photos or Files stays there.", false)
        case .folder(let folder):
            let containsItems = library.movies.contains { $0.folderID == folder.id }
                || library.folders.contains { $0.parentID == folder.id }
            let explanation = containsItems
                ? (error ?? "Move the files and folders out before deleting this folder.")
                : "The empty folder will be removed from Glamo."
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
                    Glyph(symbol: .back, size: 12, tint: GlamoStyle.secondary).rotationEffect(.degrees(180))
                }
            }.foregroundStyle(tint).padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 50)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    private func destination(_ target: MoveDestination?) -> some View {
        let folderID = target?.id
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
                LocalizedText("Move here")
                    .font(.glam(.footnote, weight: .semibold)).foregroundStyle(GlamoStyle.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: !usesStackedLayout, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(GlamoStyle.accent.opacity(0.09), in: Capsule())
            }
            .padding(.leading, 12 + indent).padding(.trailing, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
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
            do { share = SharedFile(url: try await library.shareFile(for: file, commerce: commerce)) }
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
                ScrollView {
                    DriveNameForm(title: title, startingName: startingName, creatingFolder: true) { name in
                        try save(name)
                        dismiss()
                    }
                    .pageHorizontalMargins().padding(.top, 8).padding(.bottom, 24)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(drivePaneMargins(in: container))
        }.glamoScreenBackground()
    }
}

private struct DriveNameForm: View {
    let title: String
    let creatingFolder: Bool
    let save: (String) throws -> Void
    private let startingName: String
    @State private var name: String
    @State private var error: String?

    init(title: String, startingName: String, creatingFolder: Bool = false, save: @escaping (String) throws -> Void) {
        self.title = title
        self.startingName = startingName
        self.creatingFolder = creatingFolder
        self.save = save
        _name = State(initialValue: startingName)
    }

    private var nameIsEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if creatingFolder {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Glyph(symbol: .driveFolder, size: 19, tint: GlamoStyle.accent)
                            .frame(width: 34, height: 34)
                            .background(GlamoStyle.paper, in: RoundedRectangle(cornerRadius: 9))
                        LocalizedText("Folder name").font(.glam(.subheadline, weight: .semibold))
                    }
                    nameField
                    if let error { ErrorNote(message: error) }
                }
                .padding(14)
                .glamoGlass(in: RoundedRectangle(cornerRadius: 20), tint: GlamoStyle.paperMuted, mediaBackdrop: true)
            } else {
                DrivePageTitle(title: title)
                renameFields
            }
            ActionButton(title: creatingFolder ? "Create folder" : "Save", action: commit)
                .disabled(nameIsEmpty)
        }
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
                .onChange(of: name) { _, _ in error = nil }
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
            .glamoField().onSubmit(commit)
    }

    private func commit() {
        error = nil
        do { try save(name) }
        catch { self.error = error.localizedDescription }
    }
}

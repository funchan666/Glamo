import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct DriveBrowser: View {
    private enum ImportSource { case files, photos }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .footnote) private var inlineToolbarWidth: CGFloat = 350
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
                    browserTop(artworkWidth: showsArtwork ? artworkWidth : nil)
                    VStack(alignment: .leading, spacing: 8) {
                        if !library.movies.isEmpty || !library.folders.isEmpty || !query.isEmpty || searchFocused {
                            fileToolbar(inline: paneWidth >= inlineToolbarWidth && !typeSize.isAccessibilitySize,
                                        showsControls: !movies.isEmpty || (searchTerm.isEmpty && !folders.isEmpty),
                                        canUseGrid: canUseGrid)
                        }
                        importStatus
                        if !searchTerm.isEmpty {
                            LocalizedText("Search results").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
                        }
                        if !folders.isEmpty { folderShelf(folders) }
                        if !hasFilesOrFolders {
                            emptyFolder
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

    private func browserTop(artworkWidth: CGFloat?) -> some View {
        let artworkHeight = (artworkWidth ?? 0) * 0.44
        let overlapFraction: CGFloat = 0.13

        return VStack(spacing: 0) {
            VStack(spacing: 18) {
                header
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
            if let folder {
                IconButton(symbol: .back, label: "Parent folder", glass: true) {
                    currentFolderID = folder.parentID
                    query = ""
                    searchFocused = false
                }
                Text(verbatim: folder.name)
                    .font(.glam(.largeTitle, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            } else {
                LocalizedText("Files").font(.glam(.largeTitle, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
        }.fixedSize(horizontal: false, vertical: true)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SheetHeading(title: "Import videos", inset: false) { choosingImportSource = false }
                Button { chooseImportSource(.files) } label: {
                    Label { LocalizedText("Import from Files") } icon: {
                        Glyph(symbol: .driveFolder, size: 17, tint: GlamoStyle.onAccent)
                    }
                }.buttonStyle(GlamoActionStyle()).accessibilityIdentifier("video.importFiles")
                Button { chooseImportSource(.photos) } label: {
                    Label { LocalizedText("Choose from Photos") } icon: {
                        Glyph(symbol: .feed, size: 17, tint: GlamoStyle.accent)
                    }
                }.buttonStyle(GlamoActionStyle(primary: false)).accessibilityIdentifier("video.importPhotos")
            }.glamoPage()
        }.glamoScreenBackground().presentationDetents([.medium, .large])
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
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        return layout {
            searchField(compact: inline && showsControls && !searchFocused)
                .frame(minWidth: inline ? 88 : nil)
            if showsControls, !searchFocused {
                browserControls(canUseGrid: canUseGrid)
                    .layoutPriority(1)
            }
        }
    }

    private func searchField(compact: Bool) -> some View {
        let prompt = compact ? "Search" : "Search files and folders"
        return HStack(spacing: 7) {
            Glyph(symbol: .search, size: 17, tint: GlamoStyle.secondary).padding(.leading, 13)
            TextField("Search files and folders", text: $query,
                      prompt: Text(LocalizedStringKey(prompt)).foregroundColor(GlamoStyle.secondary))
                .focused($searchFocused)
                .font(.glam(.subheadline)).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { searchFocused = false }
                .frame(minHeight: 44)
            if !query.isEmpty {
                IconButton(symbol: .close, label: "Clear search") { query = "" }
            }
        }
        .padding(.trailing, 5)
        .glamoCard(radius: 16)
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

    private func browserControls(canUseGrid: Bool) -> some View {
        HStack(spacing: 4) {
            if searchTerm.isEmpty {
                IconButton(symbol: .driveAdd, label: "New folder", glass: true) { showNewFolder = true }
            }
            Button { sortByName.toggle() } label: {
                LocalizedText(sortByName ? "Name A–Z" : "Newest first")
            }.buttonStyle(CompactActionStyle())
                .accessibilityHint(Text("Change file sort order"))
            if canUseGrid {
                IconButton(symbol: useGrid ? .driveList : .driveGrid, label: useGrid ? "List view" : "Grid view",
                           glass: true) { useGrid.toggle() }
            }
        }
    }

    private func folderShelf(_ entries: [VideoFolder]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if searchTerm.isEmpty {
                LocalizedText("Folders").font(.glam(.headline)).accessibilityAddTraits(.isHeader)
            }
            if currentFolderID == nil, searchTerm.isEmpty, !typeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(entries) { folderCell($0).frame(width: 156) }
                    }.padding(.vertical, 2)
                }.scrollIndicators(.hidden)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 254 : 150), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 10) {
                    ForEach(entries) { folderCell($0) }
                }
            }
        }
    }

    private func folderCell(_ entry: VideoFolder) -> some View {
        HStack(spacing: 2) {
            Button {
                currentFolderID = entry.id
                query = ""
                searchFocused = false
            } label: {
                HStack(spacing: 8) {
                    Glyph(symbol: .driveFolder, size: 20, tint: GlamoStyle.accent)
                    Text(verbatim: entry.name).font(.glam(.subheadline, weight: .semibold))
                        .multilineTextAlignment(.leading).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 10).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(PressStyle())
            IconButton(symbol: .driveMore, label: "Folder options") { options = .folder(entry) }
        }.glamoGlass(in: RoundedRectangle(cornerRadius: 14), tint: GlamoStyle.paper)
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
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(entries) { fileCell($0, queue: movies, tile: true, compactTile: isOverview) }
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { movie in
                            fileCell(movie, queue: movies, tile: false)
                            Divider().overlay(GlamoStyle.line)
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
            LocalizedText(searchTerm.isEmpty ? "No videos here yet" : "No matching files")
                .font(.glam(.title2, weight: .semibold)).accessibilityAddTraits(.isHeader)
            LocalizedText(searchTerm.isEmpty ? "Import videos from Files or Photos." : "Try a different name or file extension.")
                .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
            if searchTerm.isEmpty {
                Button { showNewFolder = true } label: {
                    LocalizedText("New folder")
                }.buttonStyle(CompactActionStyle())
            }
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
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
        if tile {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 0) {
                    DriveThumbnail(movie: movie)
                        .aspectRatio(compactTile ? 2 : 1.58, contentMode: .fit)
                        .overlay(alignment: .bottomTrailing) { playMark.padding(8) }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    fileName
                        .padding(.trailing, options == nil ? 0 : 44)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .overlay(alignment: .bottomTrailing) {
                if let options { IconButton(symbol: .driveMore, label: "File options", action: options) }
            }
        } else {
            HStack(spacing: 6) {
                Button(action: play) {
                    HStack(spacing: 11) {
                        DriveThumbnail(movie: movie).frame(width: 70, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        fileName
                        if options == nil { Glyph(symbol: .play, size: 14, tint: GlamoStyle.accent) }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }.buttonStyle(PressStyle())
                if let options { IconButton(symbol: .driveMore, label: "File options", action: options) }
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

private struct DriveFileMetadata: View {
    let movie: PracticeRecording
    let detail: String?
    @Environment(\.locale) private var locale
    var body: some View {
        let format = movie.fileExtension.uppercased()
        let size = movie.byteCount.map { $0.formatted(.byteCount(style: .file).locale(locale)) }
        let duration = movie.duration.map(durationLabel)
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
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    let item: DriveItem
    let pausePlayback: () -> Void
    @State private var mode: Mode = .actions
    @State private var editing = false
    @State private var paywall = false
    @State private var share: SharedFile?
    @State private var sharing = false
    @State private var error: String?

    private enum Mode: Equatable { case actions, rename, move, remove }

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

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading {
                if mode == .actions { dismiss() }
                else { mode = .actions; error = nil }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch mode {
                    case .actions:
                        if case .file(let movie) = current {
                            DriveThumbnail(movie: movie).aspectRatio(2.5, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        Text(verbatim: currentName).font(.glam(.title2, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        actionRows
                    case .rename:
                        DriveNameForm(title: "Rename", startingName: currentName) { name in
                            switch current {
                            case .file(let file): try library.renameFile(file.id, to: name)
                            case .folder(let folder): try library.renameFolder(folder.id, to: name)
                            }
                            mode = .actions
                        }
                    case .move:
                        DrivePageTitle(title: "Move to folder")
                        VStack(spacing: 0) {
                            destination("Files", folderID: nil)
                            ForEach(library.folders.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { folder in
                                if canMove(into: folder.id) {
                                    Divider().overlay(GlamoStyle.line)
                                    let path = library.folderPath(to: folder.id).map(\.name).joined(separator: " / ")
                                    destination(path, folderID: folder.id)
                                }
                            }
                        }.glamoCard(radius: 14)
                    case .remove:
                        DrivePageTitle(title: "Delete local copy")
                        Text(verbatim: currentName).font(.glam(.subheadline))
                        LocalizedText(removalExplanation)
                            .font(.glam(.subheadline)).foregroundStyle(GlamoStyle.secondary)
                        ActionButton(title: "Delete local copy") {
                            perform {
                                switch current {
                                case .file(let file): library.delete(file)
                                case .folder(let folder): try library.removeFolder(folder.id)
                                }
                                dismiss()
                            }
                        }
                        ActionButton(title: "Cancel", primary: false) { mode = .actions }
                    }
                    if let error { ErrorNote(message: error) }
                }.glamoPage()
            }
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

    private var actionRows: some View {
        VStack(spacing: 0) {
            if case .file(let file) = current {
                if !file.isAudio {
                    option("Edit video", glyph: .edit) {
                        pausePlayback()
                        editing = true
                    }
                    Divider().overlay(GlamoStyle.line)
                }
                option(sharing ? "Preparing export…" : "Share file", glyph: .driveShare) { shareFile(file) }
                Divider().overlay(GlamoStyle.line)
            }
            option("Rename", glyph: .edit) { mode = .rename }
            Divider().overlay(GlamoStyle.line)
            option("Move to folder", glyph: .driveFolder) { mode = .move }
            Divider().overlay(GlamoStyle.line)
            option("Delete local copy", glyph: .close, tint: GlamoStyle.danger) { mode = .remove }
        }.glamoCard(radius: 14)
    }

    private var removalExplanation: String {
        switch current {
        case .file: "This deletes the file from Glamo. Any original in Photos or Files stays there."
        case .folder: "Only empty folders can be deleted."
        }
    }

    private func option(_ title: String, glyph: GlamoGlyph, tint: Color = GlamoStyle.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Glyph(symbol: glyph, size: 18, tint: tint)
                LocalizedText(title).font(.glam(.subheadline, weight: .medium))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.foregroundStyle(tint).padding(13).frame(minHeight: 48)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    private func destination(_ name: String, folderID: UUID?) -> some View {
        Button {
            perform {
                switch current {
                case .file(let file): try library.moveFile(file.id, into: folderID)
                case .folder(let folder): try library.moveFolder(folder.id, into: folderID)
                }
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Glyph(symbol: .driveFolder, size: 18, tint: GlamoStyle.accent)
                if folderID == nil { LocalizedText(name) }
                else { Text(verbatim: name) }
                Spacer(minLength: 0)
            }.font(.glam(.subheadline)).padding(13).frame(minHeight: 48)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    private func canMove(into folderID: UUID) -> Bool {
        guard case .folder(let folder) = current else { return true }
        return !library.folderPath(to: folderID).contains { $0.id == folder.id }
    }

    private func shareFile(_ file: PracticeRecording) {
        guard !sharing else { return }
        guard commerce.canExportMedia else {
            pausePlayback()
            paywall = true
            return
        }
        error = nil
        sharing = true
        Task {
            defer { sharing = false }
            do { share = SharedFile(url: try await library.shareFile(for: file, commerce: commerce)) }
            catch { self.error = error.localizedDescription }
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
        VStack(spacing: 0) {
            SheetHeading { dismiss() }
            ScrollView {
                DriveNameForm(title: title, startingName: startingName) { name in
                    try save(name)
                    dismiss()
                }.glamoPage()
            }
        }.glamoScreenBackground()
    }
}

private struct DriveNameForm: View {
    let title: String
    let save: (String) throws -> Void
    @State private var name: String
    @State private var error: String?

    init(title: String, startingName: String, save: @escaping (String) throws -> Void) {
        self.title = title
        self.save = save
        _name = State(initialValue: startingName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DrivePageTitle(title: title)
            TextField("Name", text: $name)
                .autocorrectionDisabled().submitLabel(.done)
                .glamoField().onSubmit(commit)
            if let error { ErrorNote(message: error) }
            ActionButton(title: "Save", action: commit)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commit() {
        error = nil
        do { try save(name) }
        catch { self.error = error.localizedDescription }
    }
}

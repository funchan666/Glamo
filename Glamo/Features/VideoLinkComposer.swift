import SwiftUI

// Shared search presentation and help. The search field lives in DriveBrowser.
struct VideoSearchRequest: Identifiable {
    let id = UUID()
    let query: String
}

struct VideoSearchGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    FeatureRow(symbol: .search, title: "Search your files", detail: "Enter a file or folder name to filter your library as you type.")
                    FeatureRow(symbol: .link, title: "Copy the URL", detail: "Copy the video URL from the share menu or the address bar.")
                    FeatureRow(symbol: .edit, title: "Paste it here", detail: "Paste the video URL or code into the search field, then tap Search. Keep uppercase and lowercase letters exactly as shared.")
                    FeatureRow(symbol: .play, title: "Choose a video", detail: "Choose a video from the list to play. Open a folder to see its videos.")
                    ActionButton(title: "Got it") { dismiss() }
                }.glamoPage()
            }
        }.glamoScreenBackground()
    }
}

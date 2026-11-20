# Ecloud

Ecloud is a local video library for iPhone. Import videos from Files or Photos, organize them in folders, and browse by name or date in grid or list view. Files supports selecting multiple videos.

Open a file to play it. The player shares its queue and position with the in-app mini player. Recent shows watched files and resumes unfinished playback. Activity shows local import results and files produced by the editor.

The Files tab also has the original video URL field. Shared URLs and short codes open the existing online player through the guest session and viewing allowance. The former discovery catalog, makeup tools, and online downloads have been removed.

Open `Glamo.xcodeproj` and select the shared `Glamo` scheme. The minimum deployment target is iOS 17. The Duo layout paths use the iOS 27.1 SDK. The app supports portrait and landscape.

## Storage and purchases

- Imported videos are copied into the app's local library. Existing files are read from the same index. Folders, file names, and viewing positions live in that index.
- Ecloud Plus removes ads. The first release design also includes up to 10 TB of cloud storage and previews of unsaved shared photos and videos. Those two benefits depend on the cloud drive service. Open Plus to see available plans and restore purchases.
- Purchase configuration remains on the test environment. Product metadata and local prices are supplied by StoreKit.

## Verification

Source, project settings, asset references and localization tables were reviewed. Builds, import and playback on iPhone, rotation and folding behavior, and Apple Sandbox transactions remain to be verified.

# LocalDrop for iOS 26 (SwiftUI)

Native iOS 26 / Liquid Glass client for your existing `server.py`. **server.py and index.html are not changed**:
keep running `server.py` on your PC and the web version keeps working next to the app.

## Build

**Option A (XcodeGen):** `brew install xcodegen && xcodegen generate && open LocalDrop.xcodeproj` (Xcode 26).

**Option B (manual):** New Xcode 26 project -> iOS App (SwiftUI, Swift) named LocalDrop, delete the template
`ContentView`/`App` files, drag in the `LocalDrop/` folder, set the deployment target to iOS 26, and add these
Info.plist keys (they are listed in `project.yml`):

- `NSLocalNetworkUsageDescription` (the app talks to your PC on the LAN)
- `NSAppTransportSecurity` > `NSAllowsLocalNetworking` = YES (server.py is plain http). If you reach the PC through a
  custom DNS name instead of an IP / `.local` name, add an ATS exception for that host.
- `NSPhotoLibraryAddUsageDescription` (share sheet "Save Image")

Language mode is Swift 5. First launch: enter the address server.py prints next to "Network:" (e.g. `192.168.1.20:8000`).

## Moving your web photos and private files into the app

The server recognises a device by its IP and by the `ld_id` cookie. The app sends its own `ld_id` and lets you change it:

1. Web version -> **Shared** -> **Your Cookie ID** -> eye icon -> **Copy**.
2. App -> **Settings -> Cookie ID & transfer -> Use a different Cookie ID...** -> **Paste** -> **Use this Cookie ID**
   (or paste it on the first-run screen under "Transfer from the web version").
3. The app switches immediately and reports what it found (private files, private photo library, shared folders).
   The previous ID is kept under "Previously used" so you can switch back.

Nothing is copied: both clients now read the same server-side space. Treat the ID like a password.

## Web feature -> app mapping

| Web | App |
|---|---|
| Files | Files tab: upload (Files app or Photos), search, preview, download/share, delete |
| AirDrop | AirDrop tab: device name, live device grid, send, incoming sheet (Download / Exclusive ID / Cloud / Ignore) |
| Only me | Only me tab: Cookie ID or Local IP mode |
| Photos | Photos tab: Shared / Only You / Only Members / shared-with-you spaces, day grouping, Library + Albums, select, add to album, members + invites, EXIF date/camera/size |
| Viewer | Swipe paging, pinch + double-tap zoom, drag-down dismiss, hero zoom transition, share original, delete, media backdrop |
| Custom player | Glass controls: seek + buffer, +/-10s, volume, speed, audio boost, fill/fit, auto-hide, keyboard shortcuts |
| Shared | Shared tab: IDs, folders, files, members, invites |
| Settings | Theme, accent, show dates, media backdrop, custom player, button effects, animations, reset, server, device name, Cookie ID |

Left out on purpose: Liquid Glass / WebGL glass settings (iOS 26 provides it natively) and "Install as an app" / HTTPS
certificate helpers (not applicable to a native app).

## Notes

- Videos AVPlayer can't decode (MKV, AVI, ...) are requested with `?inline=1` so the server's ffmpeg transcode is used;
  MP4/MOV/M4V/3GP (including HEVC) play directly. Downloads always fetch the original.
- Audio boost uses an `AVAudioMix` gain (iOS can cap this on some outputs). "Fullscreen" becomes fill/fit because the viewer is already full-screen.
- Written without access to a Swift compiler, so expect to fix a few small compile errors on the first build.

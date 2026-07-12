# Release checklist · App Store 发布清单

This file documents everything needed to ship Gaber to the App Store, so a release can be reproduced by anyone with access to the publishing Apple Developer account.

## 1. Identity & signing · 账号与签名

The original project was created with a personal placeholder identity. For App Store distribution the target must use the publishing account's values (set in `timer.xcodeproj` → target **timer** → Signing & Capabilities):

| Setting | Development (original) | App Store release |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `gabriel.timer` | reverse-DNS ID registered to the publishing team |
| `DEVELOPMENT_TEAM` | personal team | publishing team ID |
| Signing | Automatic | Automatic (with ASC API key for CI) |

> The bundle ID is permanent once the first build is uploaded — pick deliberately.

## 2. Versioning · 版本号

- `MARKETING_VERSION` — user-facing `MAJOR.MINOR.PATCH` (e.g. `1.0.0`).
- `CURRENT_PROJECT_VERSION` — build number, an always-increasing integer. Bump on **every** upload.

## 3. Info.plist / compliance · 合规项

- `UIBackgroundModes` = `audio` — this is the "Audio, AirPlay, and Picture in Picture" capability that keeps the PiP clock rendering in the background. Do not remove it.
- `ITSAppUsesNonExemptEncryption` = `NO` — the app contains no custom encryption; declaring it in the plist skips the export-compliance question on every upload.
- `PrivacyInfo.xcprivacy` — the app itself uses `UserDefaults` (via `@AppStorage`), a *required-reason API*. The privacy manifest declares category `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (app's own preferences). No data is collected, no tracking.

## 4. App Review notes · 审核要点

The floating clock is implemented with the **system Picture-in-Picture API** rendering a live sample-buffer stream. Some floating-clock apps have faced questions under Guideline 2.5.1 (APIs used for their intended purpose). Mitigations that should ship with every submission:

- In **App Review notes**, explain (in English): the app renders a live clock as video frames into the standard `AVPictureInPictureController` sample-buffer pipeline; PiP is user-initiated only (`canStartPictureInPictureAutomaticallyFromInline = false`); the audio session is `.mixWithOthers` and never audibly plays sound over other apps.
- Point the reviewer to the in-app button (开启跨 App 悬浮窗) and note that PiP requires a real device.
- Primary store locale: **Simplified Chinese**; include an English description as a secondary locale so reviewers understand the app.

## 5. Store assets · 商店素材

- App icon: 1024×1024, no alpha (already in `Assets.xcassets`).
- Screenshots: 6.9" iPhone (mandatory) — main screen + PiP floating over another app (shoot the PiP one on a real device).
- Privacy label: **Data Not Collected** (the app has no network code at all).

## 6. Upload · 上传

```bash
xcodebuild -project timer.xcodeproj -scheme timer -destination 'generic/platform=iOS' \
  -archivePath build/gaber.xcarchive archive
xcodebuild -exportArchive -archivePath build/gaber.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
# then upload build/export/*.ipa with Transporter, altool, or CI
```

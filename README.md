# CapMark

CapMark is a local-first macOS menu bar app for capturing a selected screen
region, annotating it, and passing it straight into your next task.

## Features

- Capture a rectangular screen region with a configurable global shortcut
- Add arrows, rectangles, highlights, freehand strokes, and text
- Copy, save, or drag annotated images into another app
- Keep a configurable local history of recent captures
- Run as a menu bar app without a Dock icon
- Keep screenshots and annotations on your Mac

## Requirements

- macOS 14 or later
- Screen Recording permission

## Install

Download the latest notarized ZIP from
[GitHub Releases](https://github.com/shogoisaji/CapMark/releases), extract it,
and move `CapMark.app` to Applications.

On first use, macOS asks for Screen Recording permission. Grant access to
CapMark in **System Settings → Privacy & Security → Screen & System Audio
Recording**.

## Development

CapMark uses [XcodeGen](https://github.com/yonaskolb/XcodeGen). Generate the
Xcode project and run the tests with:

```sh
brew install xcodegen
xcodegen generate
xcodebuild test \
  -project CapMark.xcodeproj \
  -scheme CapMark \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO
```

## Local release

Releases are built, Developer ID-signed, notarized, and packaged locally.
One-time setup:

```sh
xcrun notarytool store-credentials CapMarkNotary \
  --key /secure/path/AuthKey_<KEY_ID>.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

Create local release artifacts:

```sh
scripts/release-local.sh 1.0.0
```

Create an optional DMG as well (`brew install create-dmg` first):

```sh
scripts/release-local.sh 1.0.0 --dmg
```

With a clean worktree and an authenticated GitHub CLI, create and push the tag
and publish the artifacts to GitHub Releases:

```sh
scripts/release-local.sh 1.0.0 --publish
```

Signing overrides can be placed in `Config/Local.xcconfig`; this file is
ignored by Git.

## Privacy

CapMark processes captures locally. It does not upload screenshots or require
an account.

## License

MIT License. See [LICENSE](LICENSE).

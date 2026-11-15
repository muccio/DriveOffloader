# DriveOffloader

Native macOS 14+ (SwiftUI + AppKit) utility to analyze cold apps and folders, offload them to Google Drive via FileProvider cloud-only eviction and safe Offline Stubs, and inspect/clean system & developer caches.

## Features

- **Drive Offloader**:
  - Scans selected roots (e.g. `/Applications` or custom folders) with real APFS physical allocation sizes (`totalFileAllocatedSizeKey`) and heat/inactivity scoring (`Last Opened` / `Last Modified`).
  - Offloads selected bundles/folders to your Google Drive archive, tracks per-file cloud upload progress, and evicts local Google Drive FileProvider caches (`NSFileManager.evictUbiquitousItem` / `fileproviderctl materialize --evict`).
  - Replaces offloaded paths with **Offline Stubs** (`*.gdoffload` metadata stubs that do not trigger automatic Finder hover downloads) and provides a **Restore Manager** (`~/.driveoffloader_manifest.json`) to restore items locally anytime.
  - Supports single-prompt batch administrator authorization when moving/restoring `/Applications` bundles.

- **System Caches**:
  - Separate workspace tab (`Drive Offloader` | `System Caches`) to inspect safely cleanable macOS user caches, sandboxed container caches, Electron/IDE caches (`CachedData`, `Code Cache`, `GPUCache`), developer/package caches (`~/.npm`, `~/.gradle/caches`, `~/.cache/*`, Xcode `DerivedData` / `iOS DeviceSupport`), logs, `/Library/Caches`, and `~/.Trash`.
  - Classifies each target as `Safe` or `Review`, protects active Google Drive databases (`DriveFS/<account_id>`), Preferences, and Keychains, and supports Move to Trash or direct cleanup with confirmation.

## Build & Package

Requirements: macOS 14.0+, Xcode / Swift 5.10 toolchain.

```bash
./build_app.sh
```

This compiles the release binary via Swift Package Manager, generates `AppIcon.icns` and `Info.plist`, bundles `DriveOffloader.app`, and applies an ad-hoc signature (`codesign --force --deep --sign - DriveOffloader.app`).

To run:

```bash
open DriveOffloader.app
```

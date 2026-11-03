# Explorer ↔ Folders Pro 2.11.5 parity tracker

Legend: ✅ built and checked (unit test or rendered snapshot) · 🟡 built, not yet exercised end-to-end · ⬜ not built

The reference is `/Applications/Folders Pro.app` (com.minttype.folders-pro 2.11.5), plus its User's Guide and Keyboard Shortcuts pages.

## Window & views
| Feature | Status | Notes |
|---|---|---|
| Folder Tree with configurable sections (Favorites, Home, drives, network, remote, iCloud, Cloud storage, iOS, Recent, Tags, Ratings, Saved searches, Trash) | ✅ | default 253 pt width |
| Icons / List / Table / Gallery views, ⌘1–4 | ✅ | snapshots in `build/shots` |
| Archive view (name / modified / original / compressed / kind) | ✅ | |
| Toolbar order (sidebar, dup window/tab, back/fwd/up, title, new folder, view, sort, group, remember, search) | ✅ | |
| Path bar: interactive or string, top or bottom, ⇧⌘G with completions | 🟡 | |
| Status bar with progress stripe, pause/cancel | 🟡 | |
| Info panel: preview, dates, EXIF/GPS, media, tags, rating, comment, Open With, hidden/locked, permissions, custom icon | ✅ | rendered |
| Gallery tools: zoom, lock, backgrounds, flip/rotate, Live Text | 🟡 | |
| Shelf flap | 🟡 | |
| Grouping (kind/date/size/tags/rating) and folders first/last | ✅ | unit tests |
| Remember view options per folder (+ inherit to subfolders) | ✅ | unit tests |
| Tabs, Customize Tab, Tab Sets | 🟡 | |

## File operations
| Feature | Status | Notes |
|---|---|---|
| Copy/move with progress, pause, cancel | ✅ | unit tests |
| Conflicts: Skip / Keep Both / Replace / Replace Older / Merge, Apply to All | ✅ | unit tests |
| Undo/redo of every op (incl. swaps) | ✅ | unit tests |
| Trash plus private trash fallback | ✅ | |
| Cut via Trash / internal cut / cloud rule / clipboard-replaced warning | 🟡 | |
| Paste as symlinks/aliases, Paste into Folder, Move Item Here | ✅ (core) | |
| New folder / with selection / empty file / Office docs / from clipboard / via scriptable apps | ✅ (templates tested) | |
| Batch Rename (7 step types, preview, collisions) | ✅ | unit tests |
| Drag & drop with ⌥/⌘/⌃ rules | 🟡 | |
| Retry as Administrator (SMAppService helper → osascript fallback) | 🟡 | needs a team-signed build for the daemon path |

## Archives
| Feature | Status |
|---|---|
| zip / 7z / tar / tar.gz / bz2 / xz / tar.7z create, browse, extract, add, remove | ✅ |
| Password zip (AES-256) and 7z | ✅ |
| Single-file tar.* → .gz etc. | ✅ |
| rar, multi-volume 7z read | 🟡 |
| Filename encoding picker | 🟡 |

## Integrations
| Feature | Status |
|---|---|
| Spotlight / full-scan search, Save Search (.savedSearch) | ✅ (file format) / 🟡 UI |
| Network share discovery, mount, pin/hide/forget, remount pinned | 🟡 |
| Git badges + stage/unstage/discard/commit/pull/push | ✅ |
| Actions (shell / AppleScript, {path} {name} {stem} {dir}) | ✅ |
| CLI `explorer`, URL schemes, Services, AppleScript sdef, App Intents | ✅ (parsing) / 🟡 install |
| iOS devices over AFC (libimobiledevice loaded at runtime) | 🟡 needs `brew install libimobiledevice` |
| USB MTP devices: storage browsing, copy, mkdir, rename, permanent delete | 🟡 needs `brew install libmtp`, hardware validation pending. See [MTP support](MTP.md). |
| iCloud settings sync | 🟡 needs iCloud entitlement |
| Settings: 6 tabs with the guide's defaults | ✅ rendered |

## Intentionally different
- Name, icon, sounds and templates are original. Nothing is copied from the Folders Pro bundle.
- No Paddle licensing, trial, Sparkle updater or Sentry telemetry.
- Only English is localized.

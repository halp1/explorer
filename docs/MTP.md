# USB MTP devices

Explorer supports Android phones and other USB devices that expose storage through Media Transfer Protocol. MTP devices appear in the sidebar with their available storages as children.

## Setup

Install the optional native library:

```sh
brew install libmtp
```

Restart Explorer after installing. No Homebrew packages are required to build or launch Explorer without MTP support. The application loads the library at runtime from standard Apple Silicon or Intel Homebrew locations. It does not bundle libmtp or libusb.

Connect the device, unlock it, and select **File Transfer** or **MTP** in its USB settings. Some devices ask for permission on their screen. Close other applications that claim the same MTP device, including other Android file-transfer utilities.

The **MTP Devices** setting under sidebar preferences controls whether connected devices appear. A missing-library hint is shown there when libmtp is unavailable.

## Supported operations

- Browse device storage and nested folders in any file view.
- Navigate using Back, Forward, Up, breadcrumbs, or a new tab/window.
- Copy files or folders to the Mac using Copy and Paste or drag-out file promises.
- Copy local files and folders into a writable device storage using Paste, Paste into Folder, or drag and drop.
- Create folders and rename individual objects on writable storage.
- Permanently delete selected objects after confirmation.
- Open files or show Quick Look by downloading a temporary local copy.

All cross-device-boundary transfers are copies. A cut clipboard or a move modifier never removes the original local source. Existing names are kept and incoming items receive a unique name. This version does not merge folders or replace existing device content. Uploads containing symbolic links or special files are rejected before writing rather than following them outside the selected folder.

## Limits and recovery

MTP object handles belong to a connection session. Unplugging, reconnecting, or restarting Explorer invalidates old locations. Reopen the device from the sidebar instead of continuing an old tab or history entry. A locked or busy device may require unlocking, changing its USB mode, or closing another transfer application.

Device I/O runs on a serialized background queue. Transfers show progress and can be cancelled. Cancellation is cooperative and may wait for the current native call to return. Failed downloads are not exported as completed files. Explorer attempts to remove only partial uploads it created, but a disconnected device may retain partial content that must be removed after reconnecting.

Delete is permanent. There is no device Trash or undo for device mutations. Device and storage roots cannot be renamed or deleted. Read-only storages remain browsable but do not accept writes.

Opening a downloaded copy does not upload edits back to the device. Copy an edited file back explicitly if needed. Temporary Open, Quick Look, clipboard, and drag staging is private to Explorer and is not a mounted filesystem.

Device search, cut/move, device-to-device transfers, automatic edit upload, POSIX permissions, tags, batch rename, device favorites, local scripting, Finder/Terminal actions, and device archive editing are not supported. Views use device metadata and type icons instead of probing synthetic paths as local files.

## Validation

The test suite uses an injected transport to cover connection-scoped handles, storage and object identity, listing failures, transfer collisions, unsafe names, cancellation, symlink rejection, and partial-transfer cleanup. These tests do not simulate or prove USB compatibility with every device.

Physical-device checks remain necessary for storage discovery, internal storage and SD cards, recursive round-trip copies, file promises, preview downloads, cancellation, read-only storage, and unplug/reconnect during transfer. Record actual hardware results separately from automated test results.

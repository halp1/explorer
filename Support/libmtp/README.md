# Optional libmtp runtime

Explorer has no compile-time libmtp or libusb dependency. Install libmtp with Homebrew to enable Android MTP discovery. The bridge searches these runtime library locations:

- `/opt/homebrew/lib/libmtp.9.dylib`
- `/usr/local/lib/libmtp.9.dylib`

No library is bundled. [ABI declarations](<../../Sources/CMTP/libmtp_abi.h>) are a minimal subset of the [upstream public header](https://raw.githubusercontent.com/libmtp/libmtp/master/src/libmtp.h.in), verified on 2026-11-03. The copied declarations retain upstream copyright and LGPL version 2 or later licensing. The [upstream license](<COPYING>) is included.

Every native entry point is resolved before the library is used. A failed resolution closes the library. Device handles are opened uncached and retained until disconnect or a failed storage probe. Discovery does not reopen healthy handles. Serial numbers identify devices when available, with a USB bus and device fallback for missing or duplicate serials. A separate physical candidate map retains each open handle. Every open receives a fresh session UUID. Failed discovery invalidates all sessions. Transport connection errors invalidate the affected handle before queued writes can run. Storage and file listings cross the bridge only as owned copies. Listing uses the complete child handle array and individually fetches metadata for every handle. Missing metadata aborts the entire listing instead of silently skipping files. Every returned metadata node is individually destroyed after detaching its next pointer.

The Swift service uses an injected transport for deterministic service tests. Public synchronous operations are worker-thread APIs. Discovery and every native operation share one serial queue. `canWrite` reads a separately locked snapshot without queue synchronization.

Uploads reject symbolic links and special files during preflight, before creating objects. Transfers never delete local sources. Downloads are fully staged before publication, use anchored directory descriptors and exclusive rename, and do not replace existing files. Interrupted uploads roll back only newly reported object handles. A device that does not report the handle of a failed partial upload may leave that partial object on the device. Explorer does not guess its identity or delete unrelated objects.

import CoreServices
import Foundation

struct FolderEvent: Equatable {
  var path: String
  var flags: FSEventStreamEventFlags

  func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
}

/// One FSEvents stream over one folder, with file-level events, delivered on
/// the main queue. It also reports the folder itself moving or going away.
/// Stops when released.
@MainActor
final class FolderEventStream {
  private final class Handler {
    let deliver: @MainActor ([FolderEvent]) -> Void
    init(_ deliver: @escaping @MainActor ([FolderEvent]) -> Void) { self.deliver = deliver }
  }

  // Touched only on the main actor, and by `deinit`.
  private nonisolated(unsafe) var stream: FSEventStreamRef?

  /// Nil when the system will not start a stream.
  init?(path: String, deliver: @escaping @MainActor ([FolderEvent]) -> Void) {
    let handler = Handler(deliver)
    // The stream owns the handler and releases it with itself.
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passRetained(handler).toOpaque(), retain: nil,
      release: { info in
        if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
      },
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
      let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
      let events = (0..<count).compactMap { index in
        (paths[index] as? String).map { FolderEvent(path: $0, flags: flags[index]) }
      }
      // Delivering may end this very stream, and with it the handler.
      withExtendedLifetime(handler) {
        MainActor.assumeIsolated { handler.deliver(events) }
      }
    }
    let flags =
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
      | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
    guard
      let created = FSEventStreamCreate(
        nil, callback, &context, [path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
        FSEventStreamCreateFlags(flags))
    else {
      Unmanaged.passUnretained(handler).release()
      return nil
    }
    FSEventStreamSetDispatchQueue(created, .main)
    guard FSEventStreamStart(created) else {
      FSEventStreamInvalidate(created)
      FSEventStreamRelease(created)
      return nil
    }
    stream = created
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}

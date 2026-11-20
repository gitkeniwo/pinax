import Testing

/// The parent of every test that needs a key window,
/// a first responder or SwiftUI focus. The test process is never the active
/// app, so under the parallel run `NSApp.keyWindow` stays nil and focus
/// requests are dropped (measured); these tests run instead in a
/// separate serial invocation:
///
///     swift test --skip FocusSerial
///     swift test --no-parallel --filter FocusSerial
///
/// Each child suite forwards to the original test function, which stays in
/// its own file and suite with its body and assertions unchanged.
@Suite(.serialized) enum FocusSerial {}

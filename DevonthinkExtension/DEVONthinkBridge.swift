import Foundation

/// DEVONthink application identity.
///
/// Data fetching no longer uses Apple Events: the extension talks to DEVONthink
/// through its bundled MCP stdio server (`DevonthinkMCP`), which launches and
/// awaits DEVONthink itself. Only the stable bundle identifier remains —
/// used to recognize the DEVONthink app as an action subject.
enum DEVONthinkBridge {
  static let bundleID = "com.devon-technologies.think"
}

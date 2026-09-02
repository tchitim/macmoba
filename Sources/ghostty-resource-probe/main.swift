// Proves GhosttyRuntimeResources resolves from Contents/Resources inside a
// packaged .app — the layout that crashed on a machine other than the build
// machine. Temporary: driven by scripts/check-ghostty-resources.sh.
import Foundation
import GhosttyTerminal

let dir = GhosttyRuntimeResources.directoryURL
let terminfo = GhosttyRuntimeResources.terminfoDirectoryURL
print("bundleURL   : \(Bundle.main.bundleURL.path)")
print("resourceURL : \(Bundle.main.resourceURL?.path ?? "nil")")
print("Ghostty dir : \(dir?.path ?? "NOT FOUND")")
print("terminfo dir: \(terminfo?.path ?? "NOT FOUND")")
exit(dir != nil && terminfo != nil ? 0 : 1)

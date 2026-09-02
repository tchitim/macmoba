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

// Does a custom config key actually reach libghostty, or get silently dropped?
// Worth asserting rather than assuming: cmux has filed several issues about
// scrollback-limit being ignored, and a dropped setting looks exactly like a
// working one from the outside.
let probeValue = "12345678"
let controller = MainActor.assumeIsolated {
    TerminalController { builder in
        builder.withCustom("scrollback-limit", probeValue)
    }
}
let rendered = MainActor.assumeIsolated { controller.renderedConfig }
let carried = rendered.contains("scrollback-limit") && rendered.contains(probeValue)
print("scrollback-limit reaches config: \(carried ? "YES" : "NO — silently dropped")")
if !carried {
    print("--- rendered config ---")
    print(rendered.prefix(600))
}
exit(dir != nil && terminfo != nil && carried ? 0 : 1)

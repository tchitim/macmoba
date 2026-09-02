// Seeds a throwaway vault with one SSH session, so the experimental
// libghostty SSH pane can be exercised without touching the real vault or
// this Mac's ~/.ssh. Test-only; see scripts/check-ghostty-ssh.sh.
import Foundation
import MacMobaCore

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let vault = Vault(fileURL: dir.appendingPathComponent("vault.json"))
_ = try vault.create(masterPassword: "testpassword123")
var data = try vault.getData()
data.sessions = [
    SessionConfig(name: "ghostty-ssh-test", host: "127.0.0.1", port: 2222,
                  username: "tester", password: "secret")
]
try vault.save(data)
print("seeded \(dir.path) with \(data.sessions.count) session(s)")

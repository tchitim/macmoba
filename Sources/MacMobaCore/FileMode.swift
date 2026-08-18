// Unix file permissions, the two ways people read and write them: the octal
// "755" and the symbolic "rwxr-xr-x". Used by the SFTP browser's Permissions
// panel — parse what the user types, show what the server reports.
//
// Only the low 12 bits matter for chmod (the 9 permission bits plus setuid,
// setgid and the sticky bit); the file-type bits above them are never changed.

import Foundation

public enum FileMode {
    /// The permission and special bits — everything chmod may touch.
    public static let permissionMask: UInt32 = 0o7777

    /// An octal string ("755", "0644", "1777") to its bits, or nil if it is not
    /// a valid mode. Up to four octal digits.
    public static func parse(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 4,
              trimmed.allSatisfy({ ("0"..."7").contains($0) }),
              let value = UInt32(trimmed, radix: 8) else { return nil }
        return value
    }

    /// The chmod-able bits of `mode` as an octal string, e.g. 0o40755 -> "755".
    public static func octalString(_ mode: UInt32) -> String {
        String(mode & permissionMask, radix: 8)
    }

    /// The nine rwx characters, e.g. "rwxr-xr-x", with setuid/setgid/sticky
    /// folded into the x column (s/S, t/T) the way `ls -l` shows them.
    public static func symbolic(_ mode: UInt32) -> String {
        let perms = mode & 0o777
        var chars = Array("---------")
        let letters: [Character] = ["r", "w", "x"]
        for group in 0..<3 {
            let triad = (perms >> UInt32((2 - group) * 3)) & 0o7
            for bit in 0..<3 where triad & (0o4 >> UInt32(bit)) != 0 {
                chars[group * 3 + bit] = letters[bit]
            }
        }
        // Special bits land in the execute column.
        applySpecial(&chars, mode: mode, bit: 0o4000, execIndex: 2, set: "s", clear: "S")
        applySpecial(&chars, mode: mode, bit: 0o2000, execIndex: 5, set: "s", clear: "S")
        applySpecial(&chars, mode: mode, bit: 0o1000, execIndex: 8, set: "t", clear: "T")
        return String(chars)
    }

    private static func applySpecial(_ chars: inout [Character], mode: UInt32,
                                     bit: UInt32, execIndex: Int,
                                     set: Character, clear: Character) {
        guard mode & bit != 0 else { return }
        chars[execIndex] = chars[execIndex] == "x" ? set : clear
    }
}

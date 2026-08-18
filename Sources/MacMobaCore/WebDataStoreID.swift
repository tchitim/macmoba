// A stable, private storage identity for each web session.
//
// A web tab used to run on a non-persistent data store, which sounded tidy —
// nothing left on disk — but means no cache at all: every time the tab is
// opened, the site's entire JavaScript bundle is fetched again over the SSH
// tunnel. For a small page that is invisible. For an app like LangFlow, whose
// bundle runs to tens of megabytes, it is the difference between "loads" and
// "sits on Loading…". Measured against a server that sends an ETag: with no
// persistence the bundle was re-downloaded in full on the second visit; with
// it, the browser revalidated and got a 304.
//
// Each session gets its own store, keyed by an identifier derived from the
// session id, so two internal sites still cannot see each other's cookies.

import CryptoKit
import Foundation

public enum WebDataStoreID {
    /// A stable UUID for `sessionID`. The same session always gets the same
    /// one — that is the whole point, it is what makes the cache persist —
    /// and different sessions never collide.
    public static func identifier(for sessionID: String) -> UUID {
        let digest = SHA256.hash(data: Data(("macmoba.web." + sessionID).utf8))
        var bytes = Array(digest.prefix(16))
        // WebKit rejects the all-zero UUID; a digest will not produce one, but
        // the guarantee should not rest on that.
        if bytes.allSatisfy({ $0 == 0 }) { bytes[15] = 1 }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

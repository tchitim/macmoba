// Giving a page back the clipboard API that plain http takes away.
//
// `navigator.clipboard` exists only in a "secure context". An internal site
// served over http at an IP address — a Langfuse, a Jenkins, a switch admin
// page — is not one, so it is undefined there, and every copy button on such a
// site silently does nothing: the click lands, the promise never happens, no
// error is shown. Nothing is broken; the site is being held to a rule written
// for the public web.
//
// This is the script that puts it back, injected at document start. It lives
// here rather than inline in the view so a syntax error in it fails a test
// instead of quietly breaking copy again.

import Foundation

public enum WebClipboardBridge {
    /// The name of the message handler the script posts to.
    public static let handlerName = "macmobaClipboard"

    /// Only writing is bridged. Reading is deliberately absent: a page able to
    /// call readText() could inspect the Mac's clipboard without anyone
    /// touching anything, and ⌘V pastes into a page without this API.
    public static let script = """
    (function () {
      if (navigator.clipboard && navigator.clipboard.writeText) { return; }
      var send = function (text) {
        window.webkit.messageHandlers.\(handlerName).postMessage(String(text));
        return Promise.resolve();
      };
      var clipboard = {
        writeText: send,
        // Sites using the richer API still put text/plain in the item.
        write: function (items) {
          var item = (items || [])[0];
          if (!item || !item.getType) { return Promise.reject(new Error('unsupported')); }
          return item.getType('text/plain')
            .then(function (blob) { return blob.text(); })
            .then(send);
        },
      };
      Object.defineProperty(navigator, 'clipboard', {
        value: clipboard, configurable: true,
      });
    })();
    """
}

// C surface over FreeRDP, kept deliberately small.
//
// Swift cannot import FreeRDP's headers directly (they lean on macros and
// variadic logging that Clang's importer chokes on), and FreeRDP's callback
// model is thread-based. So this shim owns the connection thread and hands
// Swift four things: frames, state changes, certificate decisions, and input.

#ifndef MACMOBA_RDP_H
#define MACMOBA_RDP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MacMobaRDP MacMobaRDP;

/// Connection lifecycle, mirroring TerminalTab.State on the Swift side.
typedef enum {
    MACMOBA_RDP_STATE_CONNECTING = 0,
    MACMOBA_RDP_STATE_CONNECTED = 1,
    MACMOBA_RDP_STATE_DISCONNECTED = 2,
} MacMobaRDPState;

/// A finished frame. `pixels` is BGRA (little-endian 32-bit), valid only for
/// the duration of the call — copy or draw before returning. Called on the
/// connection thread.
typedef void (*MacMobaRDPFrameCallback)(void *userData, const uint8_t *pixels,
                                        int width, int height, int stride);

/// State change; `message` is NULL unless there is something to explain.
typedef void (*MacMobaRDPStateCallback)(void *userData, MacMobaRDPState state,
                                        const char *message);

/// Server certificate offered during connect. Return true to proceed.
/// Called on the connection thread and blocks the handshake until it returns,
/// which is what lets Swift put a prompt in front of the user first.
typedef bool (*MacMobaRDPCertCallback)(void *userData, const char *host,
                                       const char *commonName,
                                       const char *fingerprint,
                                       bool hostMismatch);

/// Called exactly once, when the last owner of the session lets go and every
/// C-side structure has been torn down. Lets the caller drop the strong
/// reference it handed over as `userData`. May run on the connection thread:
/// see macmoba_rdp_free for why the connection thread can outlive the caller.
typedef void (*MacMobaRDPReleaseCallback)(void *userData);

MacMobaRDP *macmoba_rdp_create(void *userData,
                               MacMobaRDPFrameCallback onFrame,
                               MacMobaRDPStateCallback onState,
                               MacMobaRDPCertCallback onCertificate,
                               MacMobaRDPReleaseCallback onRelease);

/// One display, as the server should see it. Coordinates are in pixels with
/// the primary monitor at the origin and y increasing DOWNWARD — which is not
/// how macOS describes screens, so the conversion happens in Swift
/// (RDPMonitorLayout) where it can be tested.
typedef struct {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
    bool isPrimary;
    /// desktopScaleFactor as a percentage: 100 for 1x, 200 for Retina.
    uint32_t scalePercent;
} MacMobaRDPMonitor;

/// Starts the connection thread and returns immediately.
/// `security` is 0 negotiate, 1 NLA, 2 TLS, 3 legacy RDP.
/// `drives` are FreeRDP "name,path" strings, each mounted in the session as a
/// redirected drive. May be NULL.
/// `dynamicResolution` opens the display-control channel so the desktop can be
/// resized later. Pass false for a session pinned to one size — otherwise the
/// server is told the desktop may change when the whole point is that it will
/// not.
/// `monitors` describes a multi-monitor session; pass NULL/0 for a single
/// monitor. With more than one, the server sends ONE framebuffer spanning their
/// bounding box, and the client is responsible for showing each monitor's
/// region on the right screen.
bool macmoba_rdp_connect(MacMobaRDP *rdp, const char *host, int port,
                         const char *username, const char *password,
                         const char *domain, int width, int height,
                         int security, bool dynamicResolution,
                         const char *alternateShell,
                         const char *const *drives, int driveCount,
                         const MacMobaRDPMonitor *monitors, int monitorCount);

/// Send FreeRDP's own log to `path` as well as stderr, so a failing connection
/// can be diagnosed without launching the app from a terminal.
void macmoba_rdp_set_log_file(const char *path);

/// Human-readable text for the last connection error, or NULL.
const char *macmoba_rdp_last_error(MacMobaRDP *rdp);

void macmoba_rdp_disconnect(MacMobaRDP *rdp);

/// Releases the caller's claim on the session. The pointer must not be used
/// again afterwards.
///
/// This does not guarantee the session is gone by the time it returns. Tearing
/// a connection down means waiting on `freerdp_disconnect`, which talks to the
/// server and can block for a long time when the network has dropped — exactly
/// when a disconnect is most likely. So the wait for the connection thread is
/// bounded, and if it expires the thread keeps the session alive and frees it
/// once it finally unwinds. `onRelease` marks that point.
void macmoba_rdp_free(MacMobaRDP *rdp);

/// Pointer flags are the RDP PTR_FLAGS_* values; the Swift side builds them.
void macmoba_rdp_send_pointer(MacMobaRDP *rdp, uint16_t flags, uint16_t x, uint16_t y);
/// `code` is an RDP scancode; `extended` marks the E0 set.
void macmoba_rdp_send_scancode(MacMobaRDP *rdp, uint16_t code, bool down, bool extended);
void macmoba_rdp_send_unicode(MacMobaRDP *rdp, uint16_t codepoint, bool down);

/// Remote clipboard text arrived (UTF-8). Called on the connection thread.
typedef void (*MacMobaRDPClipboardCallback)(void *userData, const char *utf8);

/// Remote clipboard image arrived, as a packed DIB (BITMAPINFOHEADER followed
/// by pixel data — i.e. a .bmp file without its 14-byte file header).
typedef void (*MacMobaRDPImageCallback)(void *userData, const uint8_t *dib, uint32_t len);

/// The remote clipboard holds files. `names` is a newline-separated list of
/// file names, `sizes` their byte counts in the same order. Enough to put
/// promises on the pasteboard without transferring anything yet.
typedef void (*MacMobaRDPFileListCallback)(void *userData, const char *names,
                                           const uint64_t *sizes, uint32_t count);

/// One reply to a range request. `failed` means the server could not supply it.
typedef void (*MacMobaRDPFileChunkCallback)(void *userData, uint32_t requestId,
                                            const uint8_t *bytes, uint32_t len,
                                            bool failed);

/// Register the clipboard callbacks. Pass NULL to disable clipboard sharing.
void macmoba_rdp_set_clipboard_callback(MacMobaRDP *rdp,
                                        MacMobaRDPClipboardCallback onClipboard,
                                        MacMobaRDPImageCallback onImage);

/// Offer local clipboard content to the remote session. Either argument may be
/// NULL. The server pulls the actual bytes afterwards, so they are held here
/// until it asks.
void macmoba_rdp_offer_clipboard(MacMobaRDP *rdp, const char *utf8,
                                 const uint8_t *dib, uint32_t dibLen);

void macmoba_rdp_set_file_callbacks(MacMobaRDP *rdp,
                                    MacMobaRDPFileListCallback onFileList,
                                    MacMobaRDPFileChunkCallback onFileChunk);

/// Offer local files to the session. `paths` is newline-separated absolute
/// paths; NULL or empty withdraws the offer.
void macmoba_rdp_offer_files(MacMobaRDP *rdp, const char *paths);

/// Offer everything the local pasteboard holds, in ONE announcement.
///
/// Use this rather than calling the two above in sequence. Each of those sends
/// its own format list, so a text copy announced twice a millisecond apart —
/// and the first of the pair was built from the PREVIOUS contents, which on a
/// fresh copy is an empty list. An empty format list means "my clipboard is now
/// empty", so the session was told the clipboard was cleared and then, out of
/// sequence, that it held text. A format list is also supposed to wait for its
/// format list response before the next one is sent.
void macmoba_rdp_offer_all(MacMobaRDP *rdp, const char *paths, const char *utf8,
                           const uint8_t *dib, uint32_t dibLen);

/// Ask for a byte range of remote file `index`. The reply arrives on the chunk
/// callback tagged with `requestId`. Returns false if files are not on offer.
bool macmoba_rdp_request_file_range(MacMobaRDP *rdp, uint32_t requestId,
                                    uint32_t index, uint64_t offset, uint32_t length);

/// True once the server has opened the display-control channel, i.e. it can
/// resize the session. Windows 8.1 / Server 2012 R2 and later.
bool macmoba_rdp_can_resize(MacMobaRDP *rdp);

/// Ask the server to resize the desktop to match the pane.
///
/// This sends a layout of ONE monitor, so it must not be used on a session
/// that is spanning displays — the multi-monitor desktop would collapse.
void macmoba_rdp_request_resize(MacMobaRDP *rdp, int width, int height);

/// How many monitors the server will accept in a layout. 0 when it cannot
/// resize at all, 1 until its capability message has arrived.
int macmoba_rdp_max_monitors(MacMobaRDP *rdp);

/// Re-lay-out the session's monitors while it is connected.
///
/// This is how a session becomes multi-monitor, and how it stops being one:
/// spanning is negotiated in full screen rather than at connect time, so a
/// windowed session is the size of the screen it is on. Returns false when the
/// server will not take the layout, in which case the desktop is unchanged.
bool macmoba_rdp_send_monitor_layout(MacMobaRDP *rdp,
                                     const MacMobaRDPMonitor *monitors, int count);

/// RDP pointer flag values, re-exported so Swift does not need FreeRDP headers.
extern const uint16_t MACMOBA_PTR_FLAGS_MOVE;
extern const uint16_t MACMOBA_PTR_FLAGS_DOWN;
extern const uint16_t MACMOBA_PTR_FLAGS_BUTTON1;
extern const uint16_t MACMOBA_PTR_FLAGS_BUTTON2;
extern const uint16_t MACMOBA_PTR_FLAGS_BUTTON3;
extern const uint16_t MACMOBA_PTR_FLAGS_WHEEL;
extern const uint16_t MACMOBA_PTR_FLAGS_WHEEL_NEGATIVE;

#ifdef __cplusplus
}
#endif

#endif /* MACMOBA_RDP_H */

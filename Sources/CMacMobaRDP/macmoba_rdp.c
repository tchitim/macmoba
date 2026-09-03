// FreeRDP glue. See macmoba_rdp.h for why this layer exists.

#include "include/macmoba_rdp.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/shell.h>
#include <freerdp/input.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <winpr/thread.h>

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>

const uint16_t MACMOBA_PTR_FLAGS_MOVE = PTR_FLAGS_MOVE;
const uint16_t MACMOBA_PTR_FLAGS_DOWN = PTR_FLAGS_DOWN;
const uint16_t MACMOBA_PTR_FLAGS_BUTTON1 = PTR_FLAGS_BUTTON1;
const uint16_t MACMOBA_PTR_FLAGS_BUTTON2 = PTR_FLAGS_BUTTON2;
const uint16_t MACMOBA_PTR_FLAGS_BUTTON3 = PTR_FLAGS_BUTTON3;
const uint16_t MACMOBA_PTR_FLAGS_WHEEL = PTR_FLAGS_WHEEL;
const uint16_t MACMOBA_PTR_FLAGS_WHEEL_NEGATIVE = PTR_FLAGS_WHEEL_NEGATIVE;

/// FreeRDP allocates our context inline with its own, so this struct must lead
/// with rdpContext — that is how the client entry points hand it back to us.
typedef struct {
    rdpContext context;
    MacMobaRDP *owner;
} MacMobaContext;

struct MacMobaRDP {
    rdpContext *context;
    HANDLE thread;
    volatile bool stopping;
    /// Two independent owners: the caller, and the connection thread while it
    /// runs. Whichever lets go last tears the session down. A plain "stop and
    /// free" cannot work here because stopping is not bounded in time — see
    /// macmoba_rdp_free — and freeing the context out from under a thread still
    /// polling `context->abortEvent` is a use-after-free.
    atomic_int refCount;
    /// Display-control channel, once the server has opened it. NULL means the
    /// server does not support resizing the session.
    DispClientContext *disp;
    UINT32 maxMonitorAreaFactorA;
    UINT32 maxMonitorAreaFactorB;
    /// How many monitors the server said it will accept in a layout. Zero
    /// until the capability arrives, which is treated as "one".
    UINT32 maxMonitors;

    CliprdrClientContext *cliprdr;
    /// Set once the server has sent MonitorReady. Nothing may be advertised on
    /// the clipboard channel before that; see mm_cliprdr_send_format_list().
    bool clipboardReady;
    /// Whether the server agreed to long format names. Without them a format
    /// name is limited to 15 characters, which "FileGroupDescriptorW" exceeds.
    bool useLongFormatNames;
    MacMobaRDPClipboardCallback onClipboard;
    MacMobaRDPImageCallback onImage;
    /// Which format the outstanding FormatDataRequest asked for.
    UINT32 requestedFormatId;
    /// Local clipboard content we have advertised, kept until the server asks.
    /// Guarded because the connection thread reads it while the main thread
    /// replaces it whenever the Mac pasteboard changes.
    char *pendingLocalText;
    BYTE *pendingLocalDib;
    UINT32 pendingLocalDibLen;

    MacMobaRDPFileListCallback onFileList;
    MacMobaRDPFileChunkCallback onFileChunk;
    /// Format id the server used for FileGroupDescriptorW; it is negotiated,
    /// not fixed, so it has to be remembered from the format list.
    UINT32 remoteFileDescriptorId;
    /// How many files the server is currently offering.
    UINT32 remoteFileCount;
    /// Local files we have advertised, newline separated absolute paths.
    char *pendingLocalFiles;

    /// Outstanding range requests, keyed by the streamId we sent.
    UINT32 nextStreamId;
    struct {
        UINT32 streamId;
        UINT32 requestId;
        bool active;
    } fileRequests[32];

    CRITICAL_SECTION clipboardLock;

    void *userData;
    MacMobaRDPFrameCallback onFrame;
    MacMobaRDPStateCallback onState;
    MacMobaRDPCertCallback onCertificate;
    MacMobaRDPReleaseCallback onRelease;
};

static void mm_retain(MacMobaRDP *rdp)
{
    atomic_fetch_add_explicit(&rdp->refCount, 1, memory_order_relaxed);
}

/// Drops one claim, and performs the teardown when the last one goes. Runs on
/// whichever thread happens to be last: the caller's, or the connection thread
/// after a disconnect that outlasted the caller's patience.
static void mm_release(MacMobaRDP *rdp)
{
    if (!rdp)
        return;
    if (atomic_fetch_sub_explicit(&rdp->refCount, 1, memory_order_acq_rel) != 1)
        return;

    if (rdp->context)
        freerdp_client_context_free(rdp->context);
    free(rdp->pendingLocalText);
    free(rdp->pendingLocalDib);
    free(rdp->pendingLocalFiles);
    DeleteCriticalSection(&rdp->clipboardLock);
    // Last, and after everything that could still call back: this is what lets
    // the Swift object holding `userData` finally deallocate.
    if (rdp->onRelease)
        rdp->onRelease(rdp->userData);
    free(rdp);
}

static void report_state(MacMobaRDP *rdp, MacMobaRDPState state, const char *message)
{
    if (rdp && rdp->onState)
        rdp->onState(rdp->userData, state, message);
}

#define MACMOBA_FILEDESCRIPTOR_NAME "FileGroupDescriptorW"
#define MACMOBA_FILECONTENTS_NAME "FileContents"
/// The ids we use when *we* advertise. Windows matches these named formats by
/// name, so the numbers only have to be consistent within a session.
#define MACMOBA_LOCAL_FILEDESCRIPTOR_ID 49267
#define MACMOBA_LOCAL_FILECONTENTS_ID 49268

static UINT mm_cliprdr_handle_file_descriptors(MacMobaRDP *rdp, const BYTE *data, UINT32 len);
static UINT mm_cliprdr_send_local_file_descriptors(MacMobaRDP *rdp,
                                                   CliprdrClientContext *context);
static UINT mm_cliprdr_server_file_contents_request(
    CliprdrClientContext *context, const CLIPRDR_FILE_CONTENTS_REQUEST *request);
static UINT mm_cliprdr_server_file_contents_response(
    CliprdrClientContext *context, const CLIPRDR_FILE_CONTENTS_RESPONSE *response);

static void mm_channel_connected(void *context, const ChannelConnectedEventArgs *e);
static void mm_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e);
static void mm_cliprdr_attach(MacMobaRDP *rdp, CliprdrClientContext *context);

// MARK: - Paint callbacks

static BOOL mm_begin_paint(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
        return FALSE;
    gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

/// A frame is complete: hand the whole primary buffer to Swift. We deliberately
/// do not track dirty rectangles — the pane redraws the full framebuffer, which
/// keeps this layer simple and is fast enough at desktop sizes.
static BOOL mm_end_paint(rdpContext *context)
{
    MacMobaContext *ctx = (MacMobaContext *)context;
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer)
        return TRUE;
    if (ctx->owner && ctx->owner->onFrame) {
        ctx->owner->onFrame(ctx->owner->userData, gdi->primary_buffer,
                            (int)gdi->width, (int)gdi->height, (int)gdi->stride);
    }
    return TRUE;
}

static BOOL mm_desktop_resize(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    rdpSettings *settings = context->settings;
    if (!gdi_resize(gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                    freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight)))
        return FALSE;
    return mm_end_paint(context);
}

// MARK: - Connection callbacks

static BOOL mm_pre_connect(freerdp *instance)
{
    rdpSettings *settings = instance->context->settings;
    // Leave PEM off: with it on, FreeRDP passes the whole certificate in the
    // `fingerprint` argument, and the prompt would show a wall of base64
    // instead of something a person can compare.
    if (!freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, FALSE))
        return FALSE;
    // Optional identifier sent to the server.
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH))
        return FALSE;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
        return FALSE;
    // Subscribe before connecting: the display-control channel hands us its
    // client context through this event, and there is no other way to reach it.
    if (PubSub_SubscribeChannelConnected(instance->context->pubSub,
                                         mm_channel_connected) < 0)
        return FALSE;
    if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub,
                                            mm_channel_disconnected) < 0)
        return FALSE;

    // NOTE: OrderSupport is already initialised by the library here. It is a
    // byte array, not a flag — setting it as a bool fails and takes the whole
    // pre-connect down with ERRCONNECT_PRE_CONNECT_FAILED.
    return TRUE;
}

static BOOL mm_post_connect(freerdp *instance)
{
    // BGRA32 so the buffer can go straight into a CGImage with
    // kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, no conversion.
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;

    rdpContext *context = instance->context;
    context->update->BeginPaint = mm_begin_paint;
    context->update->EndPaint = mm_end_paint;
    context->update->DesktopResize = mm_desktop_resize;

    MacMobaContext *ctx = (MacMobaContext *)context;
    report_state(ctx->owner, MACMOBA_RDP_STATE_CONNECTED, NULL);
    // Push the first frame immediately: the server may not repaint until
    // something changes, and an empty pane looks like a failed connection.
    mm_end_paint(context);
    return TRUE;
}

static void mm_post_disconnect(freerdp *instance)
{
    if (instance && instance->context)
        gdi_free(instance);
}

/// Certificate check. Handing this to Swift keeps RDP consistent with how SSH
/// host keys are treated — the user sees the fingerprint and decides.
static DWORD mm_verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                   const char *common_name, const char *subject,
                                   const char *issuer, const char *fingerprint, DWORD flags)
{
    (void)port;
    (void)subject;
    (void)issuer;
    MacMobaContext *ctx = (MacMobaContext *)instance->context;
    MacMobaRDP *rdp = ctx->owner;
    if (!rdp || !rdp->onCertificate)
        return 0; // reject when nobody can vouch for it
    bool mismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0;
    bool accept = rdp->onCertificate(rdp->userData, host, common_name, fingerprint, mismatch);
    // 1 = accept and remember, 2 = accept once, 0 = reject. "Once" keeps the
    // decision in Swift rather than in FreeRDP's own known_hosts file.
    return accept ? 2 : 0;
}

static DWORD mm_verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                           const char *common_name, const char *subject,
                                           const char *issuer, const char *fingerprint,
                                           const char *old_subject, const char *old_issuer,
                                           const char *old_fingerprint, DWORD flags)
{
    (void)old_subject;
    (void)old_issuer;
    (void)old_fingerprint;
    return mm_verify_certificate(instance, host, port, common_name, subject, issuer,
                                 fingerprint, flags | VERIFY_CERT_FLAG_MISMATCH);
}

// MARK: - Client entry points

/// The server's answer to "how big a layout will you take?".
static UINT mm_disp_caps(DispClientContext *disp, UINT32 maxNumMonitors,
                         UINT32 maxMonitorAreaFactorA, UINT32 maxMonitorAreaFactorB)
{
    MacMobaRDP *rdp = disp ? (MacMobaRDP *)disp->custom : NULL;
    if (!rdp)
        return CHANNEL_RC_OK;
    rdp->maxMonitors = maxNumMonitors;
    rdp->maxMonitorAreaFactorA = maxMonitorAreaFactorA;
    rdp->maxMonitorAreaFactorB = maxMonitorAreaFactorB;
    WLog_INFO("com.macmoba.rdp", "display control: up to %u monitor(s)", maxNumMonitors);
    return CHANNEL_RC_OK;
}

static void mm_channel_connected(void *context, const ChannelConnectedEventArgs *e)
{
    MacMobaContext *ctx = (MacMobaContext *)context;
    if (!ctx || !ctx->owner || !e || !e->name)
        return;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext *disp = (DispClientContext *)e->pInterface;
        ctx->owner->disp = disp;
        // The server states how many monitors it will accept. Sending more is
        // a protocol error, so the answer is remembered here and the layout is
        // trimmed to it rather than being sent hopefully.
        disp->custom = ctx->owner;
        disp->DisplayControlCaps = mm_disp_caps;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
        mm_cliprdr_attach(ctx->owner, (CliprdrClientContext *)e->pInterface);
}

static void mm_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e)
{
    MacMobaContext *ctx = (MacMobaContext *)context;
    if (!ctx || !ctx->owner || !e || !e->name)
        return;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
        ctx->owner->disp = NULL;
    else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        ctx->owner->cliprdr = NULL;
        ctx->owner->clipboardReady = false;
        ctx->owner->useLongFormatNames = false;
    }
}

/// FreeRDP asks for credentials when NLA needs them and the settings are
/// incomplete. Answering from the stored session (rather than letting the
/// library prompt) keeps the failure honest: the connection fails with a
/// message instead of hanging on an invisible prompt.
///
/// An EMPTY password is a credential, not a missing one. Refusing it here
/// aborted the connection before the server was ever asked — which is exactly
/// what a CyberArk PSM file needs, since it carries a one-time token as the
/// user name and no password at all. Whether an empty password is acceptable
/// is the server's decision, and its answer is a clean authentication failure
/// rather than a cancelled handshake.
static BOOL mm_authenticate(freerdp *instance, char **username, char **password,
                            char **domain, rdp_auth_reason reason)
{
    (void)reason;
    rdpSettings *settings = instance->context->settings;
    const char *user = freerdp_settings_get_string(settings, FreeRDP_Username);
    const char *pass = freerdp_settings_get_string(settings, FreeRDP_Password);
    const char *dom = freerdp_settings_get_string(settings, FreeRDP_Domain);

    // Without a user name there is nothing to send at all, and NLA cannot
    // proceed; that is still worth failing early with an explanation.
    if (!user || !*user) {
        MacMobaContext *ctx = (MacMobaContext *)instance->context;
        report_state(ctx->owner, MACMOBA_RDP_STATE_CONNECTING,
                     "This server asked for credentials, but the session has no user name.");
        return FALSE;
    }
    if (username) *username = _strdup(user);
    if (password) *password = _strdup(pass ? pass : "");
    if (domain) *domain = dom ? _strdup(dom) : NULL;
    WLog_INFO("com.macmoba.rdp", "supplying credentials for %s%s%s (password %s)",
              dom && *dom ? dom : "", dom && *dom ? "\\" : "", user,
              pass && *pass ? "set" : "EMPTY");
    return TRUE;
}

static BOOL mm_client_new(freerdp *instance, rdpContext *context)
{
    (void)context;
    instance->AuthenticateEx = mm_authenticate;
    instance->PreConnect = mm_pre_connect;
    instance->PostConnect = mm_post_connect;
    instance->PostDisconnect = mm_post_disconnect;
    instance->VerifyCertificateEx = mm_verify_certificate;
    instance->VerifyChangedCertificateEx = mm_verify_changed_certificate;
    return TRUE;
}

static void mm_client_free(freerdp *instance, rdpContext *context)
{
    (void)instance;
    (void)context;
}

static int mm_client_start(rdpContext *context)
{
    (void)context;
    return 0;
}

static int mm_client_stop(rdpContext *context)
{
    (void)context;
    return 0;
}

static int mm_client_entry(RDP_CLIENT_ENTRY_POINTS *pEntryPoints)
{
    ZeroMemory(pEntryPoints, sizeof(RDP_CLIENT_ENTRY_POINTS));
    pEntryPoints->Version = RDP_CLIENT_INTERFACE_VERSION;
    pEntryPoints->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    pEntryPoints->ContextSize = sizeof(MacMobaContext);
    pEntryPoints->ClientNew = mm_client_new;
    pEntryPoints->ClientFree = mm_client_free;
    pEntryPoints->ClientStart = mm_client_start;
    pEntryPoints->ClientStop = mm_client_stop;
    return 0;
}

// MARK: - Connection thread

static DWORD WINAPI mm_thread(LPVOID arg)
{
    MacMobaRDP *rdp = (MacMobaRDP *)arg;
    rdpContext *context = rdp->context;
    freerdp *instance = context->instance;

    if (!freerdp_connect(instance)) {
        UINT32 last = freerdp_get_last_error(context);
        const char *name = freerdp_get_last_error_name(last);
        report_state(rdp, MACMOBA_RDP_STATE_DISCONNECTED,
                     name ? name : "connection failed");
        mm_release(rdp);
        return 0;
    }

    while (!rdp->stopping && !freerdp_shall_disconnect_context(context)) {
        HANDLE handles[64];
        DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
        if (count == 0)
            break;
        // Bounded wait so a stop request is noticed even when the server is idle.
        DWORD status = WaitForMultipleObjects(count, handles, FALSE, 100);
        if (status == WAIT_FAILED)
            break;
        if (!freerdp_check_event_handles(context))
            break;
    }

    // This is the call that can take an unbounded time on a dead network, and
    // so the reason the caller may already have given up on us by the time it
    // returns. Nothing below may assume the caller is still there.
    freerdp_disconnect(instance);
    if (!rdp->stopping) {
        UINT32 last = freerdp_get_last_error(context);
        const char *name = (last != FREERDP_ERROR_SUCCESS)
                               ? freerdp_get_last_error_name(last) : NULL;
        report_state(rdp, MACMOBA_RDP_STATE_DISCONNECTED, name);
    } else {
        report_state(rdp, MACMOBA_RDP_STATE_DISCONNECTED, NULL);
    }
    mm_release(rdp);
    return 0;
}

// MARK: - Public API

MacMobaRDP *macmoba_rdp_create(void *userData,
                               MacMobaRDPFrameCallback onFrame,
                               MacMobaRDPStateCallback onState,
                               MacMobaRDPCertCallback onCertificate,
                               MacMobaRDPReleaseCallback onRelease)
{
    MacMobaRDP *rdp = calloc(1, sizeof(MacMobaRDP));
    if (!rdp)
        return NULL;
    InitializeCriticalSection(&rdp->clipboardLock);
    atomic_init(&rdp->refCount, 1); // the caller's claim
    rdp->userData = userData;
    rdp->onFrame = onFrame;
    rdp->onState = onState;
    rdp->onCertificate = onCertificate;
    rdp->onRelease = onRelease;

    RDP_CLIENT_ENTRY_POINTS entry;
    mm_client_entry(&entry);
    rdp->context = freerdp_client_context_new(&entry);
    if (!rdp->context) {
        // Goes through the normal teardown so the caller's reference is handed
        // back even on this path.
        mm_release(rdp);
        return NULL;
    }
    ((MacMobaContext *)rdp->context)->owner = rdp;
    return rdp;
}

/// Build the argument vector a FreeRDP client would normally be invoked with.
/// Going through the official parser rather than poking settings by hand is
/// deliberate: it applies the same defaults as every other FreeRDP client and
/// runs the post-processing that keeps channels, codecs and the security layer
/// consistent. Every RDP connection bug so far came from setting things
/// individually and getting one of them subtly wrong.
#define MACMOBA_MAX_DRIVES 8

static bool apply_command_line(MacMobaRDP *rdp, const char *host, int port,
                               const char *username, const char *password,
                               const char *domain, int width, int height,
                               int security, bool dynamicResolution,
                               bool multimon, const char *alternateShell,
                               const char *const *drives, int driveCount)
{
    char argHost[512], argUser[512], argPass[512], argDomain[512];
    char argWidth[64], argHeight[64], argShell[1024];
    char argDrives[MACMOBA_MAX_DRIVES][1024];
    const char *argv[26 + MACMOBA_MAX_DRIVES];
    int argc = 0;

    argv[argc++] = "macmoba";
    (void)snprintf(argHost, sizeof(argHost), "/v:%s:%d", host, port);
    argv[argc++] = argHost;

    if (username && *username) {
        (void)snprintf(argUser, sizeof(argUser), "/u:%s", username);
        argv[argc++] = argUser;
    }
    if (password && *password) {
        (void)snprintf(argPass, sizeof(argPass), "/p:%s", password);
        argv[argc++] = argPass;
    }
    if (domain && *domain) {
        (void)snprintf(argDomain, sizeof(argDomain), "/d:%s", domain);
        argv[argc++] = argDomain;
    }

    (void)snprintf(argWidth, sizeof(argWidth), "/w:%d", width);
    (void)snprintf(argHeight, sizeof(argHeight), "/h:%d", height);
    argv[argc++] = argWidth;
    argv[argc++] = argHeight;
    argv[argc++] = "/bpp:32";
    // Ask for the channels through the parser rather than by setting the
    // matching booleans: the parser also registers the static/dynamic channel
    // entries, which is what actually makes the addin load.
    argv[argc++] = "/clipboard";
    // Only when the desktop is allowed to follow the window. A session pinned
    // to one size must not advertise display control, or the server is free to
    // renegotiate the very thing the user fixed.
    if (dynamicResolution)
        argv[argc++] = "/dynamic-resolution";
    // Registers the monitor-layout capability. The actual layout is set through
    // the settings afterwards, because this only says "there are several".
    if (multimon)
        argv[argc++] = "/multimon";
    // Play the session's audio on this Mac rather than on the server.
    // Deliberately not pinned to "sys:mac": rdpsnd already tries the macOS
    // backend first (this build has WITH_MACAUDIO), and naming a subsystem
    // explicitly changes a failed load from "fall back to the silent fake
    // device" into "fail the whole channel". If the real backend ever cannot
    // load, FreeRDP's log says so — grep MacMoba-RDP.log for
    // "Unable to load sound playback subsystem".
    argv[argc++] = "/sound";

    // "Alternate shell": run this instead of the desktop shell. Carried over
    // from .rdp files — CyberArk PSM puts its routing here
    // ("psm /u user /a target /c component"), so dropping it connects to the
    // jump server and then sits there doing nothing.
    if (alternateShell && *alternateShell) {
        (void)snprintf(argShell, sizeof(argShell), "/shell:%s", alternateShell);
        argv[argc++] = argShell;
        WLog_INFO("com.macmoba.rdp", "alternate shell: %s", alternateShell);
    }

    if (drives && driveCount > 0) {
        if (driveCount > MACMOBA_MAX_DRIVES)
            driveCount = MACMOBA_MAX_DRIVES;
        for (int i = 0; i < driveCount; i++) {
            if (!drives[i] || !*drives[i])
                continue;
            (void)snprintf(argDrives[i], sizeof(argDrives[i]), "/drive:%s", drives[i]);
            argv[argc++] = argDrives[i];
        }
    }

    switch (security) {
        case 1: argv[argc++] = "/sec:nla"; break;
        case 2: argv[argc++] = "/sec:tls"; break;
        case 3: argv[argc++] = "/sec:rdp"; break;
        default: break; /* negotiate: leave the default alone */
    }

    const int rc = freerdp_client_settings_parse_command_line_arguments(
        rdp->context->settings, argc, (char **)argv, FALSE);
    if (rc != 0) {
        report_state(rdp, MACMOBA_RDP_STATE_DISCONNECTED,
                     "Could not apply the connection settings.");
        return false;
    }
    return true;
}

void macmoba_rdp_set_log_file(const char *path)
{
    wLog *root = WLog_GetRoot();
    if (!root || !path)
        return;
    if (!WLog_SetLogAppenderType(root, WLOG_APPENDER_FILE))
        return;
    wLogAppender *appender = WLog_GetLogAppender(root);
    if (!appender)
        return;
    // The appender wants the directory and the file name as separate settings;
    // handing it a full path silently produces no file at all.
    char dir[1024];
    strncpy(dir, path, sizeof(dir) - 1);
    dir[sizeof(dir) - 1] = '\0';
    char *slash = strrchr(dir, '/');
    const char *name = path;
    if (slash) {
        *slash = '\0';
        name = slash + 1;
        WLog_ConfigureAppender(appender, "outputfilepath", (void *)dir);
    }
    WLog_ConfigureAppender(appender, "outputfilename", (void *)name);
    WLog_SetLogLevel(root, WLOG_INFO);
    WLog_OpenAppender(root);
}

const char *macmoba_rdp_last_error(MacMobaRDP *rdp)
{
    if (!rdp || !rdp->context)
        return NULL;
    const UINT32 last = freerdp_get_last_error(rdp->context);
    if (last == FREERDP_ERROR_SUCCESS)
        return NULL;
    return freerdp_get_last_error_string(last);
}

bool macmoba_rdp_connect(MacMobaRDP *rdp, const char *host, int port,
                         const char *username, const char *password,
                         const char *domain, int width, int height,
                         int security, bool dynamicResolution,
                         const char *alternateShell,
                         const char *const *drives, int driveCount,
                         const MacMobaRDPMonitor *monitors, int monitorCount)
{
    if (!rdp || !rdp->context)
        return false;
    rdpSettings *settings = rdp->context->settings;

    bool multimon = monitors && monitorCount > 1;
    if (!apply_command_line(rdp, host, port, username, password, domain,
                            width, height, security, dynamicResolution,
                            multimon, alternateShell, drives, driveCount))
        return false;

    // The monitor layout has to be applied AFTER the command line is parsed:
    // the parser rewrites the monitor settings from /multimon and would
    // otherwise overwrite what we set here.
    if (multimon) {
        if (monitorCount > 16)
            monitorCount = 16;
        rdpMonitor defs[16];
        memset(defs, 0, sizeof(defs));
        for (int i = 0; i < monitorCount; i++) {
            defs[i].x = monitors[i].x;
            defs[i].y = monitors[i].y;
            defs[i].width = monitors[i].width;
            defs[i].height = monitors[i].height;
            defs[i].is_primary = monitors[i].isPrimary ? 1 : 0;
            defs[i].orig_screen = (UINT32)i;
            // Physical size is only used for DPI hints; the scale factor is
            // what Windows actually acts on.
            defs[i].attributes.desktopScaleFactor = monitors[i].scalePercent;
            defs[i].attributes.deviceScaleFactor = 100;
            defs[i].attributes.orientation = 0;
        }
        if (!freerdp_settings_set_monitor_def_array_sorted(settings, defs,
                                                           (size_t)monitorCount)) {
            WLog_ERR("com.macmoba.rdp",
                     "server refused the monitor layout; falling back to one monitor");
            freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, FALSE);
        } else {
            freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, TRUE);
            WLog_INFO("com.macmoba.rdp", "multi-monitor: %d displays, desktop %dx%d",
                      monitorCount, width, height);
        }
    }

    // Software GDI: we need pixels in a buffer we can hand to CoreGraphics,
    // not a hardware surface. Everything else is left to the parser above.
    freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
    // Critical in a GUI app: without this FreeRDP prompts for missing
    // credentials on stdin. There is no terminal attached, so the read blocks
    // and the connection ends as ERRCONNECT_CONNECT_CANCELLED with nothing on
    // screen to explain why.
    freerdp_settings_set_bool(settings, FreeRDP_CredentialsFromStdin, FALSE);
    // Announce Unicode input support. This is a capability the server checks:
    // without it, unicode key events are silently ignored and only scancodes
    // arrive — which looks like "typing does nothing" while Escape still works.
    freerdp_settings_set_bool(settings, FreeRDP_UnicodeInput, TRUE);
    // Clipboard sharing: this is the flag the addin table keys off to load
    // the cliprdr channel at all.
    freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE);

    report_state(rdp, MACMOBA_RDP_STATE_CONNECTING, NULL);
    rdp->stopping = false;
    // Taken before the thread exists, so that a thread which fails and exits
    // immediately cannot drop the count below what we are about to add.
    mm_retain(rdp);
    rdp->thread = CreateThread(NULL, 0, mm_thread, rdp, 0, NULL);
    if (!rdp->thread) {
        mm_release(rdp);
        return false;
    }
    return true;
}

void macmoba_rdp_disconnect(MacMobaRDP *rdp)
{
    if (!rdp || !rdp->context)
        return;
    // Logged because an abort during the handshake looks identical in
    // FreeRDP's output to a network failure: both end as
    // ERRCONNECT_CONNECT_CANCELLED. This line is the difference between "we
    // tore it down" and "it died on its own".
    WLog_INFO("com.macmoba.rdp", "disconnect requested by the app");
    rdp->stopping = true;
    freerdp_abort_connect_context(rdp->context);
    if (rdp->thread) {
        // Bounded: freerdp_disconnect can block for a long time on a network
        // that has already gone away. If it expires the thread is simply
        // detached — CloseHandle on a running WinPR thread detaches it — and
        // the session stays alive under its own reference until it unwinds.
        WaitForSingleObject(rdp->thread, 3000);
        CloseHandle(rdp->thread);
        rdp->thread = NULL;
    }
}

void macmoba_rdp_free(MacMobaRDP *rdp)
{
    if (!rdp)
        return;
    macmoba_rdp_disconnect(rdp);
    mm_release(rdp);
}

void macmoba_rdp_send_pointer(MacMobaRDP *rdp, uint16_t flags, uint16_t x, uint16_t y)
{
    if (!rdp || !rdp->context || !rdp->context->input)
        return;
    freerdp_input_send_mouse_event(rdp->context->input, flags, x, y);
}

void macmoba_rdp_send_scancode(MacMobaRDP *rdp, uint16_t code, bool down, bool extended)
{
    if (!rdp || !rdp->context || !rdp->context->input)
        return;
    UINT16 flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    if (extended)
        flags |= KBD_FLAGS_EXTENDED;
    freerdp_input_send_keyboard_event(rdp->context->input, flags, code);
}

void macmoba_rdp_send_unicode(MacMobaRDP *rdp, uint16_t codepoint, bool down)
{
    if (!rdp || !rdp->context || !rdp->context->input)
        return;
    freerdp_input_send_unicode_keyboard_event(rdp->context->input,
                                              down ? 0 : KBD_FLAGS_RELEASE, codepoint);
}


// MARK: - Clipboard (text only)
//
// Only CF_UNICODETEXT is handled. Files and images need the whole file-contents
// protocol, which is a much bigger job; text is what people actually paste
// between a Mac and a remote desktop all day.

static UINT mm_cliprdr_send_format_list(MacMobaRDP *rdp, bool haveText, bool haveImage)
{
    if (!rdp->cliprdr || !rdp->cliprdr->ClientFormatList)
        return CHANNEL_RC_OK;

    // Nothing may be advertised before the server says the clipboard is ready.
    //
    // The channel context exists from the moment the channel connects, but the
    // capability exchange happens later — and the pasteboard poller starts as
    // soon as the connection does. Advertising in that window produced
    // "cliprdr_packet_format_list_new failed!": long format names have not been
    // negotiated yet, so FreeRDP builds the list in SHORT-name mode, where a
    // name field holds 15 characters and "FileGroupDescriptorW" is 20.
    //
    // It showed up on RECONNECT because the Mac pasteboard already holds
    // something by then, so the very first poll has files to offer. A first
    // connection usually has nothing to say and slips through.
    if (!rdp->clipboardReady) {
        // Said out loud, because a silent skip here is indistinguishable from
        // a successful announcement that the server ignored — and telling
        // those two apart is most of diagnosing "paste does nothing".
        WLog_INFO("com.macmoba.rdp",
                  "not announcing clipboard yet: capability exchange incomplete");
        return CHANNEL_RC_OK;
    }

    bool haveFiles;
    EnterCriticalSection(&rdp->clipboardLock);
    haveFiles = rdp->pendingLocalFiles != NULL;
    LeaveCriticalSection(&rdp->clipboardLock);

    // The same 15-character limit applies for the whole session when the server
    // never agreed to long names. Offering files anyway fails every time, and
    // takes the text and image formats in the same list down with it.
    if (haveFiles && !rdp->useLongFormatNames) {
        WLog_WARN("com.macmoba.rdp",
                  "server did not negotiate long format names; not offering files");
        haveFiles = false;
    }

    CLIPRDR_FORMAT formats[4] = { 0 };
    UINT32 count = 0;
    if (haveText)
        formats[count++].formatId = CF_UNICODETEXT;
    if (haveImage)
        formats[count++].formatId = CF_DIB;
    if (haveFiles) {
        // Named formats: Windows matches these by name, not by id.
        formats[count].formatId = MACMOBA_LOCAL_FILEDESCRIPTOR_ID;
        formats[count++].formatName = MACMOBA_FILEDESCRIPTOR_NAME;
        formats[count].formatId = MACMOBA_LOCAL_FILECONTENTS_ID;
        formats[count++].formatName = MACMOBA_FILECONTENTS_NAME;
    }

    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = count;
    list.formats = count ? formats : NULL;
    return rdp->cliprdr->ClientFormatList(rdp->cliprdr, &list);
}

/// Server announced what it holds. If there is text, ask for it.
static UINT mm_cliprdr_server_format_list(CliprdrClientContext *context,
                                          const CLIPRDR_FORMAT_LIST *formatList)
{
    MacMobaRDP *rdp = (MacMobaRDP *)context->custom;
    if (!rdp)
        return CHANNEL_RC_OK;

    // Acknowledge first — some servers stall until they see the response.
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    if (context->ClientFormatListResponse)
        context->ClientFormatListResponse(context, &response);

    WLog_INFO("com.macmoba.rdp", "server offered %u clipboard format(s)",
              formatList->numFormats);
    for (UINT32 i = 0; i < formatList->numFormats; i++) {
        WLog_INFO("com.macmoba.rdp", "  format[%u] id=%u name=%s", i,
                  formatList->formats[i].formatId,
                  formatList->formats[i].formatName ? formatList->formats[i].formatName
                                                    : "(none)");
    }
    bool haveText = false;
    bool haveImage = false;
    rdp->remoteFileDescriptorId = 0;
    for (UINT32 i = 0; i < formatList->numFormats; i++) {
        const UINT32 id = formatList->formats[i].formatId;
        const char *name = formatList->formats[i].formatName;
        if (name && strcmp(name, MACMOBA_FILEDESCRIPTOR_NAME) == 0)
            rdp->remoteFileDescriptorId = id;
        else if (id == CF_UNICODETEXT)
            haveText = true;
        else if (id == CF_DIB)
            haveImage = true;
    }
    if (!context->ClientFormatDataRequest)
        return CHANNEL_RC_OK;

    // Files win: an Explorer copy also advertises the file names as text, and
    // pasting the names instead of the files is never what was meant. After
    // that text beats an image, since a document selection offers both.
    UINT32 wanted = 0;
    if (rdp->remoteFileDescriptorId)
        wanted = rdp->remoteFileDescriptorId;
    else if (haveText)
        wanted = CF_UNICODETEXT;
    else if (haveImage)
        wanted = CF_DIB;
    else
        return CHANNEL_RC_OK;

    rdp->requestedFormatId = wanted;
    CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = wanted;
    return context->ClientFormatDataRequest(context, &request);
}

/// The text we asked for has arrived: UTF-16LE, hand it up as UTF-8.
static UINT mm_cliprdr_server_format_data_response(
    CliprdrClientContext *context, const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    MacMobaRDP *rdp = (MacMobaRDP *)context->custom;
    if (!rdp || !response->requestedFormatData)
        return CHANNEL_RC_OK;
    if ((response->common.msgFlags & CB_RESPONSE_FAIL) || response->common.dataLen == 0)
        return CHANNEL_RC_OK;

    if (rdp->remoteFileDescriptorId &&
        rdp->requestedFormatId == rdp->remoteFileDescriptorId) {
        return mm_cliprdr_handle_file_descriptors(rdp, response->requestedFormatData,
                                                  response->common.dataLen);
    }

    if (rdp->requestedFormatId == CF_DIB) {
        if (rdp->onImage)
            rdp->onImage(rdp->userData, response->requestedFormatData,
                         response->common.dataLen);
        return CHANNEL_RC_OK;
    }

    if (!rdp->onClipboard)
        return CHANNEL_RC_OK;
    char *utf8 = ConvertWCharNToUtf8Alloc((const WCHAR *)response->requestedFormatData,
                                          response->common.dataLen / sizeof(WCHAR), NULL);
    if (utf8) {
        rdp->onClipboard(rdp->userData, utf8);
        free(utf8);
    }
    return CHANNEL_RC_OK;
}

/// The server wants the text we advertised.
static UINT mm_cliprdr_server_format_data_request(
    CliprdrClientContext *context, const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    MacMobaRDP *rdp = (MacMobaRDP *)context->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;

    WCHAR *wide = NULL;
    size_t wideLen = 0;
    BYTE *dib = NULL;
    UINT32 dibLen = 0;

    if (rdp && request->requestedFormatId == MACMOBA_LOCAL_FILEDESCRIPTOR_ID)
        return mm_cliprdr_send_local_file_descriptors(rdp, context);

    if (rdp) {
        EnterCriticalSection(&rdp->clipboardLock);
        if (request->requestedFormatId == CF_UNICODETEXT && rdp->pendingLocalText) {
            wide = ConvertUtf8ToWCharAlloc(rdp->pendingLocalText, &wideLen);
        } else if (request->requestedFormatId == CF_DIB && rdp->pendingLocalDib) {
            dibLen = rdp->pendingLocalDibLen;
            dib = malloc(dibLen);
            if (dib)
                memcpy(dib, rdp->pendingLocalDib, dibLen);
        }
        LeaveCriticalSection(&rdp->clipboardLock);
    }

    if (wide) {
        // Windows expects the terminating NUL to be part of the data.
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)((wideLen + 1) * sizeof(WCHAR));
        response.requestedFormatData = (const BYTE *)wide;
    } else if (dib) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = dibLen;
        response.requestedFormatData = dib;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }

    UINT rc = CHANNEL_RC_OK;
    if (context->ClientFormatDataResponse)
        rc = context->ClientFormatDataResponse(context, &response);
    free(wide);
    free(dib);
    return rc;
}

/// Clipboard is ready: state our capabilities and advertise anything already
/// waiting from the Mac side.
static UINT mm_cliprdr_monitor_ready(CliprdrClientContext *context,
                                     const CLIPRDR_MONITOR_READY *monitorReady)
{
    (void)monitorReady;
    MacMobaRDP *rdp = (MacMobaRDP *)context->custom;

    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = 12;
    general.version = CB_CAPS_VERSION_2;
    // File clipboard needs both flags: long names to carry
    // "FileGroupDescriptorW", and the stream flag to allow FileContents.
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED |
                           CB_FILECLIP_NO_FILE_PATHS;

    CLIPRDR_CAPABILITIES capabilities = { 0 };
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    if (context->ClientCapabilities)
        context->ClientCapabilities(context, &capabilities);

    if (!rdp)
        return CHANNEL_RC_OK;
    // Only now may anything be advertised: the capability exchange is done, so
    // FreeRDP knows whether it can write long format names.
    rdp->clipboardReady = true;
    bool haveText, haveImage;
    EnterCriticalSection(&rdp->clipboardLock);
    haveText = rdp->pendingLocalText != NULL;
    haveImage = rdp->pendingLocalDib != NULL;
    LeaveCriticalSection(&rdp->clipboardLock);
    return mm_cliprdr_send_format_list(rdp, haveText, haveImage);
}

/// What the server is willing to do. Recorded because whether long format names
/// were agreed decides whether the file formats can be named at all.
static UINT mm_cliprdr_server_capabilities(CliprdrClientContext *context,
                                           const CLIPRDR_CAPABILITIES *capabilities)
{
    MacMobaRDP *rdp = (MacMobaRDP *)context->custom;
    if (!rdp || !capabilities)
        return CHANNEL_RC_OK;
    for (UINT32 i = 0; i < capabilities->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET *set = &capabilities->capabilitySets[i];
        if (set->capabilitySetType != CB_CAPSTYPE_GENERAL)
            continue;
        const CLIPRDR_GENERAL_CAPABILITY_SET *general =
            (const CLIPRDR_GENERAL_CAPABILITY_SET *)set;
        rdp->useLongFormatNames =
            (general->generalFlags & CB_USE_LONG_FORMAT_NAMES) != 0;
        WLog_INFO("com.macmoba.rdp", "clipboard: long format names %s",
                  rdp->useLongFormatNames ? "agreed" : "NOT agreed");
    }
    return CHANNEL_RC_OK;
}

static void mm_cliprdr_attach(MacMobaRDP *rdp, CliprdrClientContext *context)
{
    WLog_INFO("com.macmoba.rdp", "clipboard channel attached");
    rdp->cliprdr = context;
    context->custom = rdp;
    // A reconnect reuses the same MacMobaRDP, so both have to start false
    // again: the new channel has negotiated nothing yet.
    rdp->clipboardReady = false;
    rdp->useLongFormatNames = false;
    context->MonitorReady = mm_cliprdr_monitor_ready;
    context->ServerCapabilities = mm_cliprdr_server_capabilities;
    context->ServerFormatList = mm_cliprdr_server_format_list;
    context->ServerFormatDataRequest = mm_cliprdr_server_format_data_request;
    context->ServerFormatDataResponse = mm_cliprdr_server_format_data_response;
    context->ServerFileContentsRequest = mm_cliprdr_server_file_contents_request;
    context->ServerFileContentsResponse = mm_cliprdr_server_file_contents_response;
}


// MARK: - File clipboard
//
// Files are not one blob like text or an image: the server sends only a
// descriptor list (names and sizes), and the bytes come later through separate
// FileContents exchanges matched by streamId. That split is what lets the Mac
// side hand out promises and only transfer when something is actually pasted.

/// Split a newline separated list, returning the nth entry in `out`.
static bool mm_nth_line(const char *list, UINT32 index, char *out, size_t outLen)
{
    if (!list)
        return false;
    const char *cursor = list;
    for (UINT32 i = 0; i < index; i++) {
        cursor = strchr(cursor, '\n');
        if (!cursor)
            return false;
        cursor++;
    }
    const char *end = strchr(cursor, '\n');
    size_t len = end ? (size_t)(end - cursor) : strlen(cursor);
    if (len == 0 || len >= outLen)
        return false;
    memcpy(out, cursor, len);
    out[len] = '\0';
    return true;
}

static UINT32 mm_count_lines(const char *list)
{
    if (!list || !*list)
        return 0;
    UINT32 count = 1;
    for (const char *c = list; *c; c++)
        if (*c == '\n')
            count++;
    return count;
}

/// Turn the server's descriptor blob into names + sizes for the Swift side.
static UINT mm_cliprdr_handle_file_descriptors(MacMobaRDP *rdp, const BYTE *data, UINT32 len)
{
    FILEDESCRIPTORW *descriptors = NULL;
    UINT32 count = 0;
    if (cliprdr_parse_file_list(data, len, &descriptors, &count) != CHANNEL_RC_OK)
        return CHANNEL_RC_OK;

    rdp->remoteFileCount = count;

    // One flat buffer of names keeps the callback signature simple; the sizes
    // travel alongside in a parallel array.
    size_t namesCap = (size_t)count * 512 + 1;
    char *names = calloc(1, namesCap);
    uint64_t *sizes = calloc(count ? count : 1, sizeof(uint64_t));
    if (!names || !sizes) {
        free(names);
        free(sizes);
        free(descriptors);
        return CHANNEL_RC_OK;
    }

    for (UINT32 i = 0; i < count; i++) {
        char *utf8 = ConvertWCharNToUtf8Alloc(descriptors[i].cFileName,
                                              ARRAYSIZE(descriptors[i].cFileName), NULL);
        if (utf8) {
            // Windows uses backslashes inside a folder tree; the Mac side wants
            // a relative path it can recreate.
            for (char *c = utf8; *c; c++)
                if (*c == '\\')
                    *c = '/';
            if (i > 0)
                strncat(names, "\n", namesCap - strlen(names) - 1);
            strncat(names, utf8, namesCap - strlen(names) - 1);
            free(utf8);
        }
        sizes[i] = ((uint64_t)descriptors[i].nFileSizeHigh << 32) |
                   (uint64_t)descriptors[i].nFileSizeLow;
    }

    if (rdp->onFileList)
        rdp->onFileList(rdp->userData, names, sizes, count);

    free(names);
    free(sizes);
    free(descriptors);
    return CHANNEL_RC_OK;
}

/// Build the descriptor list for the files we are offering.
static UINT mm_cliprdr_send_local_file_descriptors(MacMobaRDP *rdp,
                                                   CliprdrClientContext *context)
{
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;

    char *list = NULL;
    EnterCriticalSection(&rdp->clipboardLock);
    if (rdp->pendingLocalFiles)
        list = _strdup(rdp->pendingLocalFiles);
    LeaveCriticalSection(&rdp->clipboardLock);

    const UINT32 count = mm_count_lines(list);
    if (!count) {
        free(list);
        response.common.msgFlags = CB_RESPONSE_FAIL;
        return context->ClientFormatDataResponse
                   ? context->ClientFormatDataResponse(context, &response)
                   : CHANNEL_RC_OK;
    }

    FILEDESCRIPTORW *descriptors = calloc(count, sizeof(FILEDESCRIPTORW));
    if (!descriptors) {
        free(list);
        return CHANNEL_RC_OK;
    }

    for (UINT32 i = 0; i < count; i++) {
        char path[1024];
        if (!mm_nth_line(list, i, path, sizeof(path)))
            continue;
        const char *name = strrchr(path, '/');
        name = name ? name + 1 : path;

        WCHAR *wide = ConvertUtf8ToWCharAlloc(name, NULL);
        if (wide) {
            wcsncpy(descriptors[i].cFileName, wide,
                    ARRAYSIZE(descriptors[i].cFileName) - 1);
            free(wide);
        }

        struct stat info;
        if (stat(path, &info) == 0) {
            descriptors[i].nFileSizeLow = (UINT32)(info.st_size & 0xFFFFFFFF);
            descriptors[i].nFileSizeHigh = (UINT32)((UINT64)info.st_size >> 32);
            descriptors[i].dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_SHOWPROGRESSUI;
            descriptors[i].dwFileAttributes =
                S_ISDIR(info.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
        }
    }

    BYTE *blob = NULL;
    UINT32 blobLen = 0;
    const UINT rc = cliprdr_serialize_file_list(descriptors, count, &blob, &blobLen);
    free(descriptors);
    free(list);

    if (rc == CHANNEL_RC_OK && blob) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = blobLen;
        response.requestedFormatData = blob;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }

    UINT sendRc = CHANNEL_RC_OK;
    if (context->ClientFormatDataResponse)
        sendRc = context->ClientFormatDataResponse(context, &response);
    free(blob);
    return sendRc;
}

/// The server wants bytes from a file we advertised.
static UINT mm_cliprdr_server_file_contents_request(
    CliprdrClientContext *context, const CLIPRDR_FILE_CONTENTS_REQUEST *request)
{
    MacMobaRDP *rdp = (MacMobaRDP *)context->custom;
    CLIPRDR_FILE_CONTENTS_RESPONSE response = { 0 };
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    response.streamId = request->streamId;

    char path[1024] = { 0 };
    if (rdp) {
        EnterCriticalSection(&rdp->clipboardLock);
        const bool found = mm_nth_line(rdp->pendingLocalFiles, request->listIndex,
                                       path, sizeof(path));
        LeaveCriticalSection(&rdp->clipboardLock);
        if (!found)
            path[0] = '\0';
    }

    BYTE *buffer = NULL;
    if (path[0]) {
        struct stat info;
        if (request->dwFlags & FILECONTENTS_SIZE) {
            // Size query: the answer is an 8-byte little-endian file size.
            if (stat(path, &info) == 0) {
                buffer = malloc(sizeof(UINT64));
                if (buffer) {
                    const UINT64 size = (UINT64)info.st_size;
                    memcpy(buffer, &size, sizeof(size));
                    response.common.msgFlags = CB_RESPONSE_OK;
                    response.cbRequested = sizeof(UINT64);
                    response.requestedData = buffer;
                }
            }
        } else if (request->dwFlags & FILECONTENTS_RANGE) {
            FILE *file = fopen(path, "rb");
            if (file) {
                const UINT64 offset = ((UINT64)request->nPositionHigh << 32) |
                                      (UINT64)request->nPositionLow;
                if (fseeko(file, (off_t)offset, SEEK_SET) == 0 && request->cbRequested) {
                    buffer = malloc(request->cbRequested);
                    if (buffer) {
                        const size_t read = fread(buffer, 1, request->cbRequested, file);
                        response.common.msgFlags = CB_RESPONSE_OK;
                        response.cbRequested = (UINT32)read;
                        response.requestedData = buffer;
                    }
                }
                fclose(file);
            }
        }
    }

    UINT rc = CHANNEL_RC_OK;
    if (context->ClientFileContentsResponse)
        rc = context->ClientFileContentsResponse(context, &response);
    free(buffer);
    return rc;
}

/// Bytes we asked for have arrived; hand them to whoever is writing the file.
static UINT mm_cliprdr_server_file_contents_response(
    CliprdrClientContext *context, const CLIPRDR_FILE_CONTENTS_RESPONSE *response)
{
    MacMobaRDP *rdp = (MacMobaRDP *)context->custom;
    if (!rdp || !rdp->onFileChunk)
        return CHANNEL_RC_OK;

    UINT32 requestId = 0;
    bool matched = false;
    EnterCriticalSection(&rdp->clipboardLock);
    for (size_t i = 0; i < ARRAYSIZE(rdp->fileRequests); i++) {
        if (rdp->fileRequests[i].active &&
            rdp->fileRequests[i].streamId == response->streamId) {
            requestId = rdp->fileRequests[i].requestId;
            rdp->fileRequests[i].active = false;
            matched = true;
            break;
        }
    }
    LeaveCriticalSection(&rdp->clipboardLock);
    if (!matched)
        return CHANNEL_RC_OK;

    const bool failed = (response->common.msgFlags & CB_RESPONSE_FAIL) != 0;
    rdp->onFileChunk(rdp->userData, requestId,
                     failed ? NULL : response->requestedData,
                     failed ? 0 : response->cbRequested, failed);
    return CHANNEL_RC_OK;
}

void macmoba_rdp_set_file_callbacks(MacMobaRDP *rdp,
                                    MacMobaRDPFileListCallback onFileList,
                                    MacMobaRDPFileChunkCallback onFileChunk)
{
    if (!rdp)
        return;
    rdp->onFileList = onFileList;
    rdp->onFileChunk = onFileChunk;
}

void macmoba_rdp_offer_files(MacMobaRDP *rdp, const char *paths)
{
    if (!rdp)
        return;
    EnterCriticalSection(&rdp->clipboardLock);
    free(rdp->pendingLocalFiles);
    rdp->pendingLocalFiles = (paths && *paths) ? _strdup(paths) : NULL;
    const bool haveFiles = rdp->pendingLocalFiles != NULL;
    const bool haveText = rdp->pendingLocalText != NULL;
    const bool haveImage = rdp->pendingLocalDib != NULL;
    LeaveCriticalSection(&rdp->clipboardLock);
    WLog_INFO("com.macmoba.rdp", "offering local clipboard: files=%d", haveFiles);
    mm_cliprdr_send_format_list(rdp, haveText, haveImage);
}

void macmoba_rdp_offer_all(MacMobaRDP *rdp, const char *paths, const char *utf8,
                           const uint8_t *dib, uint32_t dibLen)
{
    if (!rdp)
        return;
    EnterCriticalSection(&rdp->clipboardLock);
    free(rdp->pendingLocalFiles);
    rdp->pendingLocalFiles = (paths && *paths) ? _strdup(paths) : NULL;
    free(rdp->pendingLocalText);
    rdp->pendingLocalText = (utf8 && *utf8) ? _strdup(utf8) : NULL;
    free(rdp->pendingLocalDib);
    rdp->pendingLocalDib = NULL;
    rdp->pendingLocalDibLen = 0;
    if (dib && dibLen) {
        rdp->pendingLocalDib = malloc(dibLen);
        if (rdp->pendingLocalDib) {
            memcpy(rdp->pendingLocalDib, dib, dibLen);
            rdp->pendingLocalDibLen = dibLen;
        }
    }
    const bool haveFiles = rdp->pendingLocalFiles != NULL;
    const bool haveText = rdp->pendingLocalText != NULL;
    const bool haveImage = rdp->pendingLocalDib != NULL;
    LeaveCriticalSection(&rdp->clipboardLock);
    WLog_INFO("com.macmoba.rdp",
              "offering local clipboard: files=%d text=%d image=%d",
              haveFiles, haveText, haveImage);
    mm_cliprdr_send_format_list(rdp, haveText, haveImage);
}

bool macmoba_rdp_request_file_range(MacMobaRDP *rdp, uint32_t requestId,
                                    uint32_t index, uint64_t offset, uint32_t length)
{
    if (!rdp || !rdp->cliprdr || !rdp->cliprdr->ClientFileContentsRequest)
        return false;
    if (index >= rdp->remoteFileCount)
        return false;

    UINT32 streamId = 0;
    bool slotFound = false;
    EnterCriticalSection(&rdp->clipboardLock);
    streamId = ++rdp->nextStreamId;
    for (size_t i = 0; i < ARRAYSIZE(rdp->fileRequests); i++) {
        if (!rdp->fileRequests[i].active) {
            rdp->fileRequests[i].active = true;
            rdp->fileRequests[i].streamId = streamId;
            rdp->fileRequests[i].requestId = requestId;
            slotFound = true;
            break;
        }
    }
    LeaveCriticalSection(&rdp->clipboardLock);
    if (!slotFound)
        return false;

    CLIPRDR_FILE_CONTENTS_REQUEST request = { 0 };
    request.common.msgType = CB_FILECONTENTS_REQUEST;
    request.streamId = streamId;
    request.listIndex = index;
    request.dwFlags = FILECONTENTS_RANGE;
    request.nPositionLow = (UINT32)(offset & 0xFFFFFFFF);
    request.nPositionHigh = (UINT32)(offset >> 32);
    request.cbRequested = length;
    return rdp->cliprdr->ClientFileContentsRequest(rdp->cliprdr, &request) == CHANNEL_RC_OK;
}

void macmoba_rdp_set_clipboard_callback(MacMobaRDP *rdp,
                                        MacMobaRDPClipboardCallback onClipboard,
                                        MacMobaRDPImageCallback onImage)
{
    if (!rdp)
        return;
    rdp->onClipboard = onClipboard;
    rdp->onImage = onImage;
}

void macmoba_rdp_offer_clipboard(MacMobaRDP *rdp, const char *utf8,
                                 const uint8_t *dib, uint32_t dibLen)
{
    if (!rdp)
        return;
    EnterCriticalSection(&rdp->clipboardLock);
    free(rdp->pendingLocalText);
    rdp->pendingLocalText = (utf8 && *utf8) ? _strdup(utf8) : NULL;
    free(rdp->pendingLocalDib);
    rdp->pendingLocalDib = NULL;
    rdp->pendingLocalDibLen = 0;
    if (dib && dibLen) {
        rdp->pendingLocalDib = malloc(dibLen);
        if (rdp->pendingLocalDib) {
            memcpy(rdp->pendingLocalDib, dib, dibLen);
            rdp->pendingLocalDibLen = dibLen;
        }
    }
    const bool haveText = rdp->pendingLocalText != NULL;
    const bool haveImage = rdp->pendingLocalDib != NULL;
    LeaveCriticalSection(&rdp->clipboardLock);
    WLog_INFO("com.macmoba.rdp", "offering local clipboard: text=%d image=%d",
              haveText, haveImage);
    mm_cliprdr_send_format_list(rdp, haveText, haveImage);
}

bool macmoba_rdp_can_resize(MacMobaRDP *rdp)
{
    return rdp && rdp->disp && rdp->disp->SendMonitorLayout;
}

void macmoba_rdp_request_resize(MacMobaRDP *rdp, int width, int height)
{
    if (!macmoba_rdp_can_resize(rdp))
        return;

    // A multi-monitor session must never be sent this: the layout below is a
    // single rectangle at the origin, so the server would drop back to one
    // monitor and shrink the framebuffer, leaving every screen whose rectangle
    // starts outside the new size with nothing to show. The Swift side already
    // refuses; this is the backstop for any other caller.
    if (freerdp_settings_get_bool(rdp->context->settings, FreeRDP_UseMultimon)) {
        WLog_WARN("com.macmoba.rdp",
                  "ignoring a resize to %dx%d: the session spans monitors", width, height);
        return;
    }

    // The protocol requires an even width and sane bounds; Windows rejects the
    // whole layout otherwise and the session keeps its old size.
    UINT32 w = (UINT32)(width & ~1);
    UINT32 h = (UINT32)(height & ~1);
    if (w < 200) w = 200;
    if (h < 200) h = 200;
    if (w > 8192) w = 8192;
    if (h > 8192) h = 8192;

    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Left = 0;
    layout.Top = 0;
    layout.Width = w;
    layout.Height = h;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = 100;
    layout.DeviceScaleFactor = 100;
    // Physical size is optional; 0 tells the server to work it out.
    layout.PhysicalWidth = 0;
    layout.PhysicalHeight = 0;

    WLog_INFO("com.macmoba.rdp", "display-control resize to %ux%u", w, h);
    rdp->disp->SendMonitorLayout(rdp->disp, 1, &layout);
}

int macmoba_rdp_max_monitors(MacMobaRDP *rdp)
{
    if (!macmoba_rdp_can_resize(rdp))
        return 0;
    // The capability PDU arrives shortly after the channel opens. Before it
    // does, one monitor is the only safe assumption.
    return rdp->maxMonitors > 0 ? (int)rdp->maxMonitors : 1;
}

bool macmoba_rdp_send_monitor_layout(MacMobaRDP *rdp,
                                     const MacMobaRDPMonitor *monitors, int count)
{
    if (!macmoba_rdp_can_resize(rdp) || !monitors || count < 1)
        return false;
    if (count > macmoba_rdp_max_monitors(rdp)) {
        WLog_WARN("com.macmoba.rdp",
                  "server accepts %d monitor(s), not %d — layout not sent",
                  macmoba_rdp_max_monitors(rdp), count);
        return false;
    }
    if (count > 16)
        count = 16;

    DISPLAY_CONTROL_MONITOR_LAYOUT layouts[16];
    memset(layouts, 0, sizeof(layouts));
    bool sawPrimary = false;
    for (int i = 0; i < count; i++) {
        // Same bounds the single-monitor path enforces: an out-of-range
        // rectangle makes Windows reject the WHOLE layout, so the session
        // silently keeps its old size.
        UINT32 w = (UINT32)(monitors[i].width & ~1);
        UINT32 h = (UINT32)(monitors[i].height & ~1);
        if (w < DISPLAY_CONTROL_MIN_MONITOR_WIDTH) w = DISPLAY_CONTROL_MIN_MONITOR_WIDTH;
        if (h < DISPLAY_CONTROL_MIN_MONITOR_HEIGHT) h = DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
        if (w > DISPLAY_CONTROL_MAX_MONITOR_WIDTH) w = DISPLAY_CONTROL_MAX_MONITOR_WIDTH;
        if (h > DISPLAY_CONTROL_MAX_MONITOR_HEIGHT) h = DISPLAY_CONTROL_MAX_MONITOR_HEIGHT;

        layouts[i].Flags = monitors[i].isPrimary ? DISPLAY_CONTROL_MONITOR_PRIMARY : 0;
        if (monitors[i].isPrimary)
            sawPrimary = true;
        layouts[i].Left = monitors[i].x;
        layouts[i].Top = monitors[i].y;
        layouts[i].Width = w;
        layouts[i].Height = h;
        layouts[i].Orientation = ORIENTATION_LANDSCAPE;
        // 100 for a 1x display, 200 for Retina. Out-of-range values are
        // rejected along with everything else in the layout.
        UINT32 scale = monitors[i].scalePercent;
        if (scale < 100) scale = 100;
        if (scale > 500) scale = 500;
        layouts[i].DesktopScaleFactor = scale;
        layouts[i].DeviceScaleFactor = 100;
        layouts[i].PhysicalWidth = 0;
        layouts[i].PhysicalHeight = 0;
    }
    // Exactly one primary, or the layout is invalid.
    if (!sawPrimary)
        layouts[0].Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;

    WLog_INFO("com.macmoba.rdp", "display-control layout: %d monitor(s), first %ux%u",
              count, layouts[0].Width, layouts[0].Height);
    return rdp->disp->SendMonitorLayout(rdp->disp, (UINT32)count, layouts) == CHANNEL_RC_OK;
}

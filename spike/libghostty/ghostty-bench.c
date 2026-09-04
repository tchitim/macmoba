// Feed libghostty-vt the same three payloads MacMoba's
// TerminalThroughputBenchmark feeds SwiftTerm, so the two numbers are
// comparable rather than merely adjacent.
//
// Same terminal geometry (120x40), same generated content, same measurement:
// wall time around the write of one big buffer.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <ghostty/vt.h>

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// A growable byte buffer, so the payloads are built exactly like the Swift
// ones: string concatenation in a loop, then measured as one slice.
typedef struct { char *p; size_t len, cap; } Buf;

static void buf_add(Buf *b, const char *s) {
    size_t n = strlen(s);
    if (b->len + n + 1 > b->cap) {
        while (b->len + n + 1 > b->cap) b->cap = b->cap ? b->cap * 2 : 1 << 20;
        b->p = realloc(b->p, b->cap);
        if (!b->p) { fprintf(stderr, "oom\n"); exit(1); }
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = 0;
}

static Buf make_plain(int lines) {
    Buf b = {0}; char line[256];
    for (int i = 0; i < lines; i++) {
        snprintf(line, sizeof line,
                 "-rw-r--r--  1 root root  4096 Aug 21 09:00 file-%d.log\r\n", i);
        buf_add(&b, line);
    }
    return b;
}

static Buf make_coloured(int lines) {
    Buf b = {0}; char line[512];
    for (int i = 0; i < lines; i++) {
        snprintf(line, sizeof line,
                 "\x1b[32mINFO\x1b[0m \x1b[1;34mmodule-%d\x1b[0m "
                 "compiled \x1b[33m%d\x1b[0m objects in \x1b[36m1.2s\x1b[0m\r\n",
                 i % 40, i);
        buf_add(&b, line);
    }
    return b;
}

static Buf make_cjk(int lines) {
    Buf b = {0}; char line[512];
    for (int i = 0; i < lines; i++) {
        snprintf(line, sizeof line,
                 "第 %d 行：連線成功，正在同步遠端檔案與設定內容\r\n", i);
        buf_add(&b, line);
    }
    return b;
}

static void run(const char *name, Buf payload) {
    GhosttyTerminal term;
    if (ghostty_terminal_new(NULL, &term, 120, 40) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "ghostty_terminal_new failed\n");
        exit(1);
    }

    double t0 = now_seconds();
    ghostty_terminal_vt_write(term, (const uint8_t *)payload.p, payload.len);
    double secs = now_seconds() - t0;

    double mb = (double)payload.len / 1048576.0;
    printf("feed  %-10s  %6.1f MB in %5.2fs  =  %6.1f MB/s\n",
           name, mb, secs, mb / secs);

    ghostty_terminal_free(term);
    free(payload.p);
}

int main(void) {
    // Same line counts as the Swift benchmark, so the byte totals match too.
    run("plain",    make_plain(200000));
    run("coloured", make_coloured(120000));
    run("CJK",      make_cjk(120000));
    return 0;
}

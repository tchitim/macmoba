// Does ghostty_terminal_vt_write actually do the work, or defer it?
//
// A throughput number is worthless if the write only queued the bytes. This
// feeds the same payloads and then reads the screen back through the
// formatter, so the number above it can be trusted — or thrown away.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ghostty/vt.h>

static void dump_tail(const char *label, const char *payload, size_t len,
                      const char *expect) {
    GhosttyTerminal term;
    if (ghostty_terminal_new(NULL, &term, 120, 40) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "terminal_new failed\n"); exit(1);
    }
    ghostty_terminal_vt_write(term, (const uint8_t *)payload, len);

    GhosttyFormatterTerminalOptions opts = {0};
    opts.trim = true;
    GhosttyFormatter fmt;
    if (ghostty_formatter_terminal_new(NULL, &fmt, term, opts) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "formatter_new failed\n"); exit(1);
    }
    uint8_t *out = NULL; size_t out_len = 0;
    if (ghostty_formatter_format_alloc(fmt, NULL, &out, &out_len) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "format_alloc failed\n"); exit(1);
    }

    // The last non-empty line of the screen: proof the whole stream was
    // consumed and scrolled, not just the head of it.
    char *text = malloc(out_len + 1);
    memcpy(text, out, out_len); text[out_len] = 0;
    // Search BEFORE the newline-splitting loop below chops the string into
    // pieces — searching after it only ever sees the first line.
    int found = strstr(text, expect) != NULL;
    char *last = text, *p = text, *line_start = text;
    for (; *p; p++) {
        if (*p == '\n') { *p = 0; if (*line_start) last = line_start; line_start = p + 1; }
    }
    if (*line_start) last = line_start;

    printf("%-9s screen bytes=%-7zu last line: %s\n", label, out_len, last);
    printf("%-9s contains \"%s\": %s\n", label, expect,
           found ? "YES" : "NO  <-- data was NOT processed");

    free(text);
    ghostty_formatter_free(fmt);
    ghostty_terminal_free(term);
}

int main(void) {
    // Small, hand-checkable payloads: 45 lines into a 40-row screen, so the
    // first lines must have scrolled off and the last must be line 44.
    char buf[8192]; size_t n = 0;
    for (int i = 0; i < 45; i++)
        n += snprintf(buf + n, sizeof buf - n, "line-%d\r\n", i);
    dump_tail("plain", buf, n, "line-44");

    n = 0;
    for (int i = 0; i < 45; i++)
        n += snprintf(buf + n, sizeof buf - n,
                      "\x1b[32mINFO\x1b[0m row-%d\r\n", i);
    dump_tail("coloured", buf, n, "row-44");

    n = 0;
    for (int i = 0; i < 45; i++)
        n += snprintf(buf + n, sizeof buf - n, "第 %d 行：連線成功\r\n", i);
    dump_tail("CJK", buf, n, "第 44 行：連線成功");
    return 0;
}

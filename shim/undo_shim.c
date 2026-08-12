/*
 * libundo.so - LD_PRELOAD shim that journals destructive filesystem calls
 * so the `undo` CLI can revert them.
 *
 * Armed only when UNDO_SESSION points at a session directory. For every
 * destructive libc call it saves the affected file into
 * $UNDO_SESSION/data/ (hardlink when possible, copy when the data would
 * be modified in place) and appends a record to $UNDO_SESSION/journal.
 *
 * Journal line format: op<TAB>field<TAB>field...
 * Fields are percent-encoded (%, control bytes, DEL).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif

#define DEFAULT_MAX_BYTES (256UL * 1024 * 1024)
#define DEFAULT_MIN_FREE (2UL << 30)

/* Mirrors the UNDO_MAX_STORE default in cmd/undo/main.go. The shim only
 * reads it to size the per-session cap; gc is what enforces it. */
#define DEFAULT_MAX_STORE (1UL << 30)

/* how many bytes of backups may go by between two statvfs calls */
#define FREE_CHECK_INTERVAL (64UL << 20)

static __thread int in_shim;

/* asks for a thread-exit callback; defined with the cleanup itself below */
static void tls_arm(void);

#define REAL(name, ret, ...)                                                 \
    static ret (*real_##name)(__VA_ARGS__);                                  \
    if (!real_##name)                                                        \
        real_##name = (ret (*)(__VA_ARGS__))dlsym(RTLD_NEXT, #name);

/* ---------- session state ---------- */

/* The session normally arrives in UNDO_SESSION, exported by the hook
 * before each command. Nushell cannot do that: it runs rm, mv, cp and
 * save inside its own process, so there is no child to export to, and
 * `$env.X = ...` only builds the environment handed to externals. It
 * never touches the environment of the running nu, which is the process
 * this shim is loaded into.
 *
 * So the nu hook exports UNDO_SESSION_PTR once, pointing at a file it
 * rewrites with the current session before every command, and we read
 * the session from there instead.
 *
 * Only nushell sets UNDO_SESSION_PTR. Every other shell exports
 * UNDO_SESSION and returns above, paying one getenv that finds nothing. */
static __thread char ptr_path[PATH_MAX];
static __thread char ptr_buf[PATH_MAX];
static __thread int ptr_fd = -1;

static const char *session_from_ptr(void)
{
    const char *path = getenv("UNDO_SESSION_PTR");
    if (!path || *path != '/')
        return NULL;
    if (ptr_fd < 0 || strcmp(ptr_path, path) != 0) {
        if (ptr_fd >= 0)
            close(ptr_fd);
        REAL(open, int, const char *, int, ...);
        ptr_fd = real_open(path, O_RDONLY | O_CLOEXEC);
        if (ptr_fd < 0)
            return NULL;
        snprintf(ptr_path, sizeof ptr_path, "%s", path);
        tls_arm();
    }
    /* held open and pread from offset 0, so a command costs one syscall
     * on a page-cached file rather than an open/read/close */
    ssize_t n = pread(ptr_fd, ptr_buf, sizeof ptr_buf - 1, 0);
    if (n <= 0)
        return NULL;
    ptr_buf[n] = 0;
    char *nl = strchr(ptr_buf, '\n');
    if (nl)
        *nl = 0;
    return ptr_buf[0] == '/' ? ptr_buf : NULL;
}

static const char *session_dir(void)
{
    const char *s = getenv("UNDO_SESSION");
    if (!s || !*s || *s != '/')
        return session_from_ptr();
    return s;
}

/* File scope, not function scope, so thread_cleanup() can reach them. */
static __thread char jrn_dir[PATH_MAX];
static __thread int jrn_fd = -1;

static int journal_fd(const char *dir)
{
    if (!dir)
        return -1;
    if (jrn_fd >= 0 && strcmp(jrn_dir, dir) == 0)
        return jrn_fd;
    if (jrn_fd >= 0)
        close(jrn_fd);
    char path[PATH_MAX];
    if ((size_t)snprintf(path, sizeof path, "%s/journal", dir) >= sizeof path)
        return jrn_fd = -1;
    REAL(open, int, const char *, int, ...);
    jrn_fd = real_open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (jrn_fd >= 0) {
        snprintf(jrn_dir, sizeof jrn_dir, "%s", dir);
        tls_arm();
    }
    return jrn_fd;
}

static int armed(void)
{
    return !in_shim && session_dir() != NULL;
}

/* ---------- journal writing ---------- */

static void enc_append(char *dst, size_t cap, size_t *len, const char *s)
{
    static const char hex[] = "0123456789ABCDEF";
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '%' || *p < 0x20 || *p == 0x7f) {
            if (*len + 3 >= cap)
                return;
            dst[(*len)++] = '%';
            dst[(*len)++] = hex[*p >> 4];
            dst[(*len)++] = hex[*p & 15];
        } else {
            if (*len + 1 >= cap)
                return;
            dst[(*len)++] = (char)*p;
        }
    }
}

static int recording_stopped(const char *dir);

/* jwrite("op", field1, field2, NULL) */
static void jwrite(const char *op, ...)
{
    /* One getenv for the pair below, not one each: this runs for every
     * journal line and getenv walks environ. */
    const char *dir = session_dir();
    if (!dir)
        return;
    /* Once a ceiling has been hit the journal stops growing too. It is
     * small next to the backups, but the point of the free-space floor is
     * that undo stops touching a filesystem in trouble, and a record of
     * changes whose backups were never taken is not worth a byte of it. */
    if (recording_stopped(dir))
        return;
    int fd = journal_fd(dir);
    if (fd < 0)
        return;
    char line[4 * PATH_MAX];
    size_t len = 0;
    enc_append(line, sizeof line, &len, op);
    va_list ap;
    va_start(ap, op);
    const char *f;
    while ((f = va_arg(ap, const char *)) != NULL) {
        if (len + 1 < sizeof line)
            line[len++] = '\t';
        enc_append(line, sizeof line, &len, f);
    }
    va_end(ap);
    if (len + 1 < sizeof line)
        line[len++] = '\n';
    ssize_t r = write(fd, line, len);
    (void)r;
}

/* ---------- path helpers ---------- */

static int abs_path(int dirfd, const char *path, char *out)
{
    if (!path || !*path)
        return -1;
    if (path[0] == '/') {
        if (strlen(path) >= PATH_MAX)
            return -1;
        strcpy(out, path);
        return 0;
    }
    char base[PATH_MAX];
    if (dirfd == AT_FDCWD) {
        if (!getcwd(base, sizeof base))
            return -1;
    } else {
        char proc[64];
        snprintf(proc, sizeof proc, "/proc/self/fd/%d", dirfd);
        ssize_t n = readlink(proc, base, sizeof base - 1);
        if (n < 0)
            return -1;
        base[n] = 0;
    }
    if ((size_t)snprintf(out, PATH_MAX, "%s/%s", base, path) >= PATH_MAX)
        return -1;
    return 0;
}

/* Path behind an open descriptor, for the calls that are handed an fd and
 * no name. /proc is the only way to ask, and it answers for things that
 * are not files in the tree: a pipe or socket reads back as "pipe:[...]",
 * and a file whose name is already gone gets " (deleted)" appended. Both
 * are useless to restore, so take only an absolute path.
 *
 * A real file named "... (deleted)" is indistinguishable here and gets
 * skipped. Nothing better is available, and the cost is one missed backup
 * for a name nobody types. */
static int fd_path(int fd, char *out)
{
    if (fd < 0)
        return -1;
    char proc[64];
    snprintf(proc, sizeof proc, "/proc/self/fd/%d", fd);
    ssize_t n = readlink(proc, out, PATH_MAX - 1);
    if (n < 0 || n >= PATH_MAX - 1)
        return -1;
    out[n] = 0;
    if (out[0] != '/')
        return -1;
    const char del[] = " (deleted)";
    size_t dlen = sizeof del - 1;
    if ((size_t)n >= dlen && strcmp(out + n - dlen, del) == 0)
        return -1;
    return 0;
}

/* ---------- backups ---------- */

/* Hand-rolled so the shim never references strtoul. Under _GNU_SOURCE a
 * modern glibc redirects strtoul to __isoc23_strtoul, which only exists
 * in glibc >= 2.38 and makes the .so refuse to load on older distros
 * (Debian 12, Ubuntu 22.04, RHEL 9). */
static unsigned long parse_ulong(const char *s)
{
    unsigned long v = 0;
    if (!s)
        return 0;
    while (*s == ' ' || *s == '\t')
        s++;
    for (; *s >= '0' && *s <= '9'; s++) {
        if (v > (ULONG_MAX - (unsigned long)(*s - '0')) / 10)
            return ULONG_MAX; /* saturate rather than wrap */
        v = v * 10 + (unsigned long)(*s - '0');
    }
    return v;
}

static unsigned long max_bytes(void)
{
    static unsigned long v;
    if (!v) {
        v = parse_ulong(getenv("UNDO_MAX_BYTES"));
        if (!v)
            v = DEFAULT_MAX_BYTES;
    }
    return v;
}

/* A limit read from the environment once and remembered, where an
 * explicit 0 means no limit. Distinct from max_bytes() above, whose 0 has
 * always meant "unset", which is why that one cannot express "unlimited".
 *
 * Cached because these are read on every backup, and getenv walks environ
 * each time. Nothing changes UNDO_* mid-process except the session, which
 * is read separately. */
static unsigned long min_free(void)
{
    static unsigned long v;
    static int loaded;
    if (!loaded) {
        loaded = 1;
        const char *s = getenv("UNDO_MIN_FREE");
        v = (!s || !*s) ? DEFAULT_MIN_FREE : parse_ulong(s);
    }
    return v;
}

/* Default: half the store budget, so the store can hold more than one
 * session. A per-session cap equal to the whole store budget means one
 * large command evicts every other session the moment gc runs, which is
 * a coincidence of two numbers rather than a decision. Following
 * UNDO_MAX_STORE also means raising the store budget raises this. */
static unsigned long max_session(void)
{
    static unsigned long v;
    static int loaded;
    if (!loaded) {
        loaded = 1;
        const char *s = getenv("UNDO_MAX_SESSION");
        if (s && *s) {
            v = parse_ulong(s);
            return v;
        }
        const char *st = getenv("UNDO_MAX_STORE");
        unsigned long store =
            (st && *st) ? parse_ulong(st) : DEFAULT_MAX_STORE;
        v = store / 2;
    }
    return v;
}

/* ---------- space guards ---------- */

/* Two ceilings, both enforced here rather than by the shell hook. The hook
 * only gets a turn when the command returns, and the command that fills a
 * disk is the one that runs for a day: an editor, a dev server, an agent.
 * By the time precmd could call `undo gc` the damage is done, and gc would
 * skip the session anyway because it is still live.
 *
 * Whichever ceiling trips first, the session stops recording and drops a
 * `degraded` file saying why. Stopping early loses undo history, which is
 * bad. Filling the filesystem takes down everything else on the machine,
 * which is worse, and a tool that exists to save you from mistakes has no
 * business making that one.
 *
 * The counter lives in a shared mapping, not a static, so the thousand
 * compilers a build forks all bill to the same session budget. */
struct budget {
    uint64_t saved;       /* bytes of backups written by every process */
    uint64_t since_check; /* bytes since the last statvfs, shared */
    uint32_t stopped;     /* set once, by whoever trips a ceiling first */
};

/* file scope for the same reason as the journal descriptor above */
static __thread char bgt_dir[PATH_MAX];
static __thread struct budget *bgt_map;

static struct budget *budget_map(const char *dir)
{
    if (!dir)
        return NULL;
    if (bgt_map && strcmp(bgt_dir, dir) == 0)
        return bgt_map;
    if (bgt_map) {
        munmap(bgt_map, sizeof *bgt_map);
        bgt_map = NULL;
    }
    char path[PATH_MAX];
    if ((size_t)snprintf(path, sizeof path, "%s/budget", dir) >= sizeof path)
        return NULL;
    REAL(open, int, const char *, int, ...);
    int fd = real_open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0)
        return NULL;
    /* only grow it: a racing process may already have mapped this page,
     * and truncating back to zero would reset a budget mid-session */
    struct stat st;
    REAL(ftruncate, int, int, off_t);
    if (fstat(fd, &st) != 0 ||
        (st.st_size < (off_t)sizeof *bgt_map &&
         real_ftruncate(fd, (off_t)sizeof *bgt_map) != 0)) {
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, sizeof *bgt_map, PROT_READ | PROT_WRITE, MAP_SHARED,
                   fd, 0);
    close(fd);
    if (p == MAP_FAILED)
        return NULL;
    bgt_map = p;
    snprintf(bgt_dir, sizeof bgt_dir, "%s", dir);
    tls_arm();
    return bgt_map;
}

/* A thread that exits takes its TLS variables with it, but not the
 * descriptor and the mapping they point at: those belong to the process
 * and stay until it dies. A program that does its file work on
 * short-lived threads therefore leaked a journal descriptor and a page
 * per thread, until it ran out of descriptors. Nothing here is shared
 * between threads, so this is a release, not a synchronisation problem.
 *
 * A key destructor is the only thread-exit hook C gives us. */
static pthread_key_t tls_key;
static pthread_once_t tls_once = PTHREAD_ONCE_INIT;

static void thread_cleanup(void *unused)
{
    (void)unused;
    if (jrn_fd >= 0) {
        close(jrn_fd);
        jrn_fd = -1;
    }
    if (bgt_map) {
        munmap(bgt_map, sizeof *bgt_map);
        bgt_map = NULL;
    }
    if (ptr_fd >= 0) {
        close(ptr_fd);
        ptr_fd = -1;
    }
}

static void tls_key_init(void)
{
    pthread_key_create(&tls_key, thread_cleanup);
}

static void tls_arm(void)
{
    pthread_once(&tls_once, tls_key_init);
    /* the value is only a flag: glibc skips the destructor for a NULL one */
    pthread_setspecific(tls_key, (void *)1);
}

/* Records why recording stopped, once per session. Called before the
 * filesystem is actually full, so this small write still has room. */
static void budget_stop(const char *dir, const char *why)
{
    struct budget *b = budget_map(dir);
    if (b && __atomic_exchange_n(&b->stopped, 1, __ATOMIC_RELAXED))
        return; /* someone else already wrote the marker */
    if (!dir)
        return;
    char path[PATH_MAX];
    if ((size_t)snprintf(path, sizeof path, "%s/degraded", dir) >= sizeof path)
        return;
    /* O_EXCL so this really is once per session even when the mapping
     * above could not be made and every process reaches this point */
    REAL(open, int, const char *, int, ...);
    int fd = real_open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0)
        return;
    char msg[512];
    int n = snprintf(msg, sizeof msg, "%s\n", why);
    if (n > 0) {
        ssize_t w = write(fd, msg, (size_t)n);
        (void)w;
    }
    close(fd);
}

static int recording_stopped(const char *dir)
{
    struct budget *b = budget_map(dir);
    return b && __atomic_load_n(&b->stopped, __ATOMIC_RELAXED);
}

/* true if `want` more bytes of backup are affordable */
static int budget_ok(const char *dir, unsigned long want)
{
    struct budget *b = budget_map(dir);
    if (b && __atomic_load_n(&b->stopped, __ATOMIC_RELAXED))
        return 0;

    char why[512];
    unsigned long cap = max_session();
    if (b && cap) {
        unsigned long used = __atomic_load_n(&b->saved, __ATOMIC_RELAXED);
        if (used + want > cap) {
            snprintf(why, sizeof why,
                     "stopped recording: session reached the %lu MB budget "
                     "(UNDO_MAX_SESSION)",
                     (cap + (1UL << 19)) >> 20);
            budget_stop(dir, why);
            return 0;
        }
    }

    unsigned long floor = min_free();
    if (!floor)
        return 1;

    /* statvfs on every backup would be wasteful and on none would be
     * useless, so amortise it over the bytes actually written. The
     * counter lives in the shared mapping: per-thread, every thread got
     * its own 64M of slack and a busy process checked far more often
     * than intended while a session spread over many processes checked
     * far less. The first backup of a session always checks, so a
     * session opened on an already-full disk never gets going. */
    if (b) {
        uint64_t used = __atomic_load_n(&b->saved, __ATOMIC_RELAXED);
        uint64_t since =
            __atomic_add_fetch(&b->since_check, want, __ATOMIC_RELAXED);
        if (used != 0 && since < FREE_CHECK_INTERVAL)
            return 1;
        __atomic_store_n(&b->since_check, 0, __ATOMIC_RELAXED);
    }
    /* no mapping: cannot amortise, so pay for the check every time */

    struct statvfs vfs;
    if (!dir || statvfs(dir, &vfs) != 0)
        return 1; /* cannot tell: let the session budget do the limiting */
    unsigned long avail =
        (unsigned long)vfs.f_bavail * (unsigned long)vfs.f_frsize;
    if (avail < floor + want) {
        snprintf(why, sizeof why,
                 "stopped recording: %lu MB free on the store's filesystem, "
                 "floor is %lu MB (UNDO_MIN_FREE)",
                 (avail + (1UL << 19)) >> 20,
                 (floor + (1UL << 19)) >> 20);
        budget_stop(dir, why);
        return 0;
    }
    return 1;
}

static void budget_add(const char *dir, unsigned long n)
{
    struct budget *b = budget_map(dir);
    if (b)
        __atomic_add_fetch(&b->saved, (uint64_t)n, __ATOMIC_RELAXED);
}

static int backup_name(char *out)
{
    static unsigned long counter;
    const char *dir = session_dir();
    if (!dir)
        return -1;
    unsigned long n = __atomic_add_fetch(&counter, 1, __ATOMIC_RELAXED);
    if ((size_t)snprintf(out, PATH_MAX, "%s/data/%d-%lu", dir,
                         (int)getpid(), n) >= PATH_MAX)
        return -1;
    return 0;
}

static int copy_file(const char *src, const char *dst)
{
    REAL(open, int, const char *, int, ...);
    int in = real_open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0)
        return -1;
    struct stat st;
    if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode) ||
        (unsigned long)st.st_size > max_bytes()) {
        close(in);
        errno = EFBIG;
        return -1;
    }
    int out = real_open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (out < 0) {
        close(in);
        return -1;
    }
    char buf[1 << 16];
    ssize_t n;
    int ok = 1;
    while ((n = read(in, buf, sizeof buf)) > 0) {
        char *p = buf;
        while (n > 0) {
            ssize_t w = write(out, p, (size_t)n);
            if (w < 0) {
                ok = 0;
                break;
            }
            p += w;
            n -= w;
        }
        if (!ok)
            break;
    }
    if (n < 0)
        ok = 0;
    fchmod(out, st.st_mode & 07777);
    struct timespec times[2] = {st.st_atim, st.st_mtim};
    futimens(out, times);
    close(in);
    close(out);
    if (!ok)
        unlink(dst);
    return ok ? 0 : -1;
}

/* Save `abs` before it is destroyed. When the original inode survives the
 * operation untouched (unlink, rename target), a hardlink is enough; when
 * data is rewritten in place (O_TRUNC, plain write opens), we need a full
 * copy.
 *
 * A hardlink costs no extra inode data, which used to read as "costs
 * nothing", so the per-file cap was only ever applied to copies. It is not
 * free: the link is what stops the original blocks being returned when the
 * file is unlinked, so a deleted 4 GB file is 4 GB the store is holding.
 * Both paths are charged the same now. */
static int save_file(const char *abs, int need_copy, char *bak)
{
    struct stat st;
    if (lstat(abs, &st) != 0 || !S_ISREG(st.st_mode))
        return -1;
    if ((unsigned long)st.st_size > max_bytes()) {
        errno = EFBIG;
        return -1;
    }
    const char *dir = session_dir();
    if (!budget_ok(dir, (unsigned long)st.st_size)) {
        errno = ENOSPC;
        return -1;
    }

    /* Names can collide when a shell execs its last command without
     * forking (same pid, counter reset); retry with the next counter. */
    for (int tries = 0; tries < 1000; tries++) {
        if (backup_name(bak) != 0)
            return -1;
        if (!need_copy) {
            REAL(link, int, const char *, const char *);
            if (real_link(abs, bak) == 0) {
                budget_add(dir, (unsigned long)st.st_size);
                return 0;
            }
            if (errno == EEXIST)
                continue;
            /* cross-device etc: fall through to a copy under this name */
        }
        if (copy_file(abs, bak) == 0) {
            budget_add(dir, (unsigned long)st.st_size);
            return 0;
        }
        if (errno != EEXIST)
            break;
    }
    if (getenv("UNDO_DEBUG"))
        fprintf(stderr, "undo-shim: could not save %s: %s\n", abs,
                strerror(errno));
    return -1;
}

/* ---------- ignore rules ---------- */

/* true if `seg` appears in `abs` as a whole path component */
static int seg_match(const char *abs, const char *seg, size_t seglen)
{
    const char *p = abs;
    while ((p = strstr(p, seg)) != NULL) {
        char before = (p == abs) ? '/' : p[-1];
        char after = p[seglen];
        if (before == '/' && (after == '/' || after == '\0'))
            return 1;
        p += seglen;
    }
    return 0;
}

/* High-churn, always-regenerable trees. Skipped unless the user sets
 * UNDO_DEFAULT_IGNORE=0. Keeps `undo list` and the store free of build
 * noise (a compiler rewriting node_modules should not fill the store).
 *
 * Everything here is a name a tool owns and will happily recreate. Names
 * a person might have chosen for their own source -- dist, build, out,
 * target, vendor, coverage -- are deliberately absent even though they
 * hold generated output just as often: an accidental `rm -rf dist` is a
 * thing people genuinely want back, and a default that silently made it
 * unrecoverable would be a worse bug than the one this list fixes. They
 * are in examples/ignore for anyone who wants them.
 *
 * Split in two because ignored() runs on every intercepted open, and a
 * path with no dot-directory in it can skip the whole second list for the
 * price of one strstr. */
static const char *const default_ignores[] = {
    "node_modules", "__pycache__", "test-results", "playwright-report", NULL,
};

static const char *const default_dot_ignores[] = {
    ".git",   ".cache",        ".turbo",        ".next",     ".nuxt",
    ".vite",  ".svelte-kit",   ".parcel-cache", ".angular",  ".nx",
    ".tox",   ".pytest_cache", ".mypy_cache",   ".ruff_cache",
    ".gradle", ".terraform",   ".dart_tool",    NULL,
};

/* true if `abs` should not be journaled. Patterns come from
 * UNDO_IGNORE (colon-separated): a leading-'/' pattern matches as an
 * absolute path prefix, anything else matches as a path component. */
static int ignored(const char *abs)
{
    static int loaded, use_default = 1;
    static char patterns[8192];
    if (!loaded) {
        loaded = 1;
        const char *env = getenv("UNDO_IGNORE");
        snprintf(patterns, sizeof patterns, "%s", env ? env : "");
        const char *nd = getenv("UNDO_DEFAULT_IGNORE");
        if (nd && (nd[0] == '0' || nd[0] == 'n' || nd[0] == 'N'))
            use_default = 0;
    }

    if (use_default) {
        for (int i = 0; default_ignores[i]; i++)
            if (seg_match(abs, default_ignores[i], strlen(default_ignores[i])))
                return 1;
        if (strstr(abs, "/.") != NULL)
            for (int i = 0; default_dot_ignores[i]; i++)
                if (seg_match(abs, default_dot_ignores[i],
                              strlen(default_dot_ignores[i])))
                    return 1;
    }

    for (const char *s = patterns; *s;) {
        const char *end = strchr(s, ':');
        size_t len = end ? (size_t)(end - s) : strlen(s);
        if (len > 0 && len < PATH_MAX) {
            char pat[PATH_MAX];
            memcpy(pat, s, len);
            pat[len] = 0;
            if (pat[0] == '/') {
                if (strncmp(abs, pat, len) == 0 &&
                    (abs[len] == '/' || abs[len] == '\0'))
                    return 1;
            } else if (seg_match(abs, pat, len)) {
                return 1;
            }
        }
        if (!end)
            break;
        s = end + 1;
    }
    return 0;
}

/* ---------- dedup of repeated in-place writes ---------- */

/* A build that rewrites the same file many times in one command would
 * otherwise save one backup per write. Only the first (pre-command)
 * backup is needed to restore, so we record which paths have been saved
 * and skip the rest. Best-effort: once the table fills we stop deduping,
 * which only costs extra backups, never a missed one.
 *
 * Slots hold path hashes, not the paths, so the table owns no memory:
 * malloc inside an interposed open() is a hazard of its own, and with
 * nothing to free there is nothing a second thread can pull out from
 * under us when the session changes.
 *
 * Keyed on 128 bits, because a collision here does not cost an extra
 * backup, it drops one: two paths landing on the same key dedup as one
 * and the second is never saved. A single 64-bit key put that near 1e-10
 * for a command touching 100k paths, which is small but is silent data
 * loss, the one failure this shim must not have. Two hashes of different
 * shape take it to about 1e-29 for the price of 128KB of untouched bss. */
#define DEDUP_CAP 16384
struct dedup_slot {
    uint64_t h1, h2;
};
static struct dedup_slot dedup_tab[DEDUP_CAP];
static int dedup_count;
static char dedup_dir[PATH_MAX];

/* FNV-1a and djb2: different shapes, so a pair colliding in both is not
 * the same event twice. djb2 leaves its entropy low in the word, hence the
 * splitmix64 finalizer before it is used as half a key. */
static void path_hash(const char *s, uint64_t *h1, uint64_t *h2)
{
    uint64_t a = 1469598103934665603ULL;
    uint64_t b = 5381;
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        a ^= c;
        a *= 1099511628211ULL;
        b = b * 33 + c;
    }
    b += 0x9e3779b97f4a7c15ULL;
    b = (b ^ (b >> 30)) * 0xbf58476d1ce4e5b9ULL;
    b = (b ^ (b >> 27)) * 0x94d049bb133111ebULL;
    b ^= b >> 31;
    *h1 = a ? a : 1; /* 0 marks an empty slot */
    *h2 = b;
}

/* returns 1 if `abs` was already saved this command (skip it); otherwise
 * records it and returns 0.
 *
 * The table covers one command. A shell preloaded with the shim
 * (UNDO_CAPTURE_SHELL=1) outlives every session it runs, so a path saved
 * for an earlier command must not suppress its backup in the next one. */
static int mod_seen(const char *abs)
{
    const char *dir = session_dir();
    if (!dir)
        return 0;
    if (strcmp(dedup_dir, dir) != 0) {
        memset(dedup_tab, 0, sizeof dedup_tab);
        dedup_count = 0;
        snprintf(dedup_dir, sizeof dedup_dir, "%s", dir);
    }
    if (dedup_count * 4 >= DEDUP_CAP * 3)
        return 0; /* table nearly full: stop deduping, keep saving */
    uint64_t h1, h2;
    path_hash(abs, &h1, &h2);
    unsigned long i = h1 & (DEDUP_CAP - 1);
    while (dedup_tab[i].h1) {
        if (dedup_tab[i].h1 == h1 && dedup_tab[i].h2 == h2)
            return 1;
        i = (i + 1) & (DEDUP_CAP - 1);
    }
    dedup_tab[i].h1 = h1;
    dedup_tab[i].h2 = h2;
    dedup_count++;
    return 0;
}

/* ---------- operation handlers ---------- */

static void handle_unlink_pre(int dirfd, const char *path, char *abs,
                              char *bak, char *lnk, int *kind)
{
    *kind = 0;
    if (abs_path(dirfd, path, abs) != 0 || ignored(abs))
        return;
    struct stat st;
    if (lstat(abs, &st) != 0)
        return;
    if (S_ISLNK(st.st_mode)) {
        ssize_t n = readlink(abs, lnk, PATH_MAX - 1);
        if (n >= 0) {
            lnk[n] = 0;
            *kind = 2;
        }
        return;
    }
    if (S_ISREG(st.st_mode)) {
        if (save_file(abs, 0, bak) == 0)
            *kind = 1;
        else
            *kind = 3; /* existed but could not be saved */
    }
}

static void handle_unlink_post(int rc, const char *abs, const char *bak,
                               const char *lnk, int kind)
{
    if (rc == 0) {
        if (kind == 1)
            jwrite("unlink", abs, bak, NULL);
        else if (kind == 2)
            jwrite("rmlink", abs, lnk, NULL);
        else if (kind == 3)
            jwrite("lost", abs, "unlink", NULL);
    } else if (kind == 1) {
        unlink(bak);
    }
}

static void handle_rmdir_pre(int dirfd, const char *path, char *abs,
                             char *mode, int *ok)
{
    *ok = 0;
    if (abs_path(dirfd, path, abs) != 0 || ignored(abs))
        return;
    struct stat st;
    if (lstat(abs, &st) != 0 || !S_ISDIR(st.st_mode))
        return;
    snprintf(mode, 8, "%o", st.st_mode & 07777);
    *ok = 1;
}

/* open-family: returns kind 0=nothing 1=modified(bak) 2=created */
static void handle_open_pre(int dirfd, const char *path, int flags,
                            char *abs, char *bak, int *kind)
{
    *kind = 0;
    if ((flags & O_TMPFILE) == O_TMPFILE)
        return;
    int writes = (flags & (O_WRONLY | O_RDWR)) != 0;
    if (!writes && !(flags & O_CREAT))
        return;
    if (abs_path(dirfd, path, abs) != 0 || ignored(abs))
        return;
    struct stat st;
    if (lstat(abs, &st) == 0 && S_ISLNK(st.st_mode)) {
        /* writing through a symlink modifies the target; journal the
         * target so restore swaps content instead of clobbering the link */
        char rp[PATH_MAX];
        if (!realpath(abs, rp))
            return;
        strcpy(abs, rp);
    }
    if (lstat(abs, &st) == 0) {
        if (writes && S_ISREG(st.st_mode)) {
            if (mod_seen(abs))
                return; /* already backed up earlier this command */
            if (save_file(abs, 1, bak) == 0)
                *kind = 1;
            else
                *kind = 3;
        }
    } else if (errno == ENOENT && (flags & O_CREAT)) {
        *kind = 2;
    }
}

static void handle_open_post(int ok, const char *abs, const char *bak,
                             int kind)
{
    if (ok) {
        if (kind == 1)
            jwrite("mod", abs, bak, NULL);
        else if (kind == 2)
            jwrite("create", abs, NULL);
        else if (kind == 3)
            jwrite("lost", abs, "write", NULL);
    } else if (kind == 1) {
        unlink(bak);
    }
}

static void handle_rename_pre(int olddirfd, const char *oldp, int newdirfd,
                              const char *newp, unsigned flags, char *absold,
                              char *absnew, char *bak, int *kind)
{
    /* kind: 0 skip, 1 plain, 2 plain+target-backup, 3 exchange */
    *kind = 0;
    if (abs_path(olddirfd, oldp, absold) != 0 ||
        abs_path(newdirfd, newp, absnew) != 0)
        return;
    /* skip only when the move stays entirely inside ignored trees; a
     * move that rescues a file out of one must stay recoverable */
    if (ignored(absold) && ignored(absnew))
        return;
    if (flags & RENAME_EXCHANGE) {
        *kind = 3;
        return;
    }
    *kind = 1;
    struct stat st;
    if (lstat(absnew, &st) == 0 && S_ISREG(st.st_mode)) {
        if (save_file(absnew, 0, bak) == 0)
            *kind = 2;
    }
}

static void handle_rename_post(int rc, const char *absold,
                               const char *absnew, const char *bak, int kind)
{
    if (rc == 0) {
        if (kind == 1)
            jwrite("rename", absold, absnew, "-", NULL);
        else if (kind == 2)
            jwrite("rename", absold, absnew, bak, NULL);
        else if (kind == 3)
            jwrite("exchange", absold, absnew, NULL);
    } else if (kind == 2) {
        unlink(bak);
    }
}

/* ---------- interposed functions ---------- */

int unlink(const char *path)
{
    REAL(unlink, int, const char *);
    if (!armed())
        return real_unlink(path);
    in_shim = 1;
    char abs[PATH_MAX], bak[PATH_MAX], lnk[PATH_MAX];
    int kind;
    handle_unlink_pre(AT_FDCWD, path, abs, bak, lnk, &kind);
    int rc = real_unlink(path);
    handle_unlink_post(rc, abs, bak, lnk, kind);
    in_shim = 0;
    return rc;
}

int rmdir(const char *path)
{
    REAL(rmdir, int, const char *);
    if (!armed())
        return real_rmdir(path);
    in_shim = 1;
    char abs[PATH_MAX], mode[8];
    int ok;
    handle_rmdir_pre(AT_FDCWD, path, abs, mode, &ok);
    int rc = real_rmdir(path);
    if (rc == 0 && ok)
        jwrite("rmdir", abs, mode, NULL);
    in_shim = 0;
    return rc;
}

int unlinkat(int dirfd, const char *path, int flags)
{
    REAL(unlinkat, int, int, const char *, int);
    if (!armed())
        return real_unlinkat(dirfd, path, flags);
    in_shim = 1;
    char abs[PATH_MAX], bak[PATH_MAX], lnk[PATH_MAX], mode[8];
    int kind = 0, dirok = 0;
    if (flags & AT_REMOVEDIR)
        handle_rmdir_pre(dirfd, path, abs, mode, &dirok);
    else
        handle_unlink_pre(dirfd, path, abs, bak, lnk, &kind);
    int rc = real_unlinkat(dirfd, path, flags);
    if (flags & AT_REMOVEDIR) {
        if (rc == 0 && dirok)
            jwrite("rmdir", abs, mode, NULL);
    } else {
        handle_unlink_post(rc, abs, bak, lnk, kind);
    }
    in_shim = 0;
    return rc;
}

int remove(const char *path)
{
    REAL(remove, int, const char *);
    if (!armed())
        return real_remove(path);
    struct stat st;
    if (lstat(path, &st) == 0 && S_ISDIR(st.st_mode))
        return rmdir(path);
    return unlink(path);
}

static int do_rename(int olddirfd, const char *oldp, int newdirfd,
                     const char *newp, unsigned flags,
                     int (*call)(void *), void *ctx)
{
    if (!armed())
        return call(ctx);
    in_shim = 1;
    char absold[PATH_MAX], absnew[PATH_MAX], bak[PATH_MAX];
    int kind;
    handle_rename_pre(olddirfd, oldp, newdirfd, newp, flags, absold, absnew,
                      bak, &kind);
    int rc = call(ctx);
    handle_rename_post(rc, absold, absnew, bak, kind);
    in_shim = 0;
    return rc;
}

struct rename_ctx {
    int ofd, nfd;
    const char *o, *n;
    unsigned flags;
};

static int call_rename(void *p)
{
    struct rename_ctx *c = p;
    REAL(rename, int, const char *, const char *);
    return real_rename(c->o, c->n);
}

static int call_renameat(void *p)
{
    struct rename_ctx *c = p;
    REAL(renameat, int, int, const char *, int, const char *);
    return real_renameat(c->ofd, c->o, c->nfd, c->n);
}

static int call_renameat2(void *p)
{
    struct rename_ctx *c = p;
    REAL(renameat2, int, int, const char *, int, const char *, unsigned);
    return real_renameat2(c->ofd, c->o, c->nfd, c->n, c->flags);
}

int rename(const char *oldp, const char *newp)
{
    struct rename_ctx c = {AT_FDCWD, AT_FDCWD, oldp, newp, 0};
    return do_rename(AT_FDCWD, oldp, AT_FDCWD, newp, 0, call_rename, &c);
}

int renameat(int ofd, const char *oldp, int nfd, const char *newp)
{
    struct rename_ctx c = {ofd, nfd, oldp, newp, 0};
    return do_rename(ofd, oldp, nfd, newp, 0, call_renameat, &c);
}

int renameat2(int ofd, const char *oldp, int nfd, const char *newp,
              unsigned flags)
{
    struct rename_ctx c = {ofd, nfd, oldp, newp, flags};
    return do_rename(ofd, oldp, nfd, newp, flags, call_renameat2, &c);
}

int mkdir(const char *path, mode_t mode)
{
    REAL(mkdir, int, const char *, mode_t);
    int rc = real_mkdir(path, mode);
    if (rc == 0 && armed()) {
        in_shim = 1;
        char abs[PATH_MAX];
        if (abs_path(AT_FDCWD, path, abs) == 0 && !ignored(abs))
            jwrite("mkdir", abs, NULL);
        in_shim = 0;
    }
    return rc;
}

int mkdirat(int dirfd, const char *path, mode_t mode)
{
    REAL(mkdirat, int, int, const char *, mode_t);
    int rc = real_mkdirat(dirfd, path, mode);
    if (rc == 0 && armed()) {
        in_shim = 1;
        char abs[PATH_MAX];
        if (abs_path(dirfd, path, abs) == 0 && !ignored(abs))
            jwrite("mkdir", abs, NULL);
        in_shim = 0;
    }
    return rc;
}

int symlink(const char *target, const char *linkpath)
{
    REAL(symlink, int, const char *, const char *);
    int rc = real_symlink(target, linkpath);
    if (rc == 0 && armed()) {
        in_shim = 1;
        char abs[PATH_MAX];
        if (abs_path(AT_FDCWD, linkpath, abs) == 0 && !ignored(abs))
            jwrite("create", abs, NULL);
        in_shim = 0;
    }
    return rc;
}

int symlinkat(const char *target, int dirfd, const char *linkpath)
{
    REAL(symlinkat, int, const char *, int, const char *);
    int rc = real_symlinkat(target, dirfd, linkpath);
    if (rc == 0 && armed()) {
        in_shim = 1;
        char abs[PATH_MAX];
        if (abs_path(dirfd, linkpath, abs) == 0 && !ignored(abs))
            jwrite("create", abs, NULL);
        in_shim = 0;
    }
    return rc;
}

int link(const char *oldp, const char *newp)
{
    REAL(link, int, const char *, const char *);
    int rc = real_link(oldp, newp);
    if (rc == 0 && armed()) {
        in_shim = 1;
        char abs[PATH_MAX];
        if (abs_path(AT_FDCWD, newp, abs) == 0 && !ignored(abs))
            jwrite("create", abs, NULL);
        in_shim = 0;
    }
    return rc;
}

int linkat(int olddirfd, const char *oldp, int newdirfd, const char *newp,
           int flags)
{
    REAL(linkat, int, int, const char *, int, const char *, int);
    int rc = real_linkat(olddirfd, oldp, newdirfd, newp, flags);
    if (rc == 0 && armed()) {
        in_shim = 1;
        char abs[PATH_MAX];
        if (abs_path(newdirfd, newp, abs) == 0 && !ignored(abs))
            jwrite("create", abs, NULL);
        in_shim = 0;
    }
    return rc;
}

static void chmod_pre(int dirfd, const char *path, char *abs, char *oldmode,
                      int *ok)
{
    *ok = 0;
    struct stat st;
    if (abs_path(dirfd, path, abs) != 0 || ignored(abs))
        return;
    if (stat(abs, &st) != 0)
        return;
    snprintf(oldmode, 8, "%o", st.st_mode & 07777);
    *ok = 1;
}

static void chmod_post(int rc, const char *abs, const char *oldmode,
                       mode_t mode, int ok)
{
    if (rc != 0 || !ok)
        return;
    char newmode[8];
    snprintf(newmode, sizeof newmode, "%o", mode & 07777);
    if (strcmp(oldmode, newmode) != 0)
        jwrite("chmod", abs, oldmode, newmode, NULL);
}

int chmod(const char *path, mode_t mode)
{
    REAL(chmod, int, const char *, mode_t);
    if (!armed())
        return real_chmod(path, mode);
    in_shim = 1;
    char abs[PATH_MAX], oldmode[8];
    int ok;
    chmod_pre(AT_FDCWD, path, abs, oldmode, &ok);
    int rc = real_chmod(path, mode);
    chmod_post(rc, abs, oldmode, mode, ok);
    in_shim = 0;
    return rc;
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
    REAL(fchmodat, int, int, const char *, mode_t, int);
    if (!armed())
        return real_fchmodat(dirfd, path, mode, flags);
    in_shim = 1;
    char abs[PATH_MAX], oldmode[8];
    int ok;
    chmod_pre(dirfd, path, abs, oldmode, &ok);
    int rc = real_fchmodat(dirfd, path, mode, flags);
    chmod_post(rc, abs, oldmode, mode, ok);
    in_shim = 0;
    return rc;
}

/* chmod and fchmodat were interposed but fchmod was not, so the same mode
 * change went unrecorded whenever the caller held a descriptor.
 *
 * copy_file() calls fchmod on the backup it just wrote, which now lands
 * here first. It runs with in_shim set, so armed() is false and it goes
 * straight through: no recursion, and no journal line for the backup. */
int fchmod(int fd, mode_t mode)
{
    REAL(fchmod, int, int, mode_t);
    if (!armed())
        return real_fchmod(fd, mode);
    in_shim = 1;
    char abs[PATH_MAX], oldmode[8];
    int ok = 0;
    struct stat st;
    if (fd_path(fd, abs) == 0 && !ignored(abs) && stat(abs, &st) == 0) {
        snprintf(oldmode, sizeof oldmode, "%o", st.st_mode & 07777);
        ok = 1;
    }
    int rc = real_fchmod(fd, mode);
    chmod_post(rc, abs, oldmode, mode, ok);
    in_shim = 0;
    return rc;
}

/* saves path, runs `call`, journals the backup if the call stuck */
static int truncate_common(const char *path, int (*call)(const char *, off_t),
                           off_t length)
{
    in_shim = 1;
    char abs[PATH_MAX], bak[PATH_MAX];
    int have = 0;
    struct stat st;
    if (abs_path(AT_FDCWD, path, abs) == 0 && !ignored(abs) &&
        lstat(abs, &st) == 0 && S_ISREG(st.st_mode) && !mod_seen(abs))
        have = save_file(abs, 1, bak) == 0;
    int rc = call(path, length);
    if (rc == 0 && have)
        jwrite("mod", abs, bak, NULL);
    else if (have)
        unlink(bak);
    in_shim = 0;
    return rc;
}

int truncate(const char *path, off_t length)
{
    REAL(truncate, int, const char *, off_t);
    if (!armed())
        return real_truncate(path, length);
    return truncate_common(path, real_truncate, length);
}

/* Anything built with _FILE_OFFSET_BITS=64 calls this instead, which is
 * most modern software (Python among them). Missing it meant those
 * truncations were silently unrecorded.
 *
 * glibc only: musl's off_t is already 64-bit, so it has no off64_t and no
 * separate entry point, and truncate() above catches everything. */
#ifdef __GLIBC__
int truncate64(const char *path, off64_t length)
{
    REAL(truncate64, int, const char *, off64_t);
    if (!armed())
        return real_truncate64(path, length);
    return truncate_common(path, (int (*)(const char *, off_t))real_truncate64,
                           (off_t)length);
}
#endif

/* truncate_common for a caller holding a descriptor instead of a name.
 * Opening a file and truncating the fd is the ordinary way a logger or an
 * editor empties one, and none of it was recorded while only the by-name
 * calls were interposed. */
static int ftruncate_common(int fd, int (*call)(int, off_t), off_t length)
{
    in_shim = 1;
    char abs[PATH_MAX], bak[PATH_MAX];
    int have = 0;
    struct stat st;
    if (fd_path(fd, abs) == 0 && !ignored(abs) && lstat(abs, &st) == 0 &&
        S_ISREG(st.st_mode) && !mod_seen(abs))
        have = save_file(abs, 1, bak) == 0;
    int rc = call(fd, length);
    if (rc == 0 && have)
        jwrite("mod", abs, bak, NULL);
    else if (have)
        unlink(bak);
    in_shim = 0;
    return rc;
}

int ftruncate(int fd, off_t length)
{
    REAL(ftruncate, int, int, off_t);
    if (!armed())
        return real_ftruncate(fd, length);
    return ftruncate_common(fd, real_ftruncate, length);
}

/* same _FILE_OFFSET_BITS=64 split as truncate64 above */
#ifdef __GLIBC__
int ftruncate64(int fd, off64_t length)
{
    REAL(ftruncate64, int, int, off64_t);
    if (!armed())
        return real_ftruncate64(fd, length);
    return ftruncate_common(fd, (int (*)(int, off_t))real_ftruncate64,
                            (off_t)length);
}
#endif

static int open_common(const char *fn, int dirfd, const char *path,
                       int flags, mode_t mode)
{
    REAL(openat, int, int, const char *, int, ...);
    if (!armed())
        return real_openat(dirfd, path, flags, mode);
    in_shim = 1;
    char abs[PATH_MAX], bak[PATH_MAX];
    int kind;
    handle_open_pre(dirfd, path, flags, abs, bak, &kind);
    int fd = real_openat(dirfd, path, flags, mode);
    handle_open_post(fd >= 0, abs, bak, kind);
    in_shim = 0;
    (void)fn;
    return fd;
}

int open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return open_common("open", AT_FDCWD, path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return open_common("open64", AT_FDCWD, path, flags | O_LARGEFILE, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return open_common("openat", dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return open_common("openat64", dirfd, path, flags | O_LARGEFILE, mode);
}

int creat(const char *path, mode_t mode)
{
    return open_common("creat", AT_FDCWD, path,
                       O_WRONLY | O_CREAT | O_TRUNC, mode);
}

int creat64(const char *path, mode_t mode)
{
    return open_common("creat64", AT_FDCWD, path,
                       O_WRONLY | O_CREAT | O_TRUNC | O_LARGEFILE, mode);
}

/* fortified (_FORTIFY_SOURCE) entry points used when flags are dynamic */
int __open_2(const char *path, int flags)
{
    return open_common("open", AT_FDCWD, path, flags, 0);
}

int __open64_2(const char *path, int flags)
{
    return open_common("open64", AT_FDCWD, path, flags | O_LARGEFILE, 0);
}

int __openat_2(int dirfd, const char *path, int flags)
{
    return open_common("openat", dirfd, path, flags, 0);
}

int __openat64_2(int dirfd, const char *path, int flags)
{
    return open_common("openat64", dirfd, path, flags | O_LARGEFILE, 0);
}

static int fopen_flags(const char *mode)
{
    int plus = strchr(mode, '+') != NULL;
    switch (mode[0]) {
    case 'w':
        return (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
    case 'a':
        return (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
    case 'r':
        return plus ? O_RDWR : O_RDONLY;
    default:
        return O_RDONLY;
    }
}

static FILE *fopen_common(FILE *(*real)(const char *, const char *),
                          const char *path, const char *mode)
{
    if (!armed())
        return real(path, mode);
    in_shim = 1;
    char abs[PATH_MAX], bak[PATH_MAX];
    int kind;
    handle_open_pre(AT_FDCWD, path, fopen_flags(mode), abs, bak, &kind);
    FILE *f = real(path, mode);
    handle_open_post(f != NULL, abs, bak, kind);
    in_shim = 0;
    return f;
}

FILE *fopen(const char *path, const char *mode)
{
    REAL(fopen, FILE *, const char *, const char *);
    return fopen_common(real_fopen, path, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    REAL(fopen64, FILE *, const char *, const char *);
    return fopen_common(real_fopen64, path, mode);
}

FILE *freopen(const char *path, const char *mode, FILE *stream)
{
    REAL(freopen, FILE *, const char *, const char *, FILE *);
    if (!armed() || !path)
        return real_freopen(path, mode, stream);
    in_shim = 1;
    char abs[PATH_MAX], bak[PATH_MAX];
    int kind;
    handle_open_pre(AT_FDCWD, path, fopen_flags(mode), abs, bak, &kind);
    FILE *f = real_freopen(path, mode, stream);
    handle_open_post(f != NULL, abs, bak, kind);
    in_shim = 0;
    return f;
}

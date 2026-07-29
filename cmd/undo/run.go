package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/edaywalid/undo/internal/session"
)

// findShim locates libundo.so: env override, install locations relative
// to the binary, then the usual system paths.
func findShim() string {
	if p := os.Getenv("UNDO_LIB"); p != "" {
		return p
	}
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, "..", "lib", "undo", "libundo.so"),
			filepath.Join(dir, "..", "build", "libundo.so"), // dev tree
		)
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, ".local", "lib", "undo", "libundo.so"))
	}
	candidates = append(candidates,
		"/usr/local/lib/undo/libundo.so", "/usr/lib/undo/libundo.so")
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

// armedEnv returns base with the shim preloaded and the session pointed
// at dir, prepending libundo.so to any existing LD_PRELOAD.
//
// Any libundo.so already in LD_PRELOAD is dropped first. A shell with the
// hook installed already has one, and loading two copies makes both
// intercept every call: duplicate journal entries, and each copy records
// the other's backup writes as if they were the user's.
func armedEnv(base []string, shim, dir string) []string {
	env := make([]string, 0, len(base)+2)
	preload := shim
	for _, kv := range base {
		if v, ok := strings.CutPrefix(kv, "LD_PRELOAD="); ok {
			var keep []string
			for _, p := range strings.Split(v, ":") {
				if p == "" || isUndoShim(p) {
					continue
				}
				keep = append(keep, p)
			}
			if len(keep) > 0 {
				preload = shim + ":" + strings.Join(keep, ":")
			}
			continue
		}
		if strings.HasPrefix(kv, "UNDO_SESSION=") {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "UNDO_SESSION="+dir, "LD_PRELOAD="+preload)
}

// isUndoShim reports whether an LD_PRELOAD entry is one of our shims,
// under any install prefix.
func isUndoShim(path string) bool {
	return filepath.Base(path) == "libundo.so"
}

// cmdRun executes one command with the shim armed, no shell hook needed.
func cmdRun(argv []string) {
	if len(argv) > 0 && argv[0] == "--" {
		argv = argv[1:]
	}
	if len(argv) == 0 {
		fatal(fmt.Errorf("run needs a command: undo run -- <cmd> [args...]"))
	}
	shim := findShim()
	if shim == "" {
		fatal(fmt.Errorf("libundo.so not found; set UNDO_LIB or make install"))
	}

	s, err := session.Create(strings.Join(argv, " "))
	if err != nil {
		fatal(err)
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = armedEnv(os.Environ(), shim, s.Dir)

	runErr := cmd.Run()
	s.MarkDone()

	code := 0
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			code = ee.ExitCode()
			// killed by a signal: ExitCode is -1, which os.Exit turns
			// into 255. Report it the way a shell does.
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				code = 128 + int(ws.Signal())
			}
		} else {
			s.Remove()
			fatal(runErr)
		}
	}

	// reload to see what the shim recorded
	if fresh, err := session.Get(s.ID); err == nil && len(fresh.Entries) > 0 {
		fmt.Fprintf(os.Stderr, "undo: captured %d change(s), run 'undo' to revert\n",
			len(fresh.Entries))
	} else {
		s.Remove()
	}
	os.Exit(code)
}

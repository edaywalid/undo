// Package restore replays a session journal.
//
// The journal is bidirectional: Undo walks it newest-first putting
// backups back, Redo walks it oldest-first re-applying the command's
// effect. Both directions preserve data (files are swapped with or
// parked in the session store, never deleted), so undo and redo can
// toggle a session indefinitely.
package restore

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	"github.com/edaywalid/undo/internal/journal"
	"github.com/edaywalid/undo/internal/session"
)

type Direction int

const (
	Undo Direction = iota
	Redo
)

type Options struct {
	DryRun bool
	Force  bool         // clobber files that changed since the session
	Only   map[int]bool // journal indices to touch; nil means all
}

type Result struct {
	Done    int
	Skipped []string
	Actions []string // populated on dry runs
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// moveAny renames src onto dst, copying across filesystems if the
// session store lives on a different device than the touched path.
func moveAny(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, st.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	os.Chtimes(dst, st.ModTime(), st.ModTime())
	return os.Remove(src)
}

// swapAny exchanges the contents of a and b, tolerating one side
// being absent.
func swapAny(a, b string) error {
	switch {
	case !exists(a) && !exists(b):
		return fmt.Errorf("both %s and its backup are gone", a)
	case !exists(a):
		return moveAny(b, a)
	case !exists(b):
		return moveAny(a, b)
	}
	tmp := a + ".undo-swap"
	if err := os.Rename(a, tmp); err != nil {
		return err
	}
	if err := moveAny(b, a); err != nil {
		os.Rename(tmp, a)
		return err
	}
	return moveAny(tmp, b)
}

// slot is where undo parks things it removes (created files, forced
// directory deletions), keyed by journal index.
func slot(s *session.Session, i int) string {
	return filepath.Join(s.Dir, "data", fmt.Sprintf("undo-%d", i))
}

// Run replays the journal of s in the given direction.
func Run(s *session.Session, dir Direction, opts Options) (*Result, error) {
	res := &Result{}
	verb := "revert"
	if dir == Redo {
		verb = "redo"
	}

	indices := make([]int, 0, len(s.Entries))
	if dir == Undo {
		for i := len(s.Entries) - 1; i >= 0; i-- {
			indices = append(indices, i)
		}
	} else {
		for i := range s.Entries {
			indices = append(indices, i)
		}
	}

	for _, i := range indices {
		if opts.Only != nil && !opts.Only[i] {
			continue
		}
		e := s.Entries[i]
		field := func(n int) string {
			if n < len(e.Fields) {
				return e.Fields[n]
			}
			return ""
		}
		skip := func(why string) {
			res.Skipped = append(res.Skipped, e.Describe()+": "+why)
		}
		act := func() bool {
			if opts.DryRun {
				res.Actions = append(res.Actions, "would "+verb+": "+e.Describe())
				return false
			}
			return true
		}

		var err error
		done := true

		switch e.Op {
		case journal.OpCreate:
			if dir == Undo {
				if !exists(field(0)) {
					done = false
					break
				}
				if !act() {
					continue
				}
				err = moveAny(field(0), slot(s, i))
			} else {
				if exists(field(0)) {
					done = false
					break
				}
				if !exists(slot(s, i)) {
					skip("no saved copy to restore")
					continue
				}
				if !act() {
					continue
				}
				err = moveAny(slot(s, i), field(0))
			}

		case journal.OpUnlink:
			if dir == Undo {
				if exists(field(0)) && !opts.Force {
					skip("path exists again, use --force to overwrite")
					continue
				}
				if !act() {
					continue
				}
				if exists(field(0)) {
					os.Remove(field(0))
				}
				err = moveAny(field(1), field(0))
			} else {
				if !exists(field(0)) {
					done = false
					break
				}
				if !act() {
					continue
				}
				err = moveAny(field(0), field(1))
			}

		case journal.OpRmlink:
			if dir == Undo {
				if exists(field(0)) && !opts.Force {
					skip("path exists again, use --force to overwrite")
					continue
				}
				if !act() {
					continue
				}
				os.Remove(field(0))
				err = os.Symlink(field(1), field(0))
			} else {
				if !exists(field(0)) {
					done = false
					break
				}
				if !act() {
					continue
				}
				err = os.Remove(field(0))
			}

		case journal.OpMod:
			// symmetric: swap the on-disk file with the backup
			if !act() {
				continue
			}
			err = swapAny(field(0), field(1))

		case journal.OpRename:
			old, new_, bak := field(0), field(1), field(2)
			hasBak := bak != "-" && bak != ""
			if dir == Undo {
				if exists(old) && !opts.Force {
					skip("original path occupied, use --force to overwrite")
					continue
				}
				if !exists(new_) {
					skip("moved file is gone")
					continue
				}
				if !act() {
					continue
				}
				if exists(old) {
					os.Remove(old)
				}
				if err = moveAny(new_, old); err == nil && hasBak {
					err = moveAny(bak, new_)
				}
			} else {
				if !exists(old) {
					skip("file to move is gone")
					continue
				}
				if exists(new_) && !hasBak && !opts.Force {
					skip("target occupied, use --force to overwrite")
					continue
				}
				if !act() {
					continue
				}
				if exists(new_) {
					if hasBak {
						err = moveAny(new_, bak)
					} else {
						err = os.Remove(new_)
					}
				}
				if err == nil {
					err = moveAny(old, new_)
				}
			}

		case journal.OpExchange:
			if !exists(field(0)) || !exists(field(1)) {
				skip("one side is gone")
				continue
			}
			if !act() {
				continue
			}
			err = swapAny(field(0), field(1))

		case journal.OpMkdir:
			if dir == Undo {
				if !exists(field(0)) {
					done = false
					break
				}
				if !act() {
					continue
				}
				if err = os.Remove(field(0)); err != nil {
					if !opts.Force {
						skip("directory not empty, use --force to move it aside")
						continue
					}
					err = os.Rename(field(0), slot(s, i))
				}
			} else {
				if exists(field(0)) {
					done = false
					break
				}
				if !act() {
					continue
				}
				if exists(slot(s, i)) {
					err = os.Rename(slot(s, i), field(0))
				} else {
					err = os.Mkdir(field(0), 0o755)
				}
			}

		case journal.OpRmdir:
			if dir == Undo {
				if exists(field(0)) {
					done = false
					break
				}
				if !act() {
					continue
				}
				mode, perr := strconv.ParseUint(field(1), 8, 32)
				if perr != nil {
					mode = 0o755
				}
				if err = os.MkdirAll(field(0), os.FileMode(mode)); err == nil {
					err = os.Chmod(field(0), os.FileMode(mode))
				}
			} else {
				if !exists(field(0)) {
					done = false
					break
				}
				if !act() {
					continue
				}
				if err = os.Remove(field(0)); err != nil {
					skip("directory not empty")
					continue
				}
			}

		case journal.OpChmod:
			if !exists(field(0)) {
				done = false
				break
			}
			target := field(1)
			if dir == Redo {
				target = field(2)
			}
			mode, perr := strconv.ParseUint(target, 8, 32)
			if perr != nil {
				skip("bad mode in journal")
				continue
			}
			if !act() {
				continue
			}
			err = os.Chmod(field(0), os.FileMode(mode))

		case journal.OpLost:
			if dir == Undo {
				skip("the shim could not save a backup (too big or unlinkable)")
			}
			continue

		default:
			skip("unknown journal op")
			continue
		}

		if err != nil {
			skip(err.Error())
			continue
		}
		if done && !opts.DryRun {
			res.Done++
		}
	}

	// Selective replays leave the session state alone: the journal
	// stays consistent either way, and full undo/redo still works.
	if !opts.DryRun && opts.Only == nil && res.Done > 0 {
		var err error
		if dir == Undo {
			err = s.MarkUndone()
		} else {
			err = s.ClearUndone()
		}
		if err != nil {
			return res, fmt.Errorf("replayed, but could not update session state: %w", err)
		}
	}
	return res, nil
}

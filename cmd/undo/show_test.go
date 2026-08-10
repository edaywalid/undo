package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/edaywalid/undo/internal/session"
)

// Helper to create a test session with a specified command and optional journal entry
func createTestSession(t *testing.T, cmd string, withJournal bool) *session.Session {
	t.Helper()
	s, err := session.Create(cmd)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.MarkDone(); err != nil {
		t.Fatal(err)
	}
	if withJournal {
		if err := os.WriteFile(filepath.Join(s.Dir, "journal"), []byte("unlink\t/tmp/file\t/tmp/file_bak\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

// 1. Edge Case: Empty Session Store
func TestGetShowSessionEmptyStore(t *testing.T) {
	t.Setenv("UNDO_DATA_DIR", t.TempDir())

	s, allUndone, err := getShowSession(nil)
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("expected os.ErrNotExist, got %v", err)
	}
	if allUndone {
		t.Errorf("expected allUndone=false, got true")
	}
	if s != nil {
		t.Errorf("expected s=nil, got %v", s)
	}
}

// 2. Edge Case: Only Empty Sessions (0 journal entries)
func TestGetShowSessionOnlyEmptySessions(t *testing.T) {
	t.Setenv("UNDO_DATA_DIR", t.TempDir())

	createTestSession(t, "ls -la", false)
	createTestSession(t, "cat README.md", false)

	s, allUndone, err := getShowSession(nil)
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("expected os.ErrNotExist for empty sessions, got %v", err)
	}
	if allUndone {
		t.Errorf("expected allUndone=false, got true")
	}
	if s != nil {
		t.Errorf("expected s=nil, got %v", s)
	}
}

// 3. Edge Case: Explicit Session ID Argument Provided
func TestGetShowSessionExplicitID(t *testing.T) {
	t.Setenv("UNDO_DATA_DIR", t.TempDir())

	s1 := createTestSession(t, "rm -rf dir1", true)
	if err := s1.MarkUndone(); err != nil {
		t.Fatal(err)
	}

	got, allUndone, err := getShowSession([]string{s1.ID})
	if err != nil {
		t.Fatalf("unexpected error looking up explicit ID: %v", err)
	}
	if got.ID != s1.ID {
		t.Errorf("got ID %s, want %s", got.ID, s1.ID)
	}
	if allUndone {
		t.Errorf("expected allUndone=false for explicit ID lookup")
	}
}

// 4. Edge Case: Mix of Active and Undone Sessions
func TestGetShowSessionMixActiveAndUndone(t *testing.T) {
	t.Setenv("UNDO_DATA_DIR", t.TempDir())

	s1 := createTestSession(t, "rm file1", true)
	if err := s1.MarkUndone(); err != nil {
		t.Fatal(err)
	}

	time.Sleep(10 * time.Millisecond)
	s2 := createTestSession(t, "rm file2", true)

	got, allUndone, err := getShowSession(nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != s2.ID {
		t.Errorf("got session ID %s, want active session %s", got.ID, s2.ID)
	}
	if allUndone {
		t.Errorf("expected allUndone=false when an active session exists")
	}
}

// 5. Edge Case: All Sessions Undone -> Fallback to Latest
func TestGetShowSessionAllUndone(t *testing.T) {
	tmpDir := t.TempDir()
	t.Setenv("UNDO_DATA_DIR", tmpDir)

	s1 := createTestSession(t, "rm -rf old_file", true)
	if err := s1.MarkUndone(); err != nil {
		t.Fatal(err)
	}

	got, allUndone, err := getShowSession(nil)
	if err != nil {
		t.Fatalf("unexpected error on fallback: %v", err)
	}
	if !allUndone {
		t.Errorf("expected allUndone=true when all sessions are undone")
	}
	if got.ID != s1.ID {
		t.Errorf("got session %s, want %s", got.ID, s1.ID)
	}
}

// Full Output Verification Test for cmdShow
func TestCmdShowOutputFormatting(t *testing.T) {
	tmpDir := t.TempDir()
	t.Setenv("UNDO_DATA_DIR", tmpDir)

	s := createTestSession(t, "rm -rf target_folder", true)
	if err := s.MarkUndone(); err != nil {
		t.Fatal(err)
	}

	oldStdout := os.Stdout
	oldStderr := os.Stderr
	rOut, wOut, _ := os.Pipe()
	rErr, wErr, _ := os.Pipe()
	os.Stdout = wOut
	os.Stderr = wErr

	defer func() {
		os.Stdout = oldStdout
		os.Stderr = oldStderr
	}()

	cmdShow(nil)

	wOut.Close()
	wErr.Close()

	var outBuf, errBuf bytes.Buffer
	_, _ = io.Copy(&outBuf, rOut)
	_, _ = io.Copy(&errBuf, rErr)

	stderrStr := errBuf.String()
	stdoutStr := outBuf.String()

	if !strings.Contains(stderrStr, "(all sessions have been undone; showing the most recent)") {
		t.Errorf("expected stderr warning, got: %q", stderrStr)
	}
	if !strings.Contains(stdoutStr, "rm -rf target_folder") {
		t.Errorf("expected stdout command string, got: %q", stdoutStr)
	}
	if !strings.Contains(stdoutStr, "currently undone") {
		t.Errorf("expected stdout undone footer, got: %q", stdoutStr)
	}
}

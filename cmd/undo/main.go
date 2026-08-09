// undo reverts the filesystem changes made by a previous shell command.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/edaywalid/undo/internal/restore"
	"github.com/edaywalid/undo/internal/session"
)

// set via -ldflags "-X main.version=..."
var version = "dev"

const usage = `undo - revert what the last command did to the filesystem

usage:
  undo [flags]            revert the most recent command that changed files
  undo -i                 pick a session and entries interactively
  undo apply <id> [flags] revert a specific session
  undo redo [id] [flags]  re-apply an undone session
  undo diff [id]          show what a session changed, with content diffs
  undo run [--] <cmd...>  run one command with the shim armed (no hook needed)
  undo list               list recent sessions
  undo show [id]          show what a session changed
  undo gc                 prune old, empty, and oversized sessions
  undo purge              delete all stored sessions and backups
  undo doctor             check the install and run a live self-test
  undo upgrade [--check]  update to the latest release
  undo uninstall [--purge] remove undo (--purge also deletes backups)

flags:
  -n, --dry-run   show what would happen without doing it
  -y, --yes       skip the confirmation prompt
      --force     overwrite files that changed after the session
  -V, --version   print version
`

func envInt(name string, def int64) int64 {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return def
}

func cmdGC(auto bool) {
	keep := int(envInt("UNDO_KEEP", 30))
	maxBytes := envInt("UNDO_MAX_STORE", 1<<30)
	removed, err := session.GC(keep, maxBytes)
	if auto {
		return
	}
	if err != nil {
		fatal(err)
	}
	fmt.Printf("removed %d session(s)\n", removed)
}

func cmdPurge(yes, force bool) {
	sessions, err := session.List()
	if err != nil {
		fatal(err)
	}
	if len(sessions) == 0 {
		fmt.Println("store is already empty")
		return
	}
	if !yes && !confirm(fmt.Sprintf(
		"delete %d session(s) and every stored backup? [y/N] ", len(sessions))) {
		fmt.Println("aborted")
		return
	}
	removed := 0
	for _, s := range sessions {
		if s.Live() && !force {
			fmt.Fprintf(os.Stderr, "skipped %s: command may still be running (pid %d)\n",
				shortID(s.ID), s.Pid)
			continue
		}
		if s.Remove() == nil {
			removed++
		}
	}
	fmt.Printf("purged %d session(s)\n", removed)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "undo:", err)
	os.Exit(1)
}

func when(id string) string {
	sec := id
	if len(sec) > 10 {
		sec = sec[:10]
	}
	n, err := strconv.ParseInt(sec, 10, 64)
	if err != nil {
		return "?"
	}
	return time.Unix(n, 0).Format("Jan 2 15:04:05")
}

func shortID(id string) string {
	if len(id) > 14 {
		return id[:14]
	}
	return id
}

func cmdList() {
	sessions, err := session.List()
	if err != nil {
		fatal(err)
	}
	shown := 0
	for _, s := range sessions {
		if len(s.Entries) == 0 {
			continue
		}
		shown++
		mark := " "
		if s.Undone {
			mark = "u"
		}
		// a partial session restores fine, it just is not the whole
		// command, and that is not something to find out afterwards
		if s.Degraded != "" {
			mark = "!"
		}
		cmd := s.Cmd
		if len(cmd) > 60 {
			cmd = cmd[:57] + "..."
		}
		fmt.Printf("%s %s  %s  %3d changes  %s\n",
			mark, shortID(s.ID), when(s.ID), len(s.Entries), cmd)
	}
	if shown == 0 {
		fmt.Println("no sessions recorded (is the shell hook sourced?)")
	}
}

func cmdShow(args []string) {
	var s *session.Session
	var err error
	if len(args) > 0 {
		s, err = session.Get(args[0])
	} else {
		s, err = session.Latest()
	}
	if err != nil {
		fatal(fmt.Errorf("no such session"))
	}
	fmt.Printf("session %s (%s)\n$ %s\n\n", shortID(s.ID), when(s.ID), s.Cmd)
	if s.Degraded != "" {
		fmt.Printf("  ! %s\n  ! changes after that point were not recorded\n\n", s.Degraded)
	}
	for i, e := range s.Entries {
		fmt.Printf("  %2d  %s\n", i+1, e.Describe())
	}
	if s.Undone {
		fmt.Println("\ncurrently undone (undo redo to re-apply)")
	}
}

// one shared reader so consecutive prompts don't swallow each other's
// buffered input
var stdin = bufio.NewReader(os.Stdin)

func readLine(prompt string) string {
	fmt.Print(prompt)
	line, _ := stdin.ReadString('\n')
	return strings.TrimSpace(line)
}

func confirm(prompt string) bool {
	a := strings.ToLower(readLine(prompt))
	return a == "y" || a == "yes"
}

func previewSession(s *session.Session, full bool) {
	fmt.Printf("$ %s  (%s, %d changes)\n", s.Cmd, when(s.ID), len(s.Entries))
	show := s.Entries
	if len(show) > 10 && !full {
		show = show[:10]
	}
	for _, e := range show {
		fmt.Println("  " + e.Describe())
	}
	if n := len(s.Entries) - len(show); n > 0 {
		fmt.Printf("  ... and %d more (undo show %s)\n", n, shortID(s.ID))
	}
}

func report(res *restore.Result, opts restore.Options, dir restore.Direction) {
	if opts.DryRun {
		fmt.Println()
		for _, a := range res.Actions {
			fmt.Println(a)
		}
	}
	for _, w := range res.Skipped {
		fmt.Fprintln(os.Stderr, "skipped:", w)
	}
	if !opts.DryRun {
		verb := "restored"
		if dir == restore.Redo {
			verb = "re-applied"
		}
		fmt.Printf("%s %d change(s)\n", verb, res.Done)
	}
}

func cmdApply(s *session.Session, dir restore.Direction, opts restore.Options, yes bool) {
	if len(s.Entries) == 0 {
		fatal(fmt.Errorf("session recorded no changes"))
	}
	if s.Live() && !opts.Force {
		// chained like `rm x && undo`: the whole line is one session, so
		// undo is running inside the very session it is being asked to
		// revert, and the journal is not finished yet
		if cur := os.Getenv("UNDO_SESSION"); cur != "" && cur == s.Dir {
			fatal(fmt.Errorf("this is the command line you are running right now.\n" +
				"undo works on finished commands, so run it on its own line:\n" +
				"  rm x\n  undo"))
		}
		fatal(fmt.Errorf("the command may still be running (pid %d); --force to override", s.Pid))
	}
	if s.Degraded != "" && dir == restore.Undo {
		fmt.Fprintf(os.Stderr, "warning: %s\n"+
			"warning: this session is incomplete; changes after that point"+
			" cannot be reverted\n", s.Degraded)
	}
	if dir == restore.Undo && s.Undone {
		fatal(fmt.Errorf("session was already undone (undo redo %s to re-apply)", shortID(s.ID)))
	}
	if dir == restore.Redo && !s.Undone {
		fatal(fmt.Errorf("session is not undone, nothing to redo"))
	}

	previewSession(s, opts.DryRun)

	if !opts.DryRun && !yes {
		prompt := "\nrevert this? [y/N] "
		if dir == restore.Redo {
			prompt = "\nre-apply this? [y/N] "
		}
		if !confirm(prompt) {
			fmt.Println("aborted")
			return
		}
	}

	res, err := restore.Run(s, dir, opts)
	if err != nil {
		fatal(err)
	}
	report(res, opts, dir)
}

func main() {
	// `undo run` takes the rest of argv verbatim, before any flag parsing
	if len(os.Args) > 1 && os.Args[1] == "run" {
		cmdRun(os.Args[2:])
		return
	}

	var opts restore.Options
	var yes, interactive, purge bool
	var args []string

	for _, a := range os.Args[1:] {
		switch a {
		case "-n", "--dry-run":
			opts.DryRun = true
		case "-y", "--yes":
			yes = true
		case "--force":
			opts.Force = true
		case "--purge":
			purge = true
		case "-i", "--interactive":
			interactive = true
		case "-V", "--version":
			fmt.Println("undo", version)
			return
		case "-h", "--help", "help":
			fmt.Print(usage)
			return
		default:
			args = append(args, a)
		}
	}

	if interactive {
		cmdInteractive(opts, yes)
		return
	}

	if len(args) == 0 {
		s, err := session.Latest()
		if err != nil {
			// the usual cause is an installed-but-not-activated hook: with
			// no hook nothing is ever recorded, so there is never anything
			// to undo
			if os.Getenv("UNDO_HOOK") == "" {
				fatal(fmt.Errorf("nothing to undo, and the shell hook is not active here.\n" +
					"run 'undo doctor' to see how to turn it on"))
			}
			fatal(fmt.Errorf("nothing to undo"))
		}
		cmdApply(s, restore.Undo, opts, yes)
		return
	}

	switch args[0] {
	case "list", "ls":
		cmdList()
	case "show":
		cmdShow(args[1:])
	case "gc":
		cmdGC(len(args) > 1 && args[1] == "--auto")
	case "purge":
		cmdPurge(yes, opts.Force)
	case "doctor":
		cmdDoctor()
	case "upgrade":
		cmdUpgrade(len(args) > 1 && args[1] == "--check")
	case "uninstall":
		cmdUninstall(yes, purge)
	case "diff":
		cmdDiff(args[1:])
	case "apply":
		if len(args) < 2 {
			fatal(fmt.Errorf("apply needs a session id"))
		}
		s, err := session.Get(args[1])
		if err != nil {
			fatal(fmt.Errorf("no such session %q", args[1]))
		}
		cmdApply(s, restore.Undo, opts, yes)
	case "redo":
		var s *session.Session
		var err error
		if len(args) > 1 {
			s, err = session.Get(args[1])
		} else {
			s, err = session.LatestUndone()
		}
		if err != nil {
			fatal(fmt.Errorf("nothing to redo"))
		}
		cmdApply(s, restore.Redo, opts, yes)
	default:
		fmt.Print(usage)
		os.Exit(2)
	}
}

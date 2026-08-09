package main

import (
	"os"
	"regexp"
	"sort"
	"testing"
)

// The built-in ignore list lives in C, and doctor keeps a copy so it can
// report it. A copy that drifts tells users the shim skips things it does
// not, so read the real list out of the shim source and compare.
func TestBuiltinIgnoresMatchShim(t *testing.T) {
	src, err := os.ReadFile("../../shim/undo_shim.c")
	if err != nil {
		t.Fatalf("cannot read shim source: %v", err)
	}
	arrays := regexp.MustCompile(
		`(?s)default_(?:dot_)?ignores\[\] = \{(.*?)\};`).FindAllSubmatch(src, -1)
	if len(arrays) != 2 {
		t.Fatalf("expected 2 default ignore arrays in the shim, found %d", len(arrays))
	}
	quoted := regexp.MustCompile(`"([^"]*)"`)
	var fromShim []string
	for _, a := range arrays {
		for _, m := range quoted.FindAllSubmatch(a[1], -1) {
			fromShim = append(fromShim, string(m[1]))
		}
	}
	got := append([]string(nil), builtinIgnores...)
	sort.Strings(got)
	sort.Strings(fromShim)
	if len(got) != len(fromShim) {
		t.Fatalf("doctor lists %d built-in ignores, the shim has %d\ndoctor: %v\nshim:   %v",
			len(got), len(fromShim), got, fromShim)
	}
	for i := range got {
		if got[i] != fromShim[i] {
			t.Errorf("built-in ignore mismatch: doctor has %q, shim has %q", got[i], fromShim[i])
		}
	}
}

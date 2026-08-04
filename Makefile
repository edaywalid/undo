PREFIX ?= $(HOME)/.local
CC ?= gcc
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

GO_SRC := $(shell find cmd internal -name '*.go')

all: bin/undo build/libundo.so

build/libundo.so: shim/undo_shim.c
	@mkdir -p build
	$(CC) -shared -fPIC -O2 -Wall -Wextra -o $@ $< -ldl

bin/undo: $(GO_SRC) go.mod
	@mkdir -p bin
	go build -ldflags "-X main.version=$(VERSION)" -o $@ ./cmd/undo

test: all
	go test ./...
	./test/e2e.sh
	@# each skips itself when that shell is not installed
	./test/hook.sh zsh
	./test/hook.sh bash
	./test/hook.sh fish

install: all
	install -Dm755 bin/undo $(PREFIX)/bin/undo
	install -Dm755 build/libundo.so $(PREFIX)/lib/undo/libundo.so
	install -Dm644 shell/undo.zsh $(PREFIX)/share/undo/undo.zsh
	install -Dm644 shell/undo.bash $(PREFIX)/share/undo/undo.bash
	install -Dm644 shell/undo.fish $(PREFIX)/share/undo/undo.fish
	install -Dm644 completions/_undo $(PREFIX)/share/zsh/site-functions/_undo
	install -Dm644 completions/undo.bash $(PREFIX)/share/bash-completion/completions/undo
	install -Dm644 completions/undo.fish $(PREFIX)/share/fish/vendor_completions.d/undo.fish
	@echo
	@echo 'installed. add the line for your shell:'
	@echo '  zsh:   source $(PREFIX)/share/undo/undo.zsh   (~/.zshrc)'
	@echo '  bash:  source $(PREFIX)/share/undo/undo.bash  (~/.bashrc)'
	@echo '  fish:  source $(PREFIX)/share/undo/undo.fish  (config.fish)'

clean:
	rm -rf bin build dist

.PHONY: all test install clean

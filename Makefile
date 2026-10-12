# FSearch for macOS: the fsearch daemon (Rust) + the Option+Space panel (Swift).

PREFIX  ?= $(HOME)/.local
APP_DIR ?= $(HOME)/Applications
APP     := $(APP_DIR)/FSearchPanel.app

.PHONY: all daemon panel install uninstall clean

all: daemon panel

daemon:
	cd daemon && cargo build --release

panel:
	panel/build.sh "$(APP)"

# Installs the daemon to ~/.local/bin (with a login agent, so the panel always
# has a daemon to talk to) and builds the panel app.
install: daemon panel
	daemon/target/release/fsearch install --login
	@echo "panel:   $(APP)"
	@echo "open it: open '$(APP)'   (then press Option+Space)"

uninstall:
	-$(PREFIX)/bin/fsearch uninstall
	rm -rf "$(APP)"

clean:
	cd daemon && cargo clean

# Git revisions for external dependencies
BOOTLOADER_HINTS_REV ?= 5648cf0a5a2574c2870151cd178ff3ae4b141824
STWO_REV ?= e5981958234c4b28fa2b4c3368a0290ec3fc57c2
CAIRO_EXECUTE_REV ?= 7fbbd0112b5a926403c17fa95ad831c1715fd1b1

################################## CLIENT ##################################

build:
	scarb --profile release build --package client --target-kinds executable

test:
	scarb test --package consensus
	scarb test --package utils

################################## BINARIES ##################################

install-corelib:
	mkdir -p vendor
	rm -rf vendor/cairo
	git clone https://github.com/ztarknet/cairo vendor/cairo
	(cd vendor/cairo && git checkout $(CAIRO_EXECUTE_REV))
	ln -s "$(CURDIR)/vendor/cairo/corelib" \
		packages/assumevalid/corelib

install-cairo-execute:
	cargo install --git https://github.com/ztarknet/cairo \
		--rev $(CAIRO_EXECUTE_REV) cairo-execute

install-scarb-eject:
	cargo install --git https://github.com/software-mansion-labs/scarb-eject \
		--rev $(SCARB_EJECT_REV)

install-convert-proof-format:
	RUSTFLAGS="-C target-cpu=native -C opt-level=3" \
		cargo install --force \
		--git https://github.com/starkware-libs/stwo-cairo \
		--rev $(STWO_REV) \
		dev-utils

################################## ASSUMEVALID ##################################

assumevalid-build:
	scarb --profile proving build --package assumevalid \
		--no-default-features

assumevalid-eject:
	scarb-eject --package assumevalid \
		--output packages/assumevalid/cairo_project.toml

assumevalid-build-with-syscalls:
	mkdir -p target/proving
	cd packages/assumevalid && \
	cairo-execute \
		--build-only \
		--output-path \
			../../target/proving/assumevalid-syscalls.executable.json \
		--executable assumevalid::main \
		--ignore-warnings \
		--allow-syscalls .

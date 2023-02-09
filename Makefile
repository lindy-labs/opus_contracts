# Won't write the called command in the console
.SILENT:
# Because we have a folder called test we need PHONY to avoid collision
.PHONY: test

INSTALLATION_FOLDER=./cairo
SOURCE_FOLDER=./contracts-1.0

install:
	if [ -d $(INSTALLATION_FOLDER) ]; then \
		$(MAKE) update-cairo; \
	else \
		$(MAKE) clone-cairo; \
	fi
	$(MAKE) build

clone-cairo:
	mkdir -p $(INSTALLATION_FOLDER)
	git clone --depth 1 https://github.com/starkware-libs/cairo.git $(INSTALLATION_FOLDER)

update-cairo:
	git -C $(INSTALLATION_FOLDER) pull

build:
	cargo build --manifest-path=$(INSTALLATION_FOLDER)/Cargo.toml

test:
	cargo run --manifest-path=$(INSTALLATION_FOLDER)/Cargo.toml --bin cairo-test -- --starknet --path $(SOURCE_FOLDER)

format:
	cargo run --quiet --manifest-path=$(INSTALLATION_FOLDER)/Cargo.toml --bin cairo-format -- --recursive $(SOURCE_FOLDER)

check-format:
	cargo run --manifest-path=$(INSTALLATION_FOLDER)/Cargo.toml --bin cairo-format -- --check --recursive $(SOURCE_FOLDER)

compile:
	find contracts-1.0 -type f -name '*.cairo' | \
    xargs -n1 cargo run --manifest-path=./cairo/Cargo.toml --bin starknet-compile > /dev/null

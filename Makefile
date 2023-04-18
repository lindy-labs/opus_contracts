# Won't write the called command in the console
.SILENT:

CAIRO_INSTALLATION_FOLDER=./cairo
SCARB_INSTALLATION_FOLDER=./scarb
SOURCE_FOLDER=./src

install:
	$(MAKE) initialize-cairo
	$(MAKE) initialize-scarb
	$(MAKE) build

initialize-cairo:
	if [ -d $(CAIRO_INSTALLATION_FOLDER) ]; then \
		$(MAKE) update-cairo; \
	else \
		$(MAKE) clone-cairo; \
	fi

clone-cairo:
	mkdir -p $(CAIRO_INSTALLATION_FOLDER)
	git clone --depth 1 https://github.com/starkware-libs/cairo.git $(CAIRO_INSTALLATION_FOLDER)

update-cairo:
	git -C $(CAIRO_INSTALLATION_FOLDER) pull

initialize-scarb:
	if [ -d $(SCARB_INSTALLATION_FOLDER) ]; then \
		$(MAKE) update-scarb; \
	else \
		$(MAKE) clone-scarb; \
	fi

clone-scarb:
	mkdir -p $(SCARB_INSTALLATION_FOLDER)
	git clone --depth 1 https://github.com/software-mansion/scarb.git $(SCARB_INSTALLATION_FOLDER)

update-scarb:
	git -C $(SCARB_INSTALLATION_FOLDER) pull

build:
	cargo build --manifest-path=$(CAIRO_INSTALLATION_FOLDER)/Cargo.toml
	cargo build --manifest-path=$(SCARB_INSTALLATION_FOLDER)/Cargo.toml

compile:
	cargo run --manifest-path=$(SCARB_INSTALLATION_FOLDER)/Cargo.toml --bin scarb build

format:
	cargo run --manifest-path=$(CAIRO_INSTALLATION_FOLDER)/Cargo.toml --bin cairo-format -- --recursive $(SOURCE_FOLDER) --print-parsing-errors

check-format:
	cargo run --manifest-path=$(CAIRO_INSTALLATION_FOLDER)/Cargo.toml --bin cairo-format -- --check --recursive $(SOURCE_FOLDER) --print-parsing-errors

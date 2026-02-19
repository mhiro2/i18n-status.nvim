.PHONY: deps deps-plenary deps-treesitter deps-grammars treesitter-build treesitter-install fmt lint stylua stylua-check selene rustfmt rustfmt-check rust-lint test rust-build rust-test lua-test

CC ?= cc
NVIM ?= nvim
GIT ?= git
PLENARY_PATH ?= deps/plenary.nvim
TREESITTER_PATH ?= deps/nvim-treesitter
TREESITTER_INSTALL_DIR ?= deps/treesitter
TS_GRAMMAR_JS ?= deps/tree-sitter-javascript
TS_GRAMMAR_TS ?= deps/tree-sitter-typescript
TS_GRAMMAR_JSON ?= deps/tree-sitter-json

deps: deps-plenary deps-treesitter treesitter-install

deps-plenary:
	@if [ ! -d "$(PLENARY_PATH)" ]; then \
		mkdir -p "$$(dirname "$(PLENARY_PATH)")"; \
		$(GIT) clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$(PLENARY_PATH)"; \
	fi

deps-treesitter:
	@if [ ! -d "$(TREESITTER_PATH)" ]; then \
		mkdir -p "$$(dirname "$(TREESITTER_PATH)")"; \
		$(GIT) clone --depth 1 https://github.com/nvim-treesitter/nvim-treesitter "$(TREESITTER_PATH)"; \
	fi

deps-grammars:
	@if [ ! -d "$(TS_GRAMMAR_JS)" ]; then \
		mkdir -p "$$(dirname "$(TS_GRAMMAR_JS)")"; \
		$(GIT) clone --depth 1 https://github.com/tree-sitter/tree-sitter-javascript "$(TS_GRAMMAR_JS)"; \
	fi
	@if [ ! -d "$(TS_GRAMMAR_TS)" ]; then \
		mkdir -p "$$(dirname "$(TS_GRAMMAR_TS)")"; \
		$(GIT) clone --depth 1 https://github.com/tree-sitter/tree-sitter-typescript "$(TS_GRAMMAR_TS)"; \
	fi
	@if [ ! -d "$(TS_GRAMMAR_JSON)" ]; then \
		mkdir -p "$$(dirname "$(TS_GRAMMAR_JSON)")"; \
		$(GIT) clone --depth 1 https://github.com/tree-sitter/tree-sitter-json "$(TS_GRAMMAR_JSON)"; \
	fi

treesitter-build: deps-grammars
	@mkdir -p "$(TREESITTER_INSTALL_DIR)/parser" "$(TREESITTER_INSTALL_DIR)/queries"
	@JS_SCANNER=""; \
		if [ -f "$(TS_GRAMMAR_JS)/src/scanner.c" ]; then JS_SCANNER="$(TS_GRAMMAR_JS)/src/scanner.c"; fi; \
		$(CC) -fPIC -shared -O2 -o "$(TREESITTER_INSTALL_DIR)/parser/javascript.so" \
			"$(TS_GRAMMAR_JS)/src/parser.c" $$JS_SCANNER -I "$(TS_GRAMMAR_JS)/src"
	@TS_SCANNER=""; \
		if [ -f "$(TS_GRAMMAR_TS)/typescript/src/scanner.c" ]; then TS_SCANNER="$(TS_GRAMMAR_TS)/typescript/src/scanner.c"; fi; \
		$(CC) -fPIC -shared -O2 -o "$(TREESITTER_INSTALL_DIR)/parser/typescript.so" \
			"$(TS_GRAMMAR_TS)/typescript/src/parser.c" $$TS_SCANNER -I "$(TS_GRAMMAR_TS)/typescript/src"
	@TSX_SCANNER=""; \
		if [ -f "$(TS_GRAMMAR_TS)/tsx/src/scanner.c" ]; then TSX_SCANNER="$(TS_GRAMMAR_TS)/tsx/src/scanner.c"; fi; \
		$(CC) -fPIC -shared -O2 -o "$(TREESITTER_INSTALL_DIR)/parser/tsx.so" \
			"$(TS_GRAMMAR_TS)/tsx/src/parser.c" $$TSX_SCANNER -I "$(TS_GRAMMAR_TS)/tsx/src"
	@JSON_SCANNER=""; \
		if [ -f "$(TS_GRAMMAR_JSON)/src/scanner.c" ]; then JSON_SCANNER="$(TS_GRAMMAR_JSON)/src/scanner.c"; fi; \
		$(CC) -fPIC -shared -O2 -o "$(TREESITTER_INSTALL_DIR)/parser/json.so" \
			"$(TS_GRAMMAR_JSON)/src/parser.c" $$JSON_SCANNER -I "$(TS_GRAMMAR_JSON)/src"

treesitter-install: treesitter-build

fmt: stylua rustfmt

lint: stylua-check selene rustfmt-check rust-lint

stylua:
	stylua .

stylua-check:
	stylua --check .

selene:
	selene ./lua ./plugin ./tests

rustfmt:
	cd rust && cargo fmt

rustfmt-check:
	cd rust && cargo fmt -- --check

rust-lint:
	cd rust && cargo clippy --all-targets -- -D warnings

rust-build:
	cd rust && cargo build --release

rust-test:
	cd rust && cargo test

test: lua-test rust-test

lua-test: deps rust-build
	PLENARY_PATH="$(PLENARY_PATH)" TREESITTER_INSTALL_DIR="$(TREESITTER_INSTALL_DIR)" TREESITTER_PATH="$(TREESITTER_PATH)" \
		$(NVIM) --headless -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests', {minimal_init = 'tests/minimal_init.lua'})"

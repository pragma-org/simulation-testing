SRC_FILES := $(wildcard src/*.md)

all: $(patsubst src/%.md, dist/%.md, $(SRC_FILES))

dist/%.md: src/%.md
	pandoc  --lua-filter=pandoc-include-code.lua \
                --from=gfm+attributes \
                --to=gfm \
                --output $@ \
                $<

check:
	vale src/*.md

.PHONY: check

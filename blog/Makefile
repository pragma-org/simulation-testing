SRC_FILES := $(wildcard src/*.md)
DIST_FILES := $(patsubst src/%.md, dist/%.md, $(SRC_FILES))

all: $(DIST_FILES)

dist/%.md: src/%.md
	pandoc  --lua-filter=pandoc-include-code.lua \
                --from=gfm+attributes \
                --to=gfm \
                --output $@ \
                $<

check:
	vale src/*.md

clean:
	rm $(DIST_FILES)

.PHONY: check clean

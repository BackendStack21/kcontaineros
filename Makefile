.PHONY: build test coverage

build:
	docker build --platform linux/arm64 -t kcontaineros .

# End-to-end tests against the real image.
test:
	./test/e2e.sh

# The same tests against an instrumented build; fails under 99% line coverage.
coverage:
	COV=1 ./test/e2e.sh

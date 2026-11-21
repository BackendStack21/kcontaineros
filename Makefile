.PHONY: build test coverage site-preview site-deploy

build:
	docker build --platform linux/arm64 -t kcontaineros .

# End-to-end tests against the real image.
test:
	./test/e2e.sh

# The same tests against an instrumented build; fails under 99% line coverage.
coverage:
	COV=1 ./test/e2e.sh

# The landing page (docs/) on Cloudflare Workers static assets; see wrangler.jsonc.
site-preview:
	npx wrangler dev

site-deploy:
	npx wrangler deploy

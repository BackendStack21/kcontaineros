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

# Refuses to publish a page whose embedded binary is not the one just built:
# commit what tools/update-docs.sh changed, then deploy.
site-deploy: build
	tools/update-docs.sh
	@git diff --quiet HEAD -- docs/ || { echo "docs/ differs from the last commit: review, commit, then run this again" >&2; exit 1; }
	npx wrangler deploy

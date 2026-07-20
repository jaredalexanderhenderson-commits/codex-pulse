SHELL := /bin/zsh

.PHONY: app test package verify

app:
	@zsh scripts/build_app.sh

test:
	@zsh scripts/run_tests.sh

package: app
	@zsh scripts/package_app.sh

verify: test app
	@zsh scripts/verify_app.sh

# `make test` is a shortcut for the test harness; `mise run test` adds the JUnit report.
.PHONY: test
test:
	bash tests/run.sh

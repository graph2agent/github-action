.PHONY: test lint check

test:
	bash tests/run.sh

lint:
	bash -n scripts/*.sh tests/*.sh tests/fixtures/*
	actionlint .github/workflows/*.yml

check: lint test

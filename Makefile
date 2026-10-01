# Convenience targets. `make test` runs the whole suite; `make test T=export` runs matching tests.
.PHONY: test
test:
	bash tests/run.sh $(T)

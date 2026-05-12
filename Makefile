# Pair Polymath — developer commands.
# Targets are intentionally thin wrappers around bash/bats/docker so the
# project stays inspectable. Nothing here is required at install time;
# end users run bin/install.sh directly.

.PHONY: help test test-linux test-eval lint clean

help:
	@printf 'Pair Polymath developer commands:\n'
	@printf '  make test        — run bats locally (host bash, recursive)\n'
	@printf '  make test-linux  — run bats inside Ubuntu Docker (Linux bash 5)\n'
	@printf '                     catches BSD-vs-GNU and bash-3.2-vs-5 portability bugs\n'
	@printf '                     before CI roundtrip. Requires Docker.\n'
	@printf '  make test-eval   — run only the eval-harness subset\n'
	@printf '  make lint        — shellcheck across bin/ and lib/\n'
	@printf '  make clean       — remove transient artifacts (test/eval/runs/)\n'

# Host bats run. Mirrors the CI bats workflow.
test:
	bats -r test/

# Linux bats run inside a Docker container. Mirrors the install-test workflow's
# bats step. The image is the official bats-core/bats one (pinned to a stable
# tag) — small (~10 MB), pre-installed with bash + jq. Mounts the repo
# read-only; bats writes nothing back.
#
# Why: this session caught 6 cross-platform bugs that only Ubuntu CI surfaced
# (issue #37 retro). Running this target before push saves ~5 min/round-trip.
test-linux:
	@command -v docker >/dev/null 2>&1 || { \
	  printf 'make test-linux: docker not found. Install Docker Desktop or skip.\n' >&2; \
	  exit 1; \
	}
	docker run --rm -v "$$PWD:/repo:ro" -w /repo bats/bats:1.10.0 -r /repo/test/

# Just the eval-harness bats suite. Faster iteration when working on
# test/eval/*.sh or bin/statusline.sh's PP_EVAL_MODE path.
test-eval:
	bats test/eval/

# Surface lint problems early. Excludes generated artifacts.
lint:
	shellcheck bin/install.sh bin/statusline.sh bin/uninstall.sh bin/polymath
	shellcheck lib/*.sh
	shellcheck test/eval/run-eval.sh test/eval/score.sh

clean:
	rm -rf test/eval/runs/

.PHONY: help dev test verify build run docker docker-codex docker-opencode docker-all lint-sh

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  dev           Start the frontend Vite dev server (http://localhost:5173)"
	@echo "  test          Runtime-verify Lyric logic (scripts/verify.sh)"
	@echo "  build         Full server build — API + Web + Docker library"
	@echo "  run           Build full server and start it on port 8080"
	@echo "  docker        Build claude-code:base runner image"
	@echo "  docker-codex  Build codex:base runner image"
	@echo "  docker-opencode  Build opencode:base runner image"
	@echo "  docker-all    Build all three harness runner images"
	@echo "  lint-sh       Syntax-check all shell scripts (bash -n)"

dev:
	./scripts/dev.sh

test:
	./scripts/verify.sh

build:
	./scripts/build-full.sh

run:
	./scripts/run-api.sh

docker:
	./scripts/build-docker.sh claude

docker-codex:
	./scripts/build-docker.sh codex

docker-opencode:
	./scripts/build-docker.sh opencode

docker-all:
	./scripts/build-docker.sh all

lint-sh:
	@for f in \
	    docker/entrypoint.sh \
	    docker/entrypoint-codex.sh \
	    docker/entrypoint-opencode.sh \
	    deploy/install-docker.sh \
	    deploy/backup.sh \
	    scripts/verify.sh \
	    scripts/build-full.sh \
	    scripts/dev.sh \
	    scripts/build-docker.sh \
	    scripts/repro-compiler-bug.sh; do \
	    bash -n "$$f" && echo "ok: $$f"; \
	done

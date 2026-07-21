# Every CI job body is a make target — runner-agnostic by construction.
# ARCH follows the host by default (arm64 Macs build native); CI passes amd64.
VERSION ?= sha-$(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
IMAGE   ?= ghcr.io/snk5125/cribl-fips
ARCH    ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: setup lint test generate build validate status package push run clean

setup:
	@command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
	@echo "ok: docker $$(docker info --format '{{.ServerVersion}}' 2>/dev/null)"

lint:
	./ci/lint.sh

# fetch = the "generate" step here: resolve the pinned vendor tarball
generate:
	./ci/fetch-cribl.sh $(ARCH)

build: generate
	ARCH=$(ARCH) IMAGE=$(IMAGE) ./ci/build.sh $(VERSION)

# no unit tests — the boot-and-assert validator is the test suite
test: validate

validate: build
	./ci/validate.sh $(IMAGE):$(VERSION)

status:
	@docker image ls "$(IMAGE)" 2>/dev/null || true

# the image IS the package
package: build

push:
	./ci/push.sh $(IMAGE) $(VERSION)

# dev = single instance, FIPS off (Cribl refuses FIPS in single mode).
# FIPS stack: CRIBL_LICENSE=... docker compose --profile fips up -d
run: build
	IMAGE=$(IMAGE) VERSION=$(VERSION) docker compose --profile dev up -d

clean:
	rm -rf build
	-docker rmi $(IMAGE):$(VERSION) $(IMAGE):latest 2>/dev/null || true

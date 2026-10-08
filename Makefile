SHELL := /usr/bin/env bash
.PHONY: download seed kvm-start kvm-stop kvm-status test
INSTANCE ?= pipette
MEMORY ?= 2048
CPUS ?= 2
DISK ?= 16G
SSH_PORT ?= 2222
download:
	./scripts/download.sh
seed:
	./scripts/seed.sh '$(INSTANCE)'
kvm-start:
	./scripts/kvm.sh start '$(INSTANCE)' --memory '$(MEMORY)' --cpus '$(CPUS)' --disk '$(DISK)' --ssh-port '$(SSH_PORT)'
kvm-stop:
	./scripts/kvm.sh stop '$(INSTANCE)'
kvm-status:
	./scripts/kvm.sh status '$(INSTANCE)'
test:
	mkdir -p build/test-tmp
	TMPDIR="$(CURDIR)/build/test-tmp" bash tests/host.sh

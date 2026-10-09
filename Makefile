SHELL := /usr/bin/env bash
.PHONY: download seed kvm-start kvm-stop kvm-status test validate

INSTANCE ?= pipette
MEMORY ?= 2048
CPUS ?= 2
DISK ?= 16G
SSH_PORT ?= 2222
export INSTANCE MEMORY CPUS DISK SSH_PORT

download:
	./scripts/download.sh

seed:
	./scripts/seed.sh "$$INSTANCE"

kvm-start:
	./scripts/kvm.sh start "$$INSTANCE" --memory "$$MEMORY" --cpus "$$CPUS" --disk "$$DISK" --ssh-port "$$SSH_PORT"

kvm-stop:
	./scripts/kvm.sh stop "$$INSTANCE"

kvm-status:
	./scripts/kvm.sh status "$$INSTANCE"

validate:
	@test -n "$$INSTANCE" || { echo 'Set INSTANCE' >&2; exit 2; }
	python3 scripts/validate.py --instance "$$INSTANCE" --ssh-port "$$SSH_PORT"

test:
	mkdir -p build/test-tmp
	TMPDIR="$(CURDIR)/build/test-tmp" PYTHONOPTIMIZE= bash tests/host.sh
	TMPDIR="$(CURDIR)/build/test-tmp" PYTHONOPTIMIZE= python3 -m unittest discover -s tests -p validate.py
	TMPDIR="$(CURDIR)/build/test-tmp" PYTHONOPTIMIZE= python3 -m unittest discover -s tests -p kvm.py

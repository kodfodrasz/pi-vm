SHELL := /usr/bin/env bash
.PHONY: download seed kvm-start kvm-stop kvm-status test validate
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
validate:
	@test -n "$(INSTANCE)" || { echo 'Set INSTANCE' >&2; exit 2; }
	python3 scripts/validate.py --instance '$(INSTANCE)' --ssh-port '$(SSH_PORT)' $(VALIDATE_FLAGS)
test:
	mkdir -p build/test-tmp
	TMPDIR="$(CURDIR)/build/test-tmp" bash tests/host.sh
	python3 -m unittest discover -s tests -p validate.py

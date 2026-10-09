.PHONY: download seed kvm-start kvm-stop kvm-status hyperv-image test validate

INSTANCE ?= pipette
MEMORY ?= 2048
CPUS ?= 2
DISK ?= 16G
SSH_PORT ?= 2222

uv-run = uv run --script

download:
	$(uv-run) scripts/kvm.py download

seed:
	$(uv-run) scripts/seed.py $(INSTANCE) --output build/$(INSTANCE)-seed.iso

kvm-start:
	$(uv-run) scripts/kvm.py start $(INSTANCE) --memory $(MEMORY) --cpus $(CPUS) --disk $(DISK) --ssh-port $(SSH_PORT)

kvm-stop:
	$(uv-run) scripts/kvm.py stop $(INSTANCE)

kvm-status:
	$(uv-run) scripts/kvm.py status $(INSTANCE)

hyperv-image:
	$(uv-run) scripts/hyperv.py image

validate:
	$(uv-run) scripts/validate.py --instance $(INSTANCE) --ssh-port $(SSH_PORT)

test:
	$(uv-run) tests/test_python_tools.py
	$(uv-run) tests/validate.py

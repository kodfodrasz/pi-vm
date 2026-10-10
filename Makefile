.PHONY: download seed kvm-start kvm-stop kvm-status test test-powershell validate

INSTANCE ?= pipette
MEMORY ?= 2048
CPUS ?= 2
DISK ?= 16G
SSH_PORT ?= 2222

uv-run = uv run --script

download:
	$(uv-run) scripts/kvm/kvm.py download

seed:
	$(uv-run) scripts/build/seed.py $(INSTANCE) --output build/$(INSTANCE)-seed.iso

kvm-start:
	$(uv-run) scripts/kvm/kvm.py start $(INSTANCE) --memory $(MEMORY) --cpus $(CPUS) --disk $(DISK) --ssh-port $(SSH_PORT)

kvm-stop:
	$(uv-run) scripts/kvm/kvm.py stop $(INSTANCE)

kvm-status:
	$(uv-run) scripts/kvm/kvm.py status $(INSTANCE)

validate:
	$(uv-run) scripts/build/validate.py --instance $(INSTANCE) --ssh-port $(SSH_PORT)

test:
	$(uv-run) tests/test_python_tools.py
	$(uv-run) tests/test_guest_bootstrap.py
	$(uv-run) tests/test_guest_powershell.py
	$(uv-run) tests/validate.py
	$(MAKE) test-powershell

test-powershell:
	@if command -v pwsh >/dev/null 2>&1; then \
		pwsh -NoProfile -File tests/powershell-syntax.ps1 && \
		pwsh -NoProfile -File tests/hyperv.ps1; \
	else \
		echo "SKIP: PowerShell parser and Hyper-V offline fixtures (pwsh not installed)"; \
	fi

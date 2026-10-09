SHELL := /usr/bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:
.SILENT:

STAGE ?= /opt/pi-vm
CONFIG ?= /etc/pi-vm
STATE ?= /var/lib/pi-vm
CACHE ?= /var/cache/pi-vm
PI_HOME ?= /home/pi
SKEL ?= /etc/skel
SSH_CONFIG ?= /etc/ssh/sshd_config.d
SUDOERS ?= /etc/sudoers.d
SAMBA_CONFIG ?= /etc/samba/smb.conf
AVAHI_SERVICES ?= /etc/avahi/services
SHELLS_FILE ?= /etc/shells
SUBUID_FILE ?= /etc/subuid
SUBGID_FILE ?= /etc/subgid
AZURE_CONFIG ?= /etc/waagent.conf
AZURE_STATE ?= /var/lib/waagent
AZURE_LOG ?= /var/log/waagent.log

STARSHIP_URL ?= https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz
STARSHIP_SHA256 ?= b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3
STARSHIP_ARCHIVE ?= $(CACHE)/starship.tar.gz
STARSHIP_BIN ?= /usr/local/bin/starship
BOOTSTRAP_BIN ?= /usr/local/sbin/pi-vm-bootstrap

PACKAGES := avahi cloud-utils-growpart curl fastfetch fd-find firewalld fish gcc gcc-c++ git \
	hyperv-daemons jq make micro nodejs npm openssl podman python3 ripgrep rsync samba \
	samba-client tmux unzip vim-enhanced wsdd
CONFIG_FILES := $(CONFIG)/authorized_keys $(CONFIG)/public-key-identities.txt \
	$(CONFIG)/vimrc $(CONFIG)/tmux.conf $(CONFIG)/starship.toml \
	$(CONFIG)/config.fish $(CONFIG)/pi.fish $(CONFIG)/smb.conf \
	$(CONFIG)/firewall-sources.conf $(CONFIG)/avahi-samba.service \
	$(CONFIG)/pi-settings.json $(CONFIG)/AGENTS.md $(CONFIG)/kodfodrasz/SKILL.md

.PHONY: bootstrap validate-input set-hostname install-packages remove-azure \
	install-starship configure-ssh stage-configs install-default-configs \
	configure-pi-user configure-file-sharing print-deploy-key run-local-payload

# Every state-changing step names its predecessor. This keeps the graph safe
# under -j instead of relying on sibling prerequisite ordering.
bootstrap: run-local-payload
run-local-payload: print-deploy-key
print-deploy-key: configure-file-sharing
configure-file-sharing: configure-pi-user
configure-pi-user: install-default-configs
install-default-configs: configure-ssh
configure-ssh: install-starship
install-starship: remove-azure
remove-azure: stage-configs
stage-configs: install-packages
install-packages: set-hostname
set-hostname: validate-input

validate-input:
	[[ $${VM_HOSTNAME:-} =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$$ ]]
	[[ -d $(STAGE) ]]

set-hostname:
	hostnamectl set-hostname "$${VM_HOSTNAME}"

install-packages:
	dnf -y install $(PACKAGES)

remove-azure:
	installed=()
	for package in azure-vm-utils WALinuxAgent WALinuxAgent-udev; do
		if rpm -q "$$package" >/dev/null 2>&1; then
			installed+=("$$package")
		fi
	done
	if (( $${#installed[@]} )); then
		systemctl disable --now waagent.service 2>/dev/null || true
		dnf -y remove "$${installed[@]}"
	fi
	for path in "$(AZURE_CONFIG)" "$(AZURE_STATE)" "$(AZURE_LOG)"; do
		if [[ -L $$path || -f $$path ]]; then
			rm -f -- "$$path"
		elif [[ -d $$path ]]; then
			rm -rf -- "$$path"
		fi
	done

$(CACHE):
	install -d -m 0755 "$@"

$(STARSHIP_ARCHIVE): | $(CACHE)
	temporary=$@.tmp
	rm -f -- "$$temporary"
	curl --fail --location --retry 3 "$(STARSHIP_URL)" -o "$$temporary"
	printf '%s  %s\n' '$(STARSHIP_SHA256)' "$$temporary" | sha256sum -c -
	chmod 0644 "$$temporary"
	mv -f -- "$$temporary" "$@"

$(STARSHIP_BIN): $(STARSHIP_ARCHIVE)
	install -d -m 0755 "$$(dirname "$@")"
	temporary=$@.tmp
	rm -f -- "$$temporary"
	tar -xzf "$<" --to-stdout starship > "$$temporary"
	chmod 0755 "$$temporary"
	install -m 0755 "$$temporary" "$@"
	rm -f -- "$$temporary"

install-starship: $(STARSHIP_BIN)

# These are real installed files, not success stamps. install also repairs
# modes and ownership when a source file changes.
$(CONFIG):
	install -d -m 0755 "$@"
$(STATE):
	install -d -m 0755 "$@"
$(CONFIG)/kodfodrasz:
	install -d -m 0755 "$@"

$(CONFIG)/authorized_keys: $(STAGE)/authorized_keys | $(CONFIG)
	install -m 0600 -o root -g root "$<" "$@"
$(CONFIG)/public-key-identities.txt: $(STAGE)/public-key-identities.txt | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/vimrc: $(STAGE)/config/vimrc | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/tmux.conf: $(STAGE)/config/tmux.conf | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/starship.toml: $(STAGE)/config/starship.toml | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/config.fish: $(STAGE)/config/config.fish | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/pi.fish: $(STAGE)/config/pi.fish | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/smb.conf: $(STAGE)/config/smb.conf | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/firewall-sources.conf: $(STAGE)/config/firewall-sources.conf | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/avahi-samba.service: $(STAGE)/config/avahi-samba.service | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/pi-settings.json: $(STAGE)/pi/settings.json | $(CONFIG)
	install -m 0600 -o root -g root "$<" "$@"
$(CONFIG)/AGENTS.md: $(STAGE)/pi/AGENTS.md | $(CONFIG)
	install -m 0644 -o root -g root "$<" "$@"
$(CONFIG)/kodfodrasz/SKILL.md: $(STAGE)/skills/kodfodrasz/SKILL.md | $(CONFIG)/kodfodrasz
	install -m 0644 -o root -g root "$<" "$@"

$(BOOTSTRAP_BIN): $(STAGE)/bootstrap.sh
	install -D -m 0755 -o root -g root "$<" "$@"

stage-configs: $(CONFIG_FILES) $(BOOTSTRAP_BIN)
	if [[ -d $(STAGE)/local ]]; then
		if [[ -L $(CONFIG)/local ]]; then rm -f -- $(CONFIG)/local; fi
		rm -rf -- $(CONFIG)/local
		install -d -m 0700 -o root -g root $(CONFIG)/local
		cp -a --no-preserve=ownership $(STAGE)/local/. $(CONFIG)/local/
		find -P $(CONFIG)/local -exec chown -h root:root {} +
		find -P $(CONFIG)/local -type f ! -name bootstrap.sh -exec chmod 0600 {} +
		if [[ -f $(CONFIG)/local/bootstrap.sh ]]; then chmod 0700 $(CONFIG)/local/bootstrap.sh; fi
	fi

configure-ssh:
	install -d -m 0755 "$(SSH_CONFIG)"
	install -m 0644 -o root -g root "$(STAGE)/config/sshd.conf" "$(SSH_CONFIG)/10-pi-vm.conf"
	systemctl enable --now sshd

install-default-configs:
	install -D -m 0644 "$(CONFIG)/vimrc" "$(SKEL)/.vimrc"
	install -D -m 0644 "$(CONFIG)/tmux.conf" "$(SKEL)/.config/tmux/tmux.conf"
	install -D -m 0644 "$(CONFIG)/starship.toml" "$(SKEL)/.config/starship.toml"
	install -D -m 0644 "$(CONFIG)/config.fish" "$(SKEL)/.config/fish/config.fish"
	install -D -m 0644 "$(CONFIG)/pi.fish" "$(SKEL)/.config/fish/completions/pi.fish"

configure-pi-user:
	if ! id pi >/dev/null 2>&1; then
		useradd --create-home --shell /bin/bash --groups wheel pi
	fi
	usermod --lock pi
	install -d -m 0700 -o pi -g pi "$(PI_HOME)/.ssh"
	install -m 0600 -o pi -g pi "$(CONFIG)/authorized_keys" "$(PI_HOME)/.ssh/authorized_keys"
	if [[ ! -e $(PI_HOME)/.ssh/pi-vm-deploy ]]; then
		runuser -u pi -- ssh-keygen -q -t ed25519 -N '' -C "pi-vm-deploy@$${VM_HOSTNAME}" -f "$(PI_HOME)/.ssh/pi-vm-deploy"
	fi
	install -D -m 0440 -o root -g root "$(STAGE)/config/sudoers" "$(SUDOERS)/90-pi-vm"
	visudo -cf "$(SUDOERS)/90-pi-vm"
	install -D -m 0644 -o pi -g pi "$(CONFIG)/vimrc" "$(PI_HOME)/.vimrc"
	install -D -m 0644 -o pi -g pi "$(CONFIG)/tmux.conf" "$(PI_HOME)/.config/tmux/tmux.conf"
	install -D -m 0644 -o pi -g pi "$(CONFIG)/starship.toml" "$(PI_HOME)/.config/starship.toml"
	install -D -m 0644 -o pi -g pi "$(CONFIG)/config.fish" "$(PI_HOME)/.config/fish/config.fish"
	install -D -m 0644 -o pi -g pi "$(CONFIG)/pi.fish" "$(PI_HOME)/.config/fish/completions/pi.fish"
	install -D -m 0600 -o pi -g pi "$(CONFIG)/pi-settings.json" "$(PI_HOME)/.pi/agent/settings.json"
	install -D -m 0644 -o pi -g pi "$(CONFIG)/AGENTS.md" "$(PI_HOME)/.pi/agent/AGENTS.md"
	install -D -m 0644 -o pi -g pi "$(CONFIG)/kodfodrasz/SKILL.md" "$(PI_HOME)/.pi/agent/skills/kodfodrasz/SKILL.md"
	install -d -m 0755 -o pi -g pi "$(PI_HOME)/.local/share/pi-npm" "$(PI_HOME)/.local/bin"
	runuser -u pi -- env HOME="$(PI_HOME)" npm install --global --prefix "$(PI_HOME)/.local/share/pi-npm" @earendil-works/pi-coding-agent@1.1.0
	ln -sfn "$(PI_HOME)/.local/share/pi-npm/bin/pi" "$(PI_HOME)/.local/bin/pi"
	chown -h pi:pi "$(PI_HOME)/.local/bin/pi"
	runuser -u pi -- env HOME="$(PI_HOME)" "$(PI_HOME)/.local/bin/pi" install npm:pi-web-access@0.37.0
	runuser -u pi -- env HOME="$(PI_HOME)" "$(PI_HOME)/.local/bin/pi" install npm:pi-subagents@0.76.1
	runuser -u pi -- env HOME="$(PI_HOME)" "$(PI_HOME)/.local/bin/pi" install npm:pi-reset-usage-limit@0.1.1
	runuser -u pi -- env HOME="$(PI_HOME)" "$(PI_HOME)/.local/bin/pi" install npm:@wayner6/pi-usage@0.3.0
	runuser -u pi -- env HOME="$(PI_HOME)" "$(PI_HOME)/.local/bin/pi" install npm:pi-keep-going@1.1.0
	find -P "$(PI_HOME)/.config" "$(PI_HOME)/.pi" "$(PI_HOME)/.local" -exec chown -h pi:pi {} +
	grep -q '^pi:' "$(SUBUID_FILE)" || usermod --add-subuids 100000-165535 pi
	grep -q '^pi:' "$(SUBGID_FILE)" || usermod --add-subgids 100000-165535 pi
	loginctl enable-linger pi
	fish_shell=$$(grep -E '/fish$$' "$(SHELLS_FILE)" | head -1 || true)
	[[ -n $$fish_shell ]]
	chsh -s "$$fish_shell" pi

configure-file-sharing: $(STATE)
	install -D -m 0644 -o root -g root "$(CONFIG)/smb.conf" "$(SAMBA_CONFIG)"
	install -D -m 0644 -o root -g root "$(CONFIG)/avahi-samba.service" "$(AVAHI_SERVICES)/samba.service"
	testparm -s >/dev/null
	setsebool -P samba_enable_home_dirs on
	# This is a sourced, root-owned configuration file, not user input.
	source "$(CONFIG)/firewall-sources.conf"
	systemctl enable --now firewalld
	firewall-cmd --set-default-zone=public
	firewall-cmd --permanent --zone=public --add-service=ssh
	firewall-cmd --permanent --zone=public --add-service=mdns
	firewall-cmd --permanent --zone=public --add-service=wsdd
	firewall-cmd --permanent --zone=public --add-service=wsdd-http
	firewall-cmd --permanent --zone=trusted --add-source="$$HOME_LAN_CIDR"
	firewall-cmd --permanent --zone=trusted --add-source="$$VPN_CIDR"
	firewall-cmd --reload
	password_file=$(STATE)/samba-initial-password
	if ! pdbedit -L -u pi >/dev/null 2>&1; then
		if [[ ! -s $$password_file ]]; then
			temporary=$$(mktemp "$(STATE)/.samba-password.XXXXXX")
			chmod 0600 "$$temporary"
			umask 077
			openssl rand -hex 18 > "$$temporary"
			mv -f -- "$$temporary" "$$password_file"
		fi
		password=$$(<"$$password_file")
		printf '%s\n%s\n' "$$password" "$$password" | smbpasswd -a -s pi
	fi
	systemctl enable --now smb nmb wsdd avahi-daemon
	if [[ -s $$password_file ]]; then
		echo 'Samba initial login:'
		echo '  user: pi'
		printf '  password: %s\n' "$$(<"$$password_file")"
		echo 'Change it with: sudo smbpasswd pi'
		echo 'Then remove the saved initial value: sudo rm -f /var/lib/pi-vm/samba-initial-password'
	fi

print-deploy-key:
	echo 'Private-repository deploy public key:'
	cat "$(PI_HOME)/.ssh/pi-vm-deploy.pub"
	echo 'After authorizing it, clone with:'
	echo "  GIT_SSH_COMMAND='ssh -i ~/.ssh/pi-vm-deploy -o IdentitiesOnly=yes' git clone REPOSITORY"

run-local-payload:
	if [[ -x $(CONFIG)/local/bootstrap.sh ]]; then
		PI_VM_LOCAL_DIR=$(CONFIG)/local "$(CONFIG)/local/bootstrap.sh"
	fi

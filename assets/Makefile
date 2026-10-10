SHELL := /usr/bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:
.SILENT:

STAGE ?= /opt/pi-vm
SELINUX_CONFIG ?= /etc/selinux/config
STATE ?= /var/lib/pi-vm
CACHE ?= /var/cache/pi-vm
PI_USER ?= pi
export PI_USER
SKEL ?= /etc/skel
SSH_CONFIG ?= /etc/ssh/sshd_config.d
SUDOERS ?= /etc/sudoers.d
SAMBA_CONFIG ?= /etc/samba/smb.conf
AVAHI_SERVICES ?= /etc/avahi/services
SHELLS_FILE ?= /etc/shells
SUBUID_FILE ?= /etc/subuid
SUBGID_FILE ?= /etc/subgid
AZURE_CONFIG ?= /etc/waagent.conf
AZURE_SELINUX_CONFIG ?= /etc/selinux/config
STATE ?= /var/lib/waagent
AZURE_LOG ?= /var/log/waagent.log

STARSHIP_URL ?= https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz
STARSHIP_SHA256 ?= b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3
STARSHIP_ARCHIVE ?= $(CACHE)/starship.tar.gz
STARSHIP_BIN ?= /usr/local/bin/starship
BOOTSTRAP_BIN ?= /usr/local/sbin/pi-vm-bootstrap

PACKAGES := avahi cloud-utils-growpart curl fastfetch fd-find firewalld fish gcc gcc-c++ git \
	hyperv-daemons jq make micro nodejs npm openssl podman python3 ripgrep rsync samba \
	samba-client tmux unzip util-linux vim-enhanced wsdd grubby

# Bootstrap ordering and package reconciliation

.PHONY: bootstrap validate-input set-hostname install-packages remove-azure \
	install-starship configure-system configure-user configure-file-sharing run-local-payload

bootstrap: run-local-payload
run-local-payload: configure-file-sharing
configure-file-sharing: configure-user
configure-user: configure-system
configure-system: install-starship
install-starship: remove-azure
remove-azure: install-packages
install-packages: set-hostname | $(BOOTSTRAP_BIN)
set-hostname: validate-input

validate-input:
	[[ $${VM_HOSTNAME:-} =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$$ ]]
	[[ $$PI_USER =~ ^[a-z_][a-z0-9_-]{0,31}$$ && $$PI_USER != root ]]
	[[ -d $(STAGE) ]]
	if [[ -d $(STAGE)/local ]]; then
		find -P "$(STAGE)/local" -exec chown -h root:root {} +
		find -P "$(STAGE)/local" -type d -exec chmod 0700 {} +
		find -P "$(STAGE)/local" -type f ! -name bootstrap.sh -exec chmod 0600 {} +
		if [[ -f $(STAGE)/local/bootstrap.sh ]]; then chmod 0700 "$(STAGE)/local/bootstrap.sh"; fi
	fi
	source "$(STAGE)/user-context.sh"

set-hostname:
	hostnamectl set-hostname "$${VM_HOSTNAME}"

install-packages:
	dnf -y install $(PACKAGES)

$(BOOTSTRAP_BIN): $(STAGE)/bootstrap.sh | validate-input
	install -D -m 0755 -o root -g root "$<" "$@"

# Pinned Starship download; real file targets retain cache on retries

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

$(STARSHIP_ARCHIVE): | $(CACHE) install-packages
	temporary=$@.tmp
	rm -f -- "$$temporary"
	curl --fail --location --retry 3 "$(STARSHIP_URL)" -o "$$temporary"
	printf '%s  %s\n' '$(STARSHIP_SHA256)' "$$temporary" | sha256sum -c -
	chmod 0644 "$$temporary"
	mv -f -- "$$temporary" "$@"

$(STARSHIP_BIN): $(STARSHIP_ARCHIVE) | install-packages
	install -d -m 0755 "$$(dirname "$@")"
	temporary=$@.tmp
	rm -f -- "$$temporary"
	tar -xzf "$<" --to-stdout starship > "$$temporary"
	chmod 0755 "$$temporary"
	install -m 0755 "$$temporary" "$@"
	rm -f -- "$$temporary"

install-starship: $(STARSHIP_BIN)


# System destinations are installed directly from the staged seed

$(SSH_CONFIG)/10-pi-vm.conf: $(STAGE)/config/sshd.conf | install-packages
	install -D -m 0644 -o root -g root "$<" "$@"

$(SAMBA_CONFIG): $(STAGE)/config/smb.conf | install-packages
	install -D -m 0644 -o root -g root "$<" "$@"

$(AVAHI_SERVICES)/samba.service: $(STAGE)/config/avahi-samba.service | install-packages
	install -D -m 0644 -o root -g root "$<" "$@"

configure-system: $(SSH_CONFIG)/10-pi-vm.conf $(SAMBA_CONFIG) $(AVAHI_SERVICES)/samba.service
	systemctl enable --now sshd
	install -D -m 0440 -o root -g root "$(STAGE)/config/sudoers" "$(SUDOERS)/90-pi-vm"
	visudo -cf "$(SUDOERS)/90-pi-vm"
	# Fedora requires selinux=0 on the kernel command line to fully disable it.
	grubby --update-kernel=ALL --args=selinux=0
	sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$(SELINUX_CONFIG)"
	grep -qx 'SELINUX=disabled' "$(SELINUX_CONFIG)"
	install -D -m 0644 "$(STAGE)/config/vimrc" "$(SKEL)/.vimrc"
	install -D -m 0644 "$(STAGE)/config/tmux.conf" "$(SKEL)/.config/tmux/tmux.conf"
	install -D -m 0644 "$(STAGE)/config/starship.toml" "$(SKEL)/.config/starship.toml"
	install -D -m 0644 "$(STAGE)/config/config.fish" "$(SKEL)/.config/fish/config.fish"
	install -D -m 0644 "$(STAGE)/config/pi.fish" "$(SKEL)/.config/fish/completions/pi.fish"

# Cloud-init owns the account; use its home and primary group

configure-user:
	source "$(STAGE)/user-context.sh"
	usermod --lock --append --groups wheel "$$PI_USER"
	install -d -m 0700 -o "$$PI_USER" -g "$$PI_GROUP" "$$PI_HOME/.ssh"
	install -m 0600 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/authorized_keys" "$$PI_HOME/.ssh/authorized_keys"
	for mapping in 'vimrc:.vimrc' 'tmux.conf:.config/tmux/tmux.conf' 'starship.toml:.config/starship.toml' 'config.fish:.config/fish/config.fish' 'pi.fish:.config/fish/completions/pi.fish'; do
		source_file=$${mapping%%:*}; destination=$$PI_HOME/$${mapping#*:}
		if [[ ! -e $$destination ]]; then
			install -D -m 0644 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/config/$$source_file" "$$destination"
		fi
	done
	install -D -m 0600 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/pi/settings.json" "$$PI_HOME/.pi/agent/settings.json"
	install -D -m 0644 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/pi/AGENTS.md" "$$PI_HOME/.pi/agent/AGENTS.md"
	install -D -m 0644 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/skills/kodfodrasz/SKILL.md" "$$PI_HOME/.pi/agent/skills/kodfodrasz/SKILL.md"
	install -D -m 0755 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/config/readme-wall.sh" "$$PI_HOME/.local/bin/pi-vm-readme"
	install -D -m 0644 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/config/login.fish" "$$PI_HOME/.config/fish/conf.d/pi-vm-login.fish"
	install -D -m 0644 -o "$$PI_USER" -g "$$PI_GROUP" "$(STAGE)/config/login.bash" "$$PI_HOME/.config/pi-vm/login.bash"
	profile_line='if [ -n "$${BASH_VERSION:-}" ]; then . "$$HOME/.config/pi-vm/login.bash"; fi'
	# Bash reads the first of these existing profiles on login.
	profile=$$PI_HOME/.bash_profile
	if [[ ! -e $$profile ]]; then
		if [[ -e $$PI_HOME/.bash_login ]]; then profile=$$PI_HOME/.bash_login
		elif [[ -e $$PI_HOME/.profile ]]; then profile=$$PI_HOME/.profile
		fi
	fi
	touch "$$profile"
	grep -Fxq "$$profile_line" "$$profile" || printf '\n%s\n' "$$profile_line" >> "$$profile"
	chown "$$PI_USER:$$PI_GROUP" "$$profile"
	find -P "$$PI_HOME/.config" "$$PI_HOME/.pi" "$$PI_HOME/.local" -exec chown -h "$$PI_USER:$$PI_GROUP" {} +
	as_user sh "$(STAGE)/install-user.sh"
	bash "$(STAGE)/write-user-readme.sh"
	grep -q "^$$PI_USER:" "$(SUBUID_FILE)" || usermod --add-subuids 100000-165535 "$$PI_USER"
	grep -q "^$$PI_USER:" "$(SUBGID_FILE)" || usermod --add-subgids 100000-165535 "$$PI_USER"
	loginctl enable-linger "$$PI_USER"
	fish_shell=$$(grep -E '/fish$$' "$(SHELLS_FILE)" | head -1 || true)
	[[ -n $$fish_shell ]]
	chsh -s "$$fish_shell" "$$PI_USER"
	echo 'Private-repository deploy public key:'
	cat "$$PI_HOME/.ssh/pi-vm-deploy.pub"
	echo "Authorize this key, then see ~/README.md for the clone command."

# Named trusted sets preserve additional entries added by the owner

configure-file-sharing:
	source "$(STAGE)/user-context.sh"
	testparm -s >/dev/null
	source "$(STAGE)/config/firewall-sources.conf"
	systemctl enable --now firewalld
	firewall-cmd --set-default-zone=public
	for service in ssh mdns wsdd wsdd-http; do
		firewall-cmd --permanent --zone=public --add-service="$$service"
	done
	for definition in "home_lan:$$HOME_LAN_CIDR" "vpn:$$VPN_CIDR"; do
		name=$${definition%%:*}; cidr=$${definition#*:}
		if ! firewall-cmd --permanent --get-ipsets | tr ' ' '\n' | grep -Fxq "$$name"; then
			firewall-cmd --permanent --new-ipset="$$name" --type=hash:net
		fi
		firewall-cmd --permanent --ipset="$$name" --query-entry="$$cidr" >/dev/null || firewall-cmd --permanent --ipset="$$name" --add-entry="$$cidr"
		firewall-cmd --permanent --zone=trusted --query-source="ipset:$$name" >/dev/null || firewall-cmd --permanent --zone=trusted --add-source="ipset:$$name"
	done
	firewall-cmd --reload
	password_file=$$PI_HOME/samba-initial-password
	if ! pdbedit -L -u "$$PI_USER" >/dev/null 2>&1; then
		if [[ ! -s $$password_file ]]; then
			temporary=$$(mktemp "$$PI_HOME/.samba-password.XXXXXX")
			chmod 0600 "$$temporary"
			openssl rand -hex 18 > "$$temporary"
			chown "$$PI_USER:$$PI_GROUP" "$$temporary"
			mv -f -- "$$temporary" "$$password_file"
		fi
		password=$$(<"$$password_file")
		printf '%s\n%s\n' "$$password" "$$password" | smbpasswd -a -s "$$PI_USER"
		echo 'Samba initial login:'
		printf '  user: %s\n  password: %s\n  saved in: %s\n' "$$PI_USER" "$$password" "$$password_file"
		printf 'Change it with: sudo smbpasswd %s\nThen remove ~/samba-initial-password\n' "$$PI_USER"
	fi
	systemctl enable --now smb nmb wsdd avahi-daemon

# Local root-only payload stays at its original /opt location

run-local-payload:
	if [[ -x $(STAGE)/local/bootstrap.sh ]]; then
		PI_VM_LOCAL_DIR="$(STAGE)/local" "$(STAGE)/local/bootstrap.sh"
	fi

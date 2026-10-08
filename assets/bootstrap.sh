#!/usr/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "pi-vm bootstrap failed at line ${LINENO} (status ${rc})" >&2; exit "$rc"' ERR

hostnamectl set-hostname "$VM_HOSTNAME"
dnf -y install fish vim-enhanced micro podman fastfetch tmux nodejs npm git ripgrep fd-find curl jq rsync unzip python3 make gcc gcc-c++ hyperv-daemons cloud-utils-growpart

# Starship is not in the Fedora 44 repositories. Verify a pinned upstream build.
install -d -m 0755 /var/cache/pi-vm
curl --fail --location --retry 3 https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz -o /var/cache/pi-vm/starship.tar.gz
printf '%s  %s\n' b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3 /var/cache/pi-vm/starship.tar.gz | sha256sum -c -
tar -xzf /var/cache/pi-vm/starship.tar.gz -C /var/cache/pi-vm starship
install -m 0755 /var/cache/pi-vm/starship /usr/local/bin/starship

# Fedora's kernel loads virtio_balloon or hv_balloon when the device is present.
# Do not force Hyper-V modules to load on KVM (they would report no device).

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-pi-vm.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
systemctl enable --now sshd

id pi >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups wheel pi
usermod --lock pi
install -d -m 0700 -o pi -g pi /home/pi/.ssh
install -m 0600 -o pi -g pi /etc/pi-vm/authorized_keys /home/pi/.ssh/authorized_keys
printf 'pi ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/90-pi-vm
chmod 0440 /etc/sudoers.d/90-pi-vm
visudo -cf /etc/sudoers.d/90-pi-vm

install -d -m 0755 /etc/skel/.config/fish /etc/skel/.config/tmux /etc/skel/.config
install -m 0644 /etc/pi-vm/vimrc /etc/skel/.vimrc
install -m 0644 /etc/pi-vm/tmux.conf /etc/skel/.config/tmux/tmux.conf
install -m 0644 /etc/pi-vm/starship.toml /etc/skel/.config/starship.toml
install -m 0644 /etc/pi-vm/config.fish /etc/skel/.config/fish/config.fish
install -D -m 0644 /etc/pi-vm/pi.fish /etc/skel/.config/fish/completions/pi.fish
for f in /etc/pi-vm/vimrc /etc/pi-vm/tmux.conf /etc/pi-vm/starship.toml /etc/pi-vm/config.fish /etc/pi-vm/pi.fish; do
  case "$f" in
    */vimrc) dest=/home/pi/.vimrc ;;
    */tmux.conf) dest=/home/pi/.config/tmux/tmux.conf ;;
    */starship.toml) dest=/home/pi/.config/starship.toml ;;
    */config.fish) dest=/home/pi/.config/fish/config.fish ;;
    */pi.fish) dest=/home/pi/.config/fish/completions/pi.fish ;;
  esac
  install -D -m 0644 "$f" "$dest"
done
chown -R pi:pi /home/pi/.config /home/pi/.vimrc

# Install Pi only in the user's private npm prefix; preserve npm/network failures.
sudo -u pi -H bash -c 'set -Eeuo pipefail; mkdir -p "$HOME/.local/share/pi-npm" "$HOME/.local/bin"; npm install --global --prefix "$HOME/.local/share/pi-npm" @earendil-works/pi-coding-agent@1.1.0; ln -sfn "$HOME/.local/share/pi-npm/bin/pi" "$HOME/.local/bin/pi"'

# Enable rootless container ranges without replacing pre-existing allocations.
if ! grep -q '^pi:' /etc/subuid; then usermod --add-subuids 100000-165535 pi; fi
if ! grep -q '^pi:' /etc/subgid; then usermod --add-subgids 100000-165535 pi; fi
loginctl enable-linger pi

# fish is changed only after dnf installs it and account/config setup succeeds.
chsh -s "$(command -v fish)" pi
install -d -m 0755 /var/lib/pi-vm
printf 'hostname=%s\n' "$VM_HOSTNAME" > /var/lib/pi-vm/bootstrap-complete

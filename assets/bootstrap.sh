#!/usr/bin/bash
set -Eeuo pipefail

state_directory=/var/lib/pi-vm
failure_marker=$state_directory/bootstrap-failed
success_marker=$state_directory/bootstrap-complete

record_failure() {
    local line=$1
    local status=$2

    trap - ERR
    install -d -m 0755 "$state_directory"
    printf 'line=%s\nstatus=%s\n' "$line" "$status" > "$failure_marker.tmp"
    mv -f "$failure_marker.tmp" "$failure_marker"
    echo "pi-vm bootstrap failed at line $line (status $status)" >&2
    exit "$status"
}

install_guest_packages() {
    local -a packages=(
        cloud-utils-growpart curl fastfetch fd-find fish gcc gcc-c++ git
        hyperv-daemons jq make micro nodejs npm podman python3 ripgrep rsync
        tmux unzip vim-enhanced
    )
    dnf -y install "${packages[@]}"
}

install_starship() {
    local cache=/var/cache/pi-vm
    local archive=$cache/starship.tar.gz

    install -d -m 0755 "$cache"
    curl --fail --location --retry 3 \
        https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz \
        -o "$archive"
    printf '%s  %s\n' \
        b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3 \
        "$archive" | sha256sum -c -
    tar -xzf "$archive" -C "$cache" starship
    install -m 0755 "$cache/starship" /usr/local/bin/starship
}

configure_ssh() {
    install -d -m 0755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/10-pi-vm.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    systemctl enable --now sshd
}

configure_pi_user() {
    id pi >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups wheel pi
    usermod --lock pi

    install -d -m 0700 -o pi -g pi /home/pi/.ssh
    install -m 0600 -o pi -g pi \
        /etc/pi-vm/authorized_keys /home/pi/.ssh/authorized_keys

    printf 'pi ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/90-pi-vm
    chmod 0440 /etc/sudoers.d/90-pi-vm
    visudo -cf /etc/sudoers.d/90-pi-vm

    install -D -m 0644 /etc/pi-vm/vimrc /home/pi/.vimrc
    install -D -m 0644 /etc/pi-vm/tmux.conf /home/pi/.config/tmux/tmux.conf
    install -D -m 0644 /etc/pi-vm/starship.toml /home/pi/.config/starship.toml
    install -D -m 0644 /etc/pi-vm/config.fish /home/pi/.config/fish/config.fish
    install -D -m 0644 /etc/pi-vm/pi.fish /home/pi/.config/fish/completions/pi.fish
    chown -R pi:pi /home/pi/.config /home/pi/.vimrc

    sudo -u pi -H bash -c '
        set -Eeuo pipefail
        mkdir -p "$HOME/.local/share/pi-npm" "$HOME/.local/bin"
        npm install --global --prefix "$HOME/.local/share/pi-npm" \
            @earendil-works/pi-coding-agent@1.1.0
        ln -sfn "$HOME/.local/share/pi-npm/bin/pi" "$HOME/.local/bin/pi"
    '

    if ! grep -q '^pi:' /etc/subuid; then
        usermod --add-subuids 100000-165535 pi
    fi
    if ! grep -q '^pi:' /etc/subgid; then
        usermod --add-subgids 100000-165535 pi
    fi
    loginctl enable-linger pi
    chsh -s "$(command -v fish)" pi
}

install_default_configs() {
    install -D -m 0644 /etc/pi-vm/vimrc /etc/skel/.vimrc
    install -D -m 0644 /etc/pi-vm/tmux.conf /etc/skel/.config/tmux/tmux.conf
    install -D -m 0644 /etc/pi-vm/starship.toml /etc/skel/.config/starship.toml
    install -D -m 0644 /etc/pi-vm/config.fish /etc/skel/.config/fish/config.fish
    install -D -m 0644 /etc/pi-vm/pi.fish /etc/skel/.config/fish/completions/pi.fish
}

trap 'record_failure "$LINENO" "$?"' ERR
install -d -m 0755 "$state_directory"
rm -f -- "$failure_marker" "$failure_marker.tmp" "$success_marker"

hostnamectl set-hostname "$VM_HOSTNAME"
install_guest_packages
install_starship
configure_ssh
install_default_configs
configure_pi_user

printf 'hostname=%s\n' "$VM_HOSTNAME" > "$success_marker"
rm -f -- "$failure_marker"

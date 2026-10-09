#!/usr/bin/bash
set -Eeuo pipefail

state_directory=/var/lib/pi-vm
failure_marker=$state_directory/bootstrap-failed
success_marker=$state_directory/bootstrap-complete
recovered_from_failure=false

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
        avahi cloud-utils-growpart curl fastfetch fd-find firewalld fish gcc
        gcc-c++ git hyperv-daemons jq make micro nodejs npm podman python3
        ripgrep rsync samba samba-client tmux unzip vim-enhanced wsdd
    )
    dnf -y install "${packages[@]}"
}

remove_azure_guest_tools() {
    local -a installed=()
    local package
    for package in azure-vm-utils WALinuxAgent WALinuxAgent-udev; do
        if rpm -q "$package" >/dev/null 2>&1; then
            installed+=("$package")
        fi
    done
    if (( ${#installed[@]} )); then
        systemctl disable --now waagent.service 2>/dev/null || true
        dnf -y remove "${installed[@]}"
    fi
    rm -rf -- /etc/waagent.conf /var/lib/waagent /var/log/waagent.log
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
    if [[ ! -f /home/pi/.ssh/pi-vm-deploy ]]; then
        sudo -u pi ssh-keygen -q -t ed25519 -N '' \
            -C "pi-vm-deploy@$VM_HOSTNAME" \
            -f /home/pi/.ssh/pi-vm-deploy
    fi

    printf 'pi ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/90-pi-vm
    chmod 0440 /etc/sudoers.d/90-pi-vm
    visudo -cf /etc/sudoers.d/90-pi-vm

    install -D -m 0644 /etc/pi-vm/vimrc /home/pi/.vimrc
    install -D -m 0644 /etc/pi-vm/tmux.conf /home/pi/.config/tmux/tmux.conf
    install -D -m 0644 /etc/pi-vm/starship.toml /home/pi/.config/starship.toml
    install -D -m 0644 /etc/pi-vm/config.fish /home/pi/.config/fish/config.fish
    install -D -m 0644 /etc/pi-vm/pi.fish /home/pi/.config/fish/completions/pi.fish
    chown -R pi:pi /home/pi/.config /home/pi/.vimrc

    install -D -m 0600 -o pi -g pi \
        /etc/pi-vm/pi-settings.json /home/pi/.pi/agent/settings.json
    install -D -m 0644 -o pi -g pi \
        /etc/pi-vm/AGENTS.md /home/pi/.pi/agent/AGENTS.md
    install -D -m 0644 -o pi -g pi \
        /etc/pi-vm/kodfodrasz/SKILL.md \
        /home/pi/.pi/agent/skills/kodfodrasz/SKILL.md
    chown -R pi:pi /home/pi/.pi

    sudo -u pi -H bash -c '
        set -Eeuo pipefail
        mkdir -p "$HOME/.local/share/pi-npm" "$HOME/.local/bin"
        npm install --global --prefix "$HOME/.local/share/pi-npm" \
            @earendil-works/pi-coding-agent@1.1.0
        ln -sfn "$HOME/.local/share/pi-npm/bin/pi" "$HOME/.local/bin/pi"
        "$HOME/.local/bin/pi" install npm:pi-web-access@0.37.0
        "$HOME/.local/bin/pi" install npm:pi-subagents@0.76.1
        "$HOME/.local/bin/pi" install npm:pi-reset-usage-limit@0.1.1
        "$HOME/.local/bin/pi" install npm:@wayner6/pi-usage@0.3.0
        "$HOME/.local/bin/pi" install npm:pi-keep-going@1.1.0
    '

    if ! grep -q '^pi:' /etc/subuid; then
        usermod --add-subuids 100000-165535 pi
    fi
    if ! grep -q '^pi:' /etc/subgid; then
        usermod --add-subgids 100000-165535 pi
    fi
    loginctl enable-linger pi
    local fish_shell
    fish_shell=$(grep -E '/fish$' /etc/shells | head -1 || true)
    if [[ -z $fish_shell ]]; then
        echo 'fish is not registered in /etc/shells' >&2
        return 1
    fi
    chsh -s "$fish_shell" pi
}

install_default_configs() {
    install -D -m 0644 /etc/pi-vm/vimrc /etc/skel/.vimrc
    install -D -m 0644 /etc/pi-vm/tmux.conf /etc/skel/.config/tmux/tmux.conf
    install -D -m 0644 /etc/pi-vm/starship.toml /etc/skel/.config/starship.toml
    install -D -m 0644 /etc/pi-vm/config.fish /etc/skel/.config/fish/config.fish
    install -D -m 0644 /etc/pi-vm/pi.fish /etc/skel/.config/fish/completions/pi.fish
}

configure_file_sharing() {
    install -m 0644 /etc/pi-vm/smb.conf /etc/samba/smb.conf
    install -m 0644 /etc/pi-vm/avahi-samba.service \
        /etc/avahi/services/samba.service
    testparm -s >/dev/null
    setsebool -P samba_enable_home_dirs on

    # The labels live beside the addresses in this small, editable config.
    source /etc/pi-vm/firewall-sources.conf
    systemctl enable --now firewalld
    firewall-cmd --set-default-zone=public
    firewall-cmd --permanent --zone=public --add-service=ssh
    firewall-cmd --permanent --zone=public --add-service=mdns
    firewall-cmd --permanent --zone=public --add-service=wsdd
    firewall-cmd --permanent --zone=public --add-service=wsdd-http
    firewall-cmd --permanent --zone=trusted --add-source="$HOME_LAN_CIDR"
    firewall-cmd --permanent --zone=trusted --add-source="$VPN_CIDR"
    firewall-cmd --reload

    local password_file=$state_directory/samba-initial-password
    if ! pdbedit -L -u pi >/dev/null 2>&1; then
        if [[ ! -s $password_file ]]; then
            local temporary_password
            temporary_password=$(mktemp "$state_directory/.samba-password.XXXXXX")
            chmod 0600 "$temporary_password"
            (umask 077; python3 -c \
                'import secrets; print(secrets.token_urlsafe(18))' \
                > "$temporary_password")
            mv -f -- "$temporary_password" "$password_file"
        fi
        local password
        password=$(<"$password_file")
        printf '%s\n%s\n' "$password" "$password" | smbpasswd -a -s pi
    fi

    systemctl enable --now smb nmb wsdd avahi-daemon
    if [[ -s $password_file ]]; then
        echo 'Samba initial login:'
        echo '  user: pi'
        printf '  password: %s\n' "$(<"$password_file")"
        echo 'Change it with: sudo smbpasswd pi'
        echo 'Then remove the saved initial value:'
        echo '  sudo rm -f /var/lib/pi-vm/samba-initial-password'
    fi
}

print_deploy_key_instructions() {
    echo 'Private-repository deploy public key:'
    cat /home/pi/.ssh/pi-vm-deploy.pub
    echo 'After authorizing it, clone with:'
    echo "  GIT_SSH_COMMAND='ssh -i ~/.ssh/pi-vm-deploy -o IdentitiesOnly=yes' git clone REPOSITORY"
}

run_local_payload() {
    if [[ -x /etc/pi-vm/local/bootstrap.sh ]]; then
        PI_VM_LOCAL_DIR=/etc/pi-vm/local /etc/pi-vm/local/bootstrap.sh
    fi
}

trap 'record_failure "$LINENO" "$?"' ERR
install -d -m 0755 "$state_directory"
if [[ -f $failure_marker ]] \
        || { [[ -f $success_marker ]] \
            && grep -qx 'recovered_from_failure=true' "$success_marker"; }; then
    recovered_from_failure=true
fi
rm -f -- "$failure_marker" "$failure_marker.tmp" "$success_marker"

hostnamectl set-hostname "$VM_HOSTNAME"
install_guest_packages
remove_azure_guest_tools
install_starship
configure_ssh
install_default_configs
configure_pi_user
configure_file_sharing
print_deploy_key_instructions
run_local_payload

{
    printf 'hostname=%s\n' "$VM_HOSTNAME"
    printf 'recovered_from_failure=%s\n' "$recovered_from_failure"
} > "$success_marker"
rm -f -- "$failure_marker"

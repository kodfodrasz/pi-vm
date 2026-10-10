#!/usr/bin/bash
set -Eeuo pipefail
# Never replace an existing README, including a previously generated one.
[[ ! -e $PI_HOME/README.md && ! -L $PI_HOME/README.md ]] || exit 0
temporary=$(mktemp "$PI_HOME/.readme.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
cat > "$temporary" <<EOF
# Welcome to $VM_HOSTNAME

Sign in as $PI_USER. This Fedora workspace has Pi, rootless Podman, and Samba.
Read ~/README.md for setup and recovery instructions.
Samba's initial password is saved in ~/samba-initial-password; change it with:
  sudo smbpasswd $PI_USER
Dismiss this welcome message with: touch ~/.readme-dismissed

<!-- END_OF_WALL_MESSAGE -->

## Pi and development

Run pi to sign in to your provider. The current managed release lives under
~/.pi/agent/install and ~/.local/bin is on PATH. Update it with pi update.
Fedora supplies Node.js and npm. Rootless containers use podman.

## File sharing

Connect to //$VM_HOSTNAME/$PI_USER as $PI_USER. LAN 10.0.0.0/8 and VPN
192.168.100.0/24 are trusted; public networks allow key-only SSH and discovery.
Read the private initial password with: cat ~/samba-initial-password
Change it with: sudo smbpasswd $PI_USER
Then remove the saved initial value with: rm -f ~/samba-initial-password
An existing Samba account is never reset by bootstrap.

## Private repositories

Authorize the public deploy key from ~/.ssh/pi-vm-deploy.pub, then clone with:
  GIT_SSH_COMMAND='ssh -i ~/.ssh/pi-vm-deploy -o IdentitiesOnly=yes' git clone REPOSITORY
Never share the private key in ~/.ssh/pi-vm-deploy.

## Provisioning and recovery

Check: sudo cat /var/lib/pi-vm/bootstrap-failed
Retry: sudo /usr/local/sbin/pi-vm-bootstrap
Logs: sudo less /var/lib/pi-vm/bootstrap.log
SELinux is intentionally disabled; the first successful setup reboots if needed.
This README is generated only when absent. Edit it freely; reruns preserve it.
Bash and fish show only text before the END_OF_WALL_MESSAGE HTML comment on
interactive login. Remove ~/.readme-dismissed to restore the welcome message.
EOF
chmod 0644 "$temporary"
chown "$PI_USER:$PI_GROUP" "$temporary"
mv -n -- "$temporary" "$PI_HOME/README.md"

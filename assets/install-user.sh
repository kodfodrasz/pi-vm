#!/bin/sh
set -eu
# The caller supplies HOME, cwd and PATH without starting a login shell.
if [ ! -e "$HOME/.ssh/pi-vm-deploy" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "pi-vm-deploy@$VM_HOSTNAME" -f "$HOME/.ssh/pi-vm-deploy"
fi
installer=$(mktemp "$HOME/.pi/agent/.installer.XXXXXX")
trap 'rm -f -- "$installer"' EXIT HUP INT TERM
curl --fail --location --retry 3 https://pi.dev/install.sh -o "$installer"
# The installer opens /dev/tty even with redirected stdin. Fedora setsid
# removes the controlling terminal on first boot AND interactive retries.
unset PI_LEGACY_INSTALL PI_MANAGED_INSTALL_ROOT
export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
setsid --fork --wait sh "$installer" </dev/null
pi install npm:pi-web-access@0.37.0
pi install npm:pi-subagents@0.76.1
pi install npm:pi-reset-usage-limit@0.1.1
pi install npm:@wayner6/pi-usage@0.3.0
pi install npm:pi-keep-going@1.1.0

#!/usr/bin/bash
# Cloud-init owns account creation. Use its actual home and primary group.
PI_USER=${PI_USER:-pi}
if [[ ! $PI_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [[ $PI_USER == root ]]; then
    echo 'invalid PI_USER (expected a non-root Linux username)' >&2
    exit 1
fi
if ! id "$PI_USER" >/dev/null 2>&1; then
    printf 'Cloud-init must create account %s before bootstrap; account is absent.\n' "$PI_USER" >&2
    exit 1
fi
PI_HOME=$(getent passwd "$PI_USER" | cut -d: -f6)
PI_GROUP=$(id -gn "$PI_USER")
[[ $PI_HOME == /* && $PI_HOME != / && -d $PI_HOME && -n $PI_GROUP ]] || {
    echo 'configured account needs an existing absolute home and primary group' >&2
    exit 1
}
export PI_USER PI_HOME PI_GROUP

as_user() {
    # No login shell: provisioning must not source profiles or greetings.
    # The script is constant; variable values and commands travel as argv/env.
    # Expressions below are interpreted by the user's explicit sh.
    # shellcheck disable=SC2016
    su -s /bin/sh "$PI_USER" -c 'export HOME="$1"; shift; cd "$HOME" || exit; export PATH="$HOME/.local/bin:$PATH"; exec "$@"' sh "$PI_HOME" "$@"
}

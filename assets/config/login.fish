fish_add_path "$HOME/.local/bin"
if status is-interactive; and status is-login; and test -t 0; and test -t 1; and not set -q SSH_ORIGINAL_COMMAND
    "$HOME/.local/bin/pi-vm-readme"
end

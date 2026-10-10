export PATH="$HOME/.local/bin:$PATH"
if [[ $- == *i* ]] && shopt -q login_shell && [[ -t 0 && -t 1 ]] && [[ -z ${SSH_ORIGINAL_COMMAND:-} ]]; then
    "$HOME/.local/bin/pi-vm-readme"
fi

# Common Pi completions; use pi --help for the current managed release.
# This small set does not depend on a global npm path or provider credentials.
complete -c pi -n '__fish_use_subcommand' -a 'install remove uninstall update list config auth mcp' -f
complete -c pi -s h -l help -d 'Show help'
complete -c pi -s v -l version -d 'Show version'
complete -c pi -s p -l print -d 'Process prompt and exit'
complete -c pi -s c -l continue -d 'Continue the last session'
complete -c pi -s r -l resume -d 'Choose a session'
complete -c pi -l provider -r -f -d 'Model provider'
complete -c pi -l model -r -f -d 'Model pattern or ID'
complete -c pi -l thinking -r -f -a 'off minimal low medium high xhigh max'
complete -c pi -l mode -r -f -a 'text json rpc'
complete -c pi -l tui-mode -r -f -a 'fullscreen regular'
complete -c pi -l api-key -r -f
complete -c pi -l system-prompt -r
complete -c pi -l append-system-prompt -r
complete -c pi -l session -r
complete -c pi -l session-id -r -f
complete -c pi -l session-dir -r -a '(__fish_complete_directories)'
complete -c pi -l fork -r
complete -c pi -s n -l name -r -f
complete -c pi -l models -r -f
complete -c pi -s t -l tools -r -f
complete -c pi -l exclude-tools -r -f
complete -c pi -s e -l extension -r
complete -c pi -l skill -r
complete -c pi -l prompt-template -r
complete -c pi -l theme -r
complete -c pi -l use-theme -r -f
complete -c pi -l export -r
for flag in no-session no-tools no-builtin-tools no-extensions no-mcp no-skills no-prompt-templates no-themes no-context-files verbose approve no-approve offline
    complete -c pi -l $flag
end
complete -c pi -n '__fish_seen_subcommand_from install remove uninstall config' -s l -l local
complete -c pi -n '__fish_seen_subcommand_from update' -a 'self pi'
complete -c pi -n '__fish_seen_subcommand_from auth' -f -a 'print-api-key print-bearer-token check'

fish_add_path "$HOME/.local/bin"

if status is-interactive
    # Commands to run in interactive sessions can go here
    set -gx EDITOR /usr/bin/micro

    # Starship shell prompt
    if command -q starship
        starship init fish | source
    end
end

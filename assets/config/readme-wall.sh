#!/bin/sh
[ ! -e "$HOME/.readme-dismissed" ] || exit 0
[ -r "$HOME/README.md" ] || exit 0
# A user README without the explicit boundary must never become a greeting.
awk '
    /^<!-- END_OF_WALL_MESSAGE -->$/ { printf "%s", intro; exit }
    { intro = intro $0 "\n" }
' "$HOME/README.md"

#!/bin/sh
[ ! -e "$HOME/.readme-dismissed" ] || exit 0
[ -r "$HOME/README.md" ] || exit 0
# A user README without the explicit boundary must never become a greeting.
grep -qx '<!-- END_OF_WALL_MESSAGE -->' "$HOME/README.md" || exit 0
awk '/^<!-- END_OF_WALL_MESSAGE -->$/ { exit } { print }' "$HOME/README.md"

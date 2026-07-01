#!/usr/bin/env bash
# Prints the BetterCallChatGPT 3-line colored header to stdout via printf.
# IMPORTANT: we use printf (not `cat`), because Claude Code renders `cat <file>`
# as a collapsed "Read 1 file (ctrl+o to expand)" block — printf stdout shows inline.
y=$'\033[38;5;220m'         # yellow (BETTER CALL)
Y=$'\033[1;38;5;220m'       # bold yellow
G=$'\033[1;38;2;16;163;127m' # bold OpenAI green (#10A37F) for ChatGPT
d=$'\033[38;5;245m'         # dim grey
Z=$'\033[0m'
sub="second opinion from Codex (ChatGPT) · press Ctrl+O to see the full banner"
printf '%s' "$y"; printf '─%.0s' {1..63}; printf '%s\n' "$Z"
printf '  %s⚖%s  %sIt'\''s Better Call%s %sChatGPT!%s  %s⚖%s\n' "$y" "$Z" "$Y" "$Z" "$G" "$Z" "$y" "$Z"
printf '  %s%s%s\n' "$d" "$sub" "$Z"

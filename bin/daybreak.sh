#!/bin/bash
# daybreak.sh: one-shot OpenAI Responses API call under the Daybreak Blue cyber
# access program (defensive cybersecurity calibration), used by agents/openai.md.
#
#   daybreak.sh [-m MODEL] [-e EFFORT] [-w] [-r PROGRAM] [-o OUT] < briefing.txt
#
#   -m  model (default gpt-6-sol)          -e  reasoning effort (default high)
#   -w  enable the web_search tool          -o  write the reply text to OUT
#   -r  cyber access program (default daybreak_blue; daybreak_red only when asked)
#
# The briefing is read from stdin. Reply text goes to stdout (or -o), and run
# metadata (model, status, tokens) goes to stderr.
#
# Key: a macOS Keychain generic password (service OPENAI_DAYBREAK_API_KEY,
# account $USER; override the service name with DAYBREAK_KEYCHAIN_ITEM). Store
# it once with:  security add-generic-password -U -a "$USER" -s OPENAI_DAYBREAK_API_KEY -w
# (no value after -w, so it prompts and the key never lands in shell history).
# It is fetched per run and handed to curl on stdin, so it is never exported,
# never in argv, and never printed.
#
# Optional: DAYBREAK_ORG / DAYBREAK_PROJECT add the OpenAI-Organization and
# OpenAI-Project headers. They are not secret, but keep them out of public
# copies; a service-account key is already bound to its project.
set -euo pipefail

ORG="${DAYBREAK_ORG:-}"
PROJECT="${DAYBREAK_PROJECT:-}"
KEY_ITEM="${DAYBREAK_KEYCHAIN_ITEM:-OPENAI_DAYBREAK_API_KEY}"
MODEL="gpt-6-sol"; EFFORT="high"; WEB=0; PROGRAM="daybreak_blue"; OUT=""

while getopts "m:e:wr:o:h" opt; do
  case $opt in
    m) MODEL=$OPTARG ;; e) EFFORT=$OPTARG ;; w) WEB=1 ;;
    r) PROGRAM=$OPTARG ;;
    o) OUT=$OPTARG ;;
    *) sed -n '2,23p' "$0" >&2; exit 2 ;;
  esac
done

[ -t 0 ] && { echo "daybreak.sh: pipe the briefing on stdin" >&2; exit 2; }
PROMPT=$(cat)
[ -n "$PROMPT" ] || { echo "daybreak.sh: empty briefing" >&2; exit 2; }

KEY=$(security find-generic-password -a "$USER" -s "$KEY_ITEM" -w 2>/dev/null) \
  || { echo "daybreak.sh: Keychain item $KEY_ITEM not found" >&2; exit 3; }

BODY=$(jq -n --arg m "$MODEL" --arg e "$EFFORT" --arg p "$PROGRAM" --arg in "$PROMPT" --argjson web "$WEB" '
  {model: $m, input: $in, store: false,
   reasoning: {effort: $e},
   access_programs: {cyber: $p}}
  + (if $web == 1 then {tools: [{type: "web_search"}]} else {} end)')

TMP=$(mktemp "${TMPDIR:-/tmp}/daybreak.XXXXXX"); REQ=$(mktemp "${TMPDIR:-/tmp}/daybreak-req.XXXXXX")
trap 'command rm -f "$TMP" "$REQ"' EXIT
printf '%s' "$BODY" > "$REQ"
HDRS=(-H "Content-Type: application/json")
[ -n "$ORG" ] && HDRS+=(-H "OpenAI-Organization: $ORG")
[ -n "$PROJECT" ] && HDRS+=(-H "OpenAI-Project: $PROJECT")
CODE=$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -sS -K - \
  --max-time 900 -o "$TMP" -w '%{http_code}' https://api.openai.com/v1/responses \
  "${HDRS[@]}" --data-binary @"$REQ" 2>&1) || true
unset KEY

if [ "$CODE" != "200" ]; then
  echo "daybreak.sh: HTTP $CODE: $(jq -r '.error.message // .' "$TMP" 2>/dev/null | head -c 500)" >&2
  exit 1
fi

TEXT=$(jq -r '[.output[]? | select(.type=="message") | .content[]? | select(.type=="output_text") | .text] | join("\n")' "$TMP")
jq -r '"daybreak.sh: model=\(.model) program='"$PROGRAM"' status=\(.status) tokens in=\(.usage.input_tokens) out=\(.usage.output_tokens) reasoning=\(.usage.output_tokens_details.reasoning_tokens // 0)"' "$TMP" >&2
[ -n "$TEXT" ] || { echo "daybreak.sh: empty reply (status $(jq -r .status "$TMP"))" >&2; exit 1; }
if [ -n "$OUT" ]; then printf '%s\n' "$TEXT" > "$OUT"; else printf '%s\n' "$TEXT"; fi

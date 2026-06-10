#!/usr/bin/env bash
# v0_bash_agent_mini.sh - Mini Claude Code (Pure Bash, Compact). aws-cli + jq only.
set -euo pipefail
M="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-20250514-v1:0}" R="${AWS_REGION:-us-east-1}" S="$(cd "$(dirname "$0")";pwd)/$(basename "$0")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; echo '[]' > "$W/m"
jq -n --arg s "CLI agent at $(pwd). Use bash. Subagent: bash $S 'task'. Be concise." '[{"text":$s}]' > "$W/s"
jq -n --arg d "Shell. Read:cat/grep/find. Write:echo>/sed. Subagent: bash $S 'task'" \
  '{"tools":[{"toolSpec":{"name":"bash","description":$d,"inputSchema":{"json":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}}]}' > "$W/t"
jqm() { jq "$@" "$W/m" > "$W/_" && mv "$W/_" "$W/m"; }
ask() { aws bedrock-runtime converse --model-id "$M" --region "$R" --messages "file://$W/m" --system "file://$W/s" --tool-config "file://$W/t" --inference-config '{"maxTokens":8000}' 2>&1; }

chat() {
  jqm --arg p "$1" '. + [{"role":"user","content":[{"text":$p}]}]'
  while local r; r=$(ask); do
    jqm --argjson c "$(echo "$r" | jq '.output.message.content')" '. + [{"role":"assistant","content":$c}]'
    [[ "$(echo "$r" | jq -r .stopReason)" != tool_use ]] && { echo "$r" | jq -r '.output.message.content[]|select(.text)|.text'; return; }
    local res='[]'
    while IFS= read -r t; do
      local i=$(echo "$t"|jq -r .toolUseId) c=$(echo "$t"|jq -r .input.command) o
      printf '\033[33m$ %s\033[0m\n' "$c" >&2; o=$(timeout 300 bash -c "$c" 2>&1|head -c 50000)||true; echo "${o:-(empty)}" >&2
      res=$(echo "$res"|jq --arg i "$i" --arg o "$o" '.+[{"toolResult":{"toolUseId":$i,"content":[{"text":$o}]}}]')
    done < <(echo "$r"|jq -c '.output.message.content[]|select(.toolUse)|.toolUse')
    jqm --argjson r "$res" '.+[{"role":"user","content":$r}]'
  done
}

[[ $# -gt 0 ]] && { chat "$*"; exit; }
while printf '\033[36m>> \033[0m' && read -r q && [[ -n "$q" && "$q" != q ]]; do chat "$q"; done

#!/usr/bin/env bash
#
# v0_bash_agent.sh - Mini Claude Code: Bash is All You Need (Pure Bash Edition)
#
# The Python version proved: ONE tool (bash) + ONE loop = FULL agent.
# This goes further: the agent itself IS bash. Zero Python. Zero pip.
# Only needs: aws CLI + jq.
#
# Uses AWS Bedrock `converse` API (native tool_use support).
# jq handles all JSON. History lives in a temp file passed via file://.
#
# Subagent: bash v0_bash_agent.sh "task"
#   → new process = new tmpdir = isolated history
#   → returns summary via stdout
#
# Usage:
#   bash v0_bash_agent.sh                        # Interactive
#   bash v0_bash_agent.sh "explore and summarize" # One-shot / subagent
#
# Config: BEDROCK_MODEL, AWS_REGION (env vars)
#
set -euo pipefail

MODEL="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-20250514-v1:0}"
REGION="${AWS_REGION:-us-east-1}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; echo '[]' > "$W/msg.json"

# System prompt
jq -n --arg s "You are a CLI agent at $(pwd). Solve problems using bash commands.

Rules:
- Prefer tools over prose. Act first, explain briefly after.
- Read files: cat, grep, find, rg, ls, head, tail
- Write files: echo '...' > file, sed -i, or cat << 'EOF' > file
- Subagent: For complex subtasks, spawn a subagent to keep context clean:
  bash $SELF \"explore src/ and summarize the architecture\"

When to use subagent:
- Task requires reading many files (isolate the exploration)
- Task is independent and self-contained
- You want to avoid polluting current conversation with intermediate details

The subagent runs in isolation and returns only its final summary." \
  '[{"text": $s}]' > "$W/sys.json"

# The ONE tool — description teaches the model patterns + subagent spawning
jq -n --arg d "Execute shell command. Common patterns:
- Read: cat/head/tail, grep/find/rg/ls, wc -l
- Write: echo 'content' > file, sed -i 's/old/new/g' file
- Subagent: bash $SELF 'task description' (spawns isolated agent, returns summary)" \
  '{"tools":[{"toolSpec":{"name":"bash","description":$d,
    "inputSchema":{"json":{"type":"object",
      "properties":{"command":{"type":"string","description":"Shell command to execute"}},
      "required":["command"]}}}}]}' > "$W/tool.json"

# Helpers: eliminate repeated boilerplate
# jqm: jq-mutate messages file in place
jqm() { jq "$@" "$W/msg.json" > "$W/msg.tmp" && mv "$W/msg.tmp" "$W/msg.json"; }
# ask: call Bedrock converse with all static flags baked in
ask() { aws bedrock-runtime converse --model-id "$MODEL" --region "$REGION" \
  --messages "file://$W/msg.json" --system "file://$W/sys.json" \
  --tool-config "file://$W/tool.json" --inference-config '{"maxTokens":8000}' 2>&1; }

# ── The agent loop (same pattern as Python version) ─────────────────────────
#   while True:
#       response = model(messages, tools)
#       if stop_reason != "tool_use": return text
#       execute tools, append results, continue
#
chat() {
  jqm --arg p "$1" '. + [{"role":"user","content":[{"text":$p}]}]'

  while true; do
    local resp; resp=$(ask)
    jqm --argjson c "$(echo "$resp" | jq '.output.message.content')" \
      '. + [{"role":"assistant","content":$c}]'

    # Done? Print final text.
    if [[ "$(echo "$resp" | jq -r '.stopReason')" != "tool_use" ]]; then
      echo "$resp" | jq -r '.output.message.content[] | select(.text) | .text'
      return
    fi

    # Execute each tool call, collect results
    local results='[]'
    while IFS= read -r tool; do
      local tid cmd out
      tid=$(echo "$tool" | jq -r '.toolUseId')
      cmd=$(echo "$tool" | jq -r '.input.command')
      echo -e "\033[33m$ ${cmd}\033[0m" >&2
      out=$(timeout 300 bash -c "$cmd" 2>&1 | head -c 50000) || true
      echo "${out:-(empty)}" >&2
      results=$(echo "$results" | jq --arg id "$tid" --arg out "$out" \
        '. + [{"toolResult":{"toolUseId":$id,"content":[{"text":$out}]}}]')
    done < <(echo "$resp" | jq -c '.output.message.content[] | select(.toolUse) | .toolUse')

    jqm --argjson r "$results" '. + [{"role":"user","content":$r}]'
  done
}

if [[ $# -gt 0 ]]; then
  chat "$*"
else
  while true; do
    echo -ne "\033[36mMini Claude Code v0 (bash) >> \033[0m"
    read -r query || break
    [[ -z "$query" || "$query" == "q" || "$query" == "exit" ]] && break
    chat "$query"
  done
fi

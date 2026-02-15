# Testing v0 Bash Agent — Hands-On Guide

How to manually verify `v0_bash_agent.sh` and `v0_bash_agent_mini.sh` work correctly.

## Prerequisites

```bash
# 1. AWS CLI (v2)
aws --version        # expect: aws-cli/2.x.x

# 2. jq
jq --version         # expect: jq-1.x

# 3. AWS credentials configured with Bedrock access
aws configure list   # should show access_key, secret_key, region
```

If your AWS SSO session is expired:

```bash
aws sso login --profile YOUR_PROFILE
```

## Test 0: Verify Bedrock Access

Before running the agent, confirm you can talk to Bedrock at all.

```bash
aws bedrock-runtime converse \
  --model-id us.anthropic.claude-sonnet-4-20250514-v1:0 \
  --messages '[{"role":"user","content":[{"text":"Say hi in 5 words"}]}]' \
  --inference-config '{"maxTokens":100}' \
  --region us-east-1
```

Expected: a JSON response with `"stopReason": "end_turn"` and some text in `output.message.content`.

If this fails, nothing else will work. Debug your AWS credentials / Bedrock model access first.

## Test 1: Single Task (Subagent Mode)

The simplest test. Pass a prompt as argument — the agent runs, prints results, exits.

```bash
bash v0_bash_agent.sh "list all .sh files in the current directory and tell me how many there are"
```

**What to look for:**

- Yellow `$` lines (tool calls being executed)
- The agent calls something like `ls *.sh` or `find . -name "*.sh"`
- Final answer includes the file list and count
- Process exits cleanly

Example output:

```
$ ls -la *.sh                        ← agent chose this command
-rwxr-xr-x  v0_bash_agent_mini.sh
-rwxr-xr-x  v0_bash_agent.sh
$ ls *.sh | wc -l                    ← second tool call
       2
There are 2 .sh files: ...           ← final text response
```

## Test 2: Multi-Step Reasoning

Give a task that requires multiple tool calls in sequence.

```bash
bash v0_bash_agent.sh "count how many python files exist here and show the smallest one"
```

**What to look for:**

- Agent makes 2-3 tool calls (find → sort → cat)
- Each tool result feeds into the next decision
- Final answer synthesizes all findings

## Test 3: Subagent (Recursive Call) ⭐

This is the key feature — the agent spawning a child copy of itself.

```bash
bash v0_bash_agent.sh "Use a subagent to find out what v0_bash_agent_mini.py does. Run: bash v0_bash_agent.sh 'read v0_bash_agent_mini.py and summarize in 2 sentences'. Then tell me the line count of v0_bash_agent.sh"
```

**What to look for:**

- A `$ bash v0_bash_agent.sh '...'` line appears — the parent spawning the child
- Indented tool calls from the child (e.g., `$ cat v0_bash_agent_mini.py`)
- Child's summary text returned to parent as tool output
- Parent continues with its own task (`$ wc -l v0_bash_agent.sh`)
- Final answer combines both results

**The call tree looks like:**

```
Parent Agent
 ├─ tool: bash v0_bash_agent.sh "read ... and summarize"
 │    └─ Child Agent (isolated process, fresh history)
 │         ├─ tool: cat v0_bash_agent_mini.py
 │         └─ returns: "This is a compact Python CLI agent..."
 ├─ tool: wc -l v0_bash_agent.sh
 └─ final: "The mini.py file does X. The .sh file has Y lines."
```

## Test 4: Mini Version

Repeat any test above with the compact version to confirm identical behavior:

```bash
# Single task
bash v0_bash_agent_mini.sh "what is the biggest file in this directory?"

# Subagent
bash v0_bash_agent_mini.sh "spawn a subagent (bash v0_bash_agent_mini.sh 'list all .md files') and report what it found"
```

## Test 5: Interactive REPL

Run without arguments to enter interactive mode:

```bash
bash v0_bash_agent.sh
```

```
Mini Claude Code v0 (bash) >> what python files are here?
$ find . -name "*.py" -maxdepth 1
./v0_bash_agent.py
./v1_basic_agent.py
...
There are 10 Python files in the current directory: ...

Mini Claude Code v0 (bash) >> which one is the largest?    ← context preserved
$ ls -lS *.py | head -1
...

Mini Claude Code v0 (bash) >> q                            ← type q or exit to quit
```

**What to look for:**

- Second question benefits from prior context (knows we were talking about python files)
- History accumulates across turns
- `q` or `exit` or empty input exits cleanly

## Test 6: Custom Model

Override the model via environment variable:

```bash
BEDROCK_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0 bash v0_bash_agent.sh "say hello"
```

## What Can Go Wrong

| Symptom                 | Cause                               | Fix                                           |
| ----------------------- | ----------------------------------- | --------------------------------------------- |
| `ExpiredTokenException` | AWS SSO session expired             | `aws sso login --profile YOUR_PROFILE`        |
| `AccessDeniedException` | No Bedrock permissions              | Check IAM policy allows `bedrock:InvokeModel` |
| `jq: command not found` | jq not installed                    | `brew install jq` / `apt install jq`          |
| `Unknown model`         | Model ID not available in region    | Check `aws bedrock list-foundation-models`    |
| Agent hangs             | Model generating very long response | Wait, or Ctrl-C and retry with simpler prompt |

## Python vs Bash — Side by Side

Both versions implement the same agent loop. Test them back to back:

```bash
# Python version (needs: pip install anthropic python-dotenv)
python v0_bash_agent.py "list .sh files"

# Bash version (needs: aws-cli + jq, zero pip)
bash v0_bash_agent.sh "list .sh files"
```

The outputs will differ in wording (different API calls, different model behavior) but the capability is identical: tool calling loop + subagent recursion.

#!/usr/bin/env bash
set -euo pipefail

sleep 0.1
printf '%s\n' '{"type":"thread.started","thread_id":"thr_exec_fake"}'
printf '%s\n' '{"type":"turn.started","turn_id":"turn_exec_fake"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"item_exec_fake","type":"agent_message","text":"Structured result"}}'
printf '%s\n' '{"type":"turn.completed","turn_id":"turn_exec_fake","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":4}}'
sleep 0.2

#!/bin/sh

while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"id":1,"result":{"codexHome":"/tmp/fake-codex-home","platformFamily":"unix","platformOs":"linux","userAgent":"fake-codex/1.0"}}'
      ;;
    *'"method":"initialized"'*)
      ;;
    *'"method":"thread/start"'*)
      case "$line" in
        *'"approvalPolicy":"on-request"'*) ;;
        *)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"missing safe thread defaults"}}'
          continue
          ;;
      esac
      case "$line" in
        *'"sandbox":"workspace-write"'*) ;;
        *)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"missing safe thread defaults"}}'
          continue
          ;;
      esac
      case "$line" in
        *'CASEIN_API_TOKEN'*) ;;
        *)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"missing safe thread defaults"}}'
          continue
          ;;
      esac
      case "$line" in
        *'"set":{"CASEIN_API_TOKEN"'*)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"sensitive token leaked to shell overrides"}}'
          continue
          ;;
        *) ;;
      esac
      printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_fake","sessionId":"sess_fake","parentThreadId":null,"status":{"type":"idle"},"cwd":"/workspace","ephemeral":true,"preview":"","modelProvider":"openai","cliVersion":"0.144.4","source":"appServer","createdAt":1784155200,"updatedAt":1784155200,"turns":[]}}}'
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"thr_fake","sessionId":"sess_fake","parentThreadId":null,"status":{"type":"idle"},"cwd":"/workspace","ephemeral":true,"preview":"","modelProvider":"openai","cliVersion":"0.144.4","source":"appServer","createdAt":1784155200,"updatedAt":1784155200,"turns":[]}}}'
      ;;
    *'"method":"thread/resume"'*)
      case "$line" in
        *'"approvalPolicy":"on-request"'*) ;;
        *)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"missing safe thread defaults"}}'
          continue
          ;;
      esac
      case "$line" in
        *'"sandbox":"workspace-write"'*) ;;
        *)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"missing safe thread defaults"}}'
          continue
          ;;
      esac
      case "$line" in
        *'CASEIN_API_TOKEN'*) ;;
        *)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"missing safe thread defaults"}}'
          continue
          ;;
      esac
      case "$line" in
        *'"set":{"CASEIN_API_TOKEN"'*)
          printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"sensitive token leaked to shell overrides"}}'
          continue
          ;;
        *) ;;
      esac
      printf '%s\n' '{"id":2,"result":{"approvalPolicy":"on-request","approvalsReviewer":"user","cwd":"/workspace","model":"gpt-5","modelProvider":"openai","sandbox":{"type":"workspaceWrite","writableRoots":[],"readOnlyAccess":{"type":"fullAccess"},"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false},"thread":{"id":"thr_fake","sessionId":"sess_fake","parentThreadId":null,"status":{"type":"idle"},"cwd":"/workspace","ephemeral":true,"preview":"","modelProvider":"openai","cliVersion":"0.144.4","source":"appServer","createdAt":1784155200,"updatedAt":1784155203,"turns":[]}}}'
      printf '%s\n' '{"method":"thread/status/changed","params":{"threadId":"thr_fake","status":{"type":"idle"}}}'
      ;;
    *'"method":"turn/start"'*)
      printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn_fake","status":"inProgress","items":[],"startedAt":1784155201,"completedAt":null,"durationMs":null,"error":null}}}'
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr_fake","turn":{"id":"turn_fake","status":"inProgress","items":[],"startedAt":1784155201,"completedAt":null,"durationMs":null,"error":null}}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thr_fake","turnId":"turn_fake","itemId":"item_fake","delta":"fake response"}}'
      case "$line" in
        *approval*)
          printf '%s\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thr_fake","turnId":"turn_fake","itemId":"command_fake","approvalId":null,"command":"git status","commandActions":[{"type":"unknown","command":"git status"}],"cwd":"/workspace","reason":"Verify the worktree","startedAtMs":1784155201500}}'
          ;;
        *)
          printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr_fake","turn":{"id":"turn_fake","status":"completed","items":[],"startedAt":1784155201,"completedAt":1784155202,"durationMs":1000,"error":null}}}'
          ;;
      esac
      ;;
    *'"id":"approval-1"'*'"decision":"accept"'*)
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr_fake","turn":{"id":"turn_fake","status":"completed","items":[],"startedAt":1784155201,"completedAt":1784155202,"durationMs":1000,"error":null}}}'
      ;;
  esac
done

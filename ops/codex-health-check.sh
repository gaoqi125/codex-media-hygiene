#!/usr/bin/env bash
set -uo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
WARN_SESSION_MB="${WARN_SESSION_MB:-100}"
CRITICAL_SESSION_MB="${CRITICAL_SESSION_MB:-200}"
WARN_ROLLOUT_LINE_BYTES="${WARN_ROLLOUT_LINE_BYTES:-1048576}"
CRITICAL_ROLLOUT_LINE_BYTES="${CRITICAL_ROLLOUT_LINE_BYTES:-2097152}"
WARN_TOTAL_MB="${WARN_TOTAL_MB:-1024}"
WARN_RSS_MB="${WARN_RSS_MB:-1500}"
WARN_CPU_PERCENT="${WARN_CPU_PERCENT:-15}"
CPU_RESAMPLE_COUNT="${CPU_RESAMPLE_COUNT:-2}"
CPU_RESAMPLE_SECONDS="${CPU_RESAMPLE_SECONDS:-3}"

status=0

bytes_to_mb() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f", bytes / 1024 / 1024 }'
}

path_size_mb() {
  local path="$1"
  if [ -e "$path" ]; then
    du -sm "$path" 2>/dev/null | awk '{print $1}'
  else
    echo 0
  fi
}

warn() {
  printf 'WARN: %s\n' "$1"
  if [ "$status" -lt 1 ]; then
    status=1
  fi
}

info() {
  printf 'INFO: %s\n' "$1"
}

ps_cpu_for_pid() {
  ps -p "$1" -o %cpu= 2>/dev/null | awk '{print int($1); exit}'
}

critical() {
  printf 'CRITICAL: %s\n' "$1"
  status=2
}

printf 'Codex health check\n'
printf 'CODEX_HOME=%s\n\n' "$CODEX_HOME"

if [ ! -d "$CODEX_HOME" ]; then
  critical "Codex home does not exist: $CODEX_HOME"
  exit "$status"
fi

sessions_dir="$CODEX_HOME/sessions"
archived_dir="$CODEX_HOME/archived_sessions"

sessions_mb="$(path_size_mb "$sessions_dir")"
archived_mb="$(path_size_mb "$archived_dir")"
total_sessions_mb=$((sessions_mb + archived_mb))

printf 'Session storage:\n'
printf '  sessions:          %s MB\n' "$sessions_mb"
printf '  archived_sessions: %s MB\n' "$archived_mb"
printf '  total:             %s MB\n' "$total_sessions_mb"

if [ "$total_sessions_mb" -gt "$WARN_TOTAL_MB" ]; then
  warn "sessions + archived_sessions exceed ${WARN_TOTAL_MB}MB; archive or move old large threads before continuing long work."
fi

printf '\nLarge rollout files:\n'
large_found=0
if [ -d "$sessions_dir" ] || [ -d "$archived_dir" ]; then
  while IFS= read -r -d '' file; do
    large_found=1
    size_bytes="$(stat -f '%z' "$file" 2>/dev/null || echo 0)"
    size_mb="$(bytes_to_mb "$size_bytes")"
    printf '  %7s MB  %s\n' "$size_mb" "$file"
    size_int="${size_mb%.*}"
    if [ "$size_int" -gt "$CRITICAL_SESSION_MB" ]; then
      critical "rollout file exceeds ${CRITICAL_SESSION_MB}MB: $file"
    elif [ "$size_int" -gt "$WARN_SESSION_MB" ]; then
      warn "rollout file exceeds ${WARN_SESSION_MB}MB: $file"
    fi
  done < <(find "$sessions_dir" "$archived_dir" -type f -name 'rollout-*.jsonl' -size +"${WARN_SESSION_MB}"M -print0 2>/dev/null)
fi
if [ "$large_found" -eq 0 ]; then
  printf '  none over %s MB\n' "$WARN_SESSION_MB"
fi

printf '\nOversized rollout records:\n'
oversized_found=0
if [ -d "$sessions_dir" ] || [ -d "$archived_dir" ]; then
  while IFS="$(printf '\t')" read -r file count max_len; do
    [ -n "$file" ] || continue
    oversized_found=1
    if [ "$max_len" -gt "$CRITICAL_ROLLOUT_LINE_BYTES" ]; then
      printf '  %s oversized line(s), max=%s bytes  %s\n' "$count" "$max_len" "$file"
      critical "rollout record exceeds ${CRITICAL_ROLLOUT_LINE_BYTES} bytes: $file"
    elif [ "$max_len" -gt "$WARN_ROLLOUT_LINE_BYTES" ]; then
      printf '  %s oversized line(s), max=%s bytes  %s\n' "$count" "$max_len" "$file"
      warn "rollout record exceeds ${WARN_ROLLOUT_LINE_BYTES} bytes: $file"
    fi
  done < <(
    find "$sessions_dir" "$archived_dir" -type f -name 'rollout-*.jsonl' -exec awk -v warn="$WARN_ROLLOUT_LINE_BYTES" '
      length($0) > warn {
        count += 1
        if (length($0) > max_len) {
          max_len = length($0)
        }
      }
      END {
        if (count > 0) {
          printf "%s\t%s\t%s\n", FILENAME, count, max_len
        }
      }
    ' {} \; 2>/dev/null
  )
fi
if [ "$oversized_found" -eq 0 ]; then
  printf '  none over %s bytes\n' "$WARN_ROLLOUT_LINE_BYTES"
fi

printf '\nCodex processes:\n'
if command -v ps >/dev/null 2>&1; then
  ps_blocked=0
  if ! ps_all="$(ps auxww 2>/dev/null)"; then
    ps_blocked=1
    info "process check skipped because ps is blocked by the current execution environment."
    ps_output=""
  else
    ps_output="$(printf '%s\n' "$ps_all" | awk '/codex app-server|Codex|SkyComputerUseClient/ && !/awk/ {print}')"
  fi
  if [ -n "$ps_output" ]; then
    printf '%s\n' "$ps_output" | awk '{printf "  CPU=%5s%% RSS=%7.1f MB  %s\n", $3, $6/1024, substr($0, index($0,$11))}'
    app_server_line="$(printf '%s\n' "$ps_output" | awk '/codex app-server --listen unix:\/\// {print; exit}')"
    if [ -n "$app_server_line" ]; then
      app_pid="$(printf '%s\n' "$app_server_line" | awk '{print $2}')"
      app_cpu="$(printf '%s\n' "$app_server_line" | awk '{print int($3)}')"
      app_rss_mb="$(printf '%s\n' "$app_server_line" | awk '{print int($6/1024)}')"
      if [ "$app_cpu" -gt "$WARN_CPU_PERCENT" ]; then
        high_cpu_samples=1
        sample_index=0
        while [ "$sample_index" -lt "$CPU_RESAMPLE_COUNT" ]; do
          sample_index=$((sample_index + 1))
          sleep "$CPU_RESAMPLE_SECONDS"
          next_cpu="$(ps_cpu_for_pid "$app_pid")"
          if [ -n "$next_cpu" ] && [ "$next_cpu" -gt "$WARN_CPU_PERCENT" ]; then
            high_cpu_samples=$((high_cpu_samples + 1))
          fi
        done
        if [ "$high_cpu_samples" -gt "$CPU_RESAMPLE_COUNT" ]; then
          warn "codex app-server CPU stayed above ${WARN_CPU_PERCENT}% across $((CPU_RESAMPLE_COUNT + 1)) samples."
        else
          printf '  CPU spike was transient across %s follow-up sample(s).\n' "$CPU_RESAMPLE_COUNT"
        fi
      fi
      if [ "$app_rss_mb" -gt "$WARN_RSS_MB" ]; then
        warn "codex app-server RSS exceeds ${WARN_RSS_MB}MB."
      fi
    fi
  elif [ "$ps_blocked" -eq 0 ]; then
    printf '  no Codex processes found\n'
  fi
else
  info "process check skipped because ps command is unavailable."
fi

printf '\nResult: '
case "$status" in
  0)
    printf 'OK\n'
    ;;
  1)
    printf 'WARN - review warnings before the next major task step.\n'
    ;;
  *)
    printf 'CRITICAL - stop before the next task step and confirm cleanup.\n'
    ;;
esac

printf '\nThis script is read-only. It does not delete, move, or rewrite Codex data.\n'
exit "$status"

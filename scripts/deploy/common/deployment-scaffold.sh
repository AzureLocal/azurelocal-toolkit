#!/usr/bin/env bash
set -euo pipefail

resolve_repo_root() {
  local start_path="$1"
  local current_path
  current_path="$(cd "$start_path" && pwd)"

  while [[ "$current_path" != "/" ]]; do
    if [[ -f "$current_path/config/variables/variables.example.yml" ]]; then
      printf '%s\n' "$current_path"
      return 0
    fi
    current_path="$(dirname "$current_path")"
  done

  return 1
}

initialize_config_path() {
  local repo_root="$1"
  local requested_path="${2:-}"
  local resolved_path
  local template_path="$repo_root/config/variables/variables.example.yml"

  if [[ -n "$requested_path" ]]; then
    resolved_path="$requested_path"
  else
    resolved_path="$repo_root/config/variables/variables.yml"
  fi

  if [[ ! -f "$resolved_path" ]]; then
    if [[ ! -f "$template_path" ]]; then
      printf 'Runtime config missing and no template found at %s\n' "$template_path" >&2
      return 1
    fi

    mkdir -p "$(dirname "$resolved_path")"
    cp "$template_path" "$resolved_path"
  fi

  printf '%s\n' "$resolved_path"
}

new_log_path() {
  local repo_root="$1"
  local task_path="$2"
  local requested_path="${3:-}"
  local task_name
  local log_dir

  if [[ -n "$requested_path" ]]; then
    mkdir -p "$(dirname "$requested_path")"
    printf '%s\n' "$requested_path"
    return 0
  fi

  task_name="$(basename "$task_path")"
  log_dir="$repo_root/logs/$task_name"
  mkdir -p "$log_dir"
  printf '%s/%s.log\n' "$log_dir" "$(date +%Y%m%d-%H%M%S)"
}

write_log() {
  local log_path="$1"
  local level="$2"
  local message="$3"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" | tee -a "$log_path"
}

invoke_bash_deployment() {
  local script_path="$1"
  local task_path="$2"
  local action_name="$3"
  shift 3

  local config_path=""
  local log_path=""
  local passthrough=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-path)
        config_path="$2"
        shift 2
        ;;
      --log-path)
        log_path="$2"
        shift 2
        ;;
      *)
        passthrough+=("$1")
        shift
        ;;
    esac
  done

  local script_dir
  local repo_root
  local resolved_config_path
  local resolved_log_path

  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  repo_root="$(resolve_repo_root "$script_dir")"
  resolved_config_path="$(initialize_config_path "$repo_root" "$config_path")"
  resolved_log_path="$(new_log_path "$repo_root" "$task_path" "$log_path")"

  write_log "$resolved_log_path" INFO "Starting Bash scaffold '$action_name' for task '$task_path'."
  write_log "$resolved_log_path" INFO "Using config path '$resolved_config_path'."

  if ! command -v az >/dev/null 2>&1; then
    write_log "$resolved_log_path" ERROR "Azure CLI 'az' was not found in PATH."
    return 1
  fi

    write_log "$resolved_log_path" WARN "This script is a standards-compliant scaffold. Add task-specific Bash operations before production use."
  if [[ ${#passthrough[@]} -gt 0 ]]; then
    write_log "$resolved_log_path" DEBUG "Passthrough arguments: ${passthrough[*]}"
  fi
}

# shellcheck shell=bash
# nixbook-model-provider: which model provider the shell's AI talks to.
# Everything that calls a model (nixbook-meta-agent: the side panel, the
# memory and initiative passes, routines, the equalizer agent,
# nixbook-improve; Quick AI, the voice, the Nix onboarding) is started
# through `nixbook-model-provider run CMD ARGS…`, which hands it the
# provider's Messages API (Meta's by default, Muse models), its key and its
# model names in NIXBOOK_AI_* and runs it unchanged.
#
# The setting is the shell's (Settings > Desktop agents > Model provider):
# ai.provider = {kind: meta|custom, baseUrl, model, smallModel, bigModel} in
# ~/.config/nixbook-shell/config.json ("custom": another server with a
# Messages API). The API key is in the keyring (secret-tool), stored per
# provider and host: a key saved for one server is never sent to another.
#
#   run CMD [ARGS…]     exec CMD with the provider's environment:
#                       NIXBOOK_AI_BASE_URL, NIXBOOK_AI_KEY, NIXBOOK_AI_MODEL,
#                       NIXBOOK_AI_SMALL_MODEL, NIXBOOK_AI_BIG_MODEL,
#                       NIXBOOK_AI_PROVIDED=1
#   env                 the same values as one JSON object, for a process
#                       that wasn't started through `run` (desktop-mcp's
#                       helper and its passes, calling the API in-process):
#                       {baseUrl, key, model, smallModel, bigModel, label}
#                       or {error} (exit 3)
#   status              {kind, label, baseUrl, host, model, smallModel,
#                        bigModel, keySaved, error}
#   key set             the key on stdin → {saved} or {error}
#   key forget          → {saved: false}
#   test                one short request → {ok, model, answer} or {ok: false, error}
set -uo pipefail

config=${NIXBOOK_SHELL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nixbook-shell/config.json}

# The provider's settings, presets filled in: kind, base URL, main, small
# and big model (one line each).
settings() {
  jq -r '
    def presets: {meta: {baseUrl: "https://api.meta.ai", model: "muse-spark-1.3", smallModel: "muse-spark-1.3", bigModel: "muse-wonder-1.0"}};
    (.ai.provider // {}) as $p
    | (($p.kind // "meta") | tostring | ascii_downcase | if . == "" or . == "anthropic" then "meta" else . end) as $k
    | (presets[$k] // {}) as $preset
    | [ "baseUrl", "model", "smallModel", "bigModel" ]
    | map(($p[.] // "" | tostring) as $v | if $v == "" then ($preset[.] // "") else $v end) as $v
    | $k, ($v[0] | sub("/+$"; "")), $v[1], $v[2], $v[3]
  ' "$config" 2>/dev/null || printf 'meta\nhttps://api.meta.ai\nmuse-spark-1.3\nmuse-spark-1.3\nmuse-wonder-1.0\n'
}

{
  read -r kind
  read -r base
  read -r model
  read -r small
  read -r big
} < <(settings)
kind=${kind:-meta}
case "$kind" in
meta) label="Meta" ;;
custom) label="Custom" ;;
*)
  label=$kind
  ;;
esac

# The URL's error, if any: https, or http on this computer only (a local
# gateway); never a key sent in clear over the network.
url_error() {
  case "$kind" in
  meta | custom) ;;
  *)
    echo "unknown provider \"$kind\""
    return 0
    ;;
  esac
  if [ -z "$base" ]; then
    echo "no server URL"
  elif [[ ! $base =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] &&
    [[ ! $base =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "the server URL must be https:// (or http:// on this computer): $base"
  elif [ -z "$model" ]; then
    echo "no model"
  fi
}
host=$(sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$base")
attrs=(application nixbook-shell kind model-provider provider "$kind" host "$host")

lookup_key() {
  secret-tool lookup "${attrs[@]}" 2>/dev/null
}

# A failure the caller can read: a result line (nixbook-meta-agent's shape)
# when it was asked for JSON, otherwise on stderr.
fail_run() {
  local msg="$label: $1"
  if [[ " ${run_args[*]} " =~ \ --output-format[=\ ](stream-)?json\  ]]; then
    jq -cn --arg m "$msg" '{type: "result", subtype: "error_during_execution", is_error: true, result: $m}'
  fi
  echo "nixbook-model-provider: $msg" >&2
  exit 3
}

cmd_run() {
  local cmd=${1:-}
  shift || true
  run_args=("$@")
  [ -n "$cmd" ] || {
    echo "usage: nixbook-model-provider run CMD [ARGS…]" >&2
    exit 2
  }
  local err key v
  err=$(url_error)
  [ -z "$err" ] || fail_run "$err (Settings > Desktop agents > Model provider)"
  key=$(lookup_key)
  [ -n "$key" ] || fail_run "no API key saved (Settings > Desktop agents > Model provider)"
  # Only the provider's key: nothing of another vendor's from the
  # environment (it would be sent along, or used instead). ${!PREFIX@}, not
  # `compgen -e`: Nix's script bash is the non-interactive build, without
  # the completion builtins ("compgen: command not found").
  for v in "${!ANTHROPIC_@}" "${!CLAUDE_CODE_@}"; do
    unset "$v"
  done
  export NIXBOOK_AI_BASE_URL=$base NIXBOOK_AI_KEY=$key NIXBOOK_AI_MODEL=$model
  export NIXBOOK_AI_SMALL_MODEL=${small:-$model} NIXBOOK_AI_BIG_MODEL=${big:-$model}
  export NIXBOOK_AI_LABEL=$label NIXBOOK_AI_PROVIDED=1
  exec "$cmd" "$@"
}

cmd_env() {
  local err key
  err=$(url_error)
  [ -z "$err" ] || {
    jq -cn --arg e "$label: $err (Settings > Desktop agents > Model provider)" '{error: $e}'
    exit 3
  }
  key=$(lookup_key)
  [ -n "$key" ] || {
    jq -cn --arg e "$label: no API key saved (Settings > Desktop agents > Model provider)" '{error: $e}'
    exit 3
  }
  # The key from stdin, never on a command line (ps shows those).
  printf '%s' "$key" | jq -cR --arg base "$base" --arg model "$model" --arg small "${small:-$model}" \
    --arg big "${big:-$model}" --arg label "$label" \
    '{baseUrl: $base, key: ., model: $model, smallModel: $small, bigModel: $big, label: $label}'
}

cmd_status() {
  local saved=false err
  err=$(url_error)
  [ -z "$err" ] && [ -n "$(lookup_key)" ] && saved=true
  jq -cn --arg kind "$kind" --arg label "$label" --arg base "$base" --arg host "$host" --arg model "$model" \
    --arg small "$small" --arg big "$big" --argjson saved "$saved" --arg err "$err" \
    '{kind: $kind, label: $label, baseUrl: $base, host: $host, model: $model, smallModel: $small,
      bigModel: $big, keySaved: $saved, error: $err}'
}

cmd_key() {
  local err key
  case "${1:-}" in
  set)
    err=$(url_error)
    [ -z "$err" ] || {
      jq -cn --arg e "$err" '{error: $e}'
      return
    }
    IFS= read -r key || true
    key=$(tr -d '[:space:]' <<<"$key")
    [[ -n $key && $key =~ ^[[:print:]]+$ ]] || {
      jq -cn '{error: "empty key"}'
      return
    }
    if printf '%s' "$key" | secret-tool store --label="nixbook-shell: $label API key ($host)" "${attrs[@]}" 2>/dev/null; then
      jq -cn '{saved: true}'
    else
      jq -cn '{error: "the keyring refused it (secret-tool store)"}'
    fi
    ;;
  forget)
    secret-tool clear "${attrs[@]}" 2>/dev/null
    jq -cn '{saved: false}'
    ;;
  *)
    echo "usage: nixbook-model-provider key set|forget" >&2
    exit 2
    ;;
  esac
}

cmd_test() {
  local err key reply code
  err=$(url_error)
  [ -z "$err" ] || {
    jq -cn --arg e "$err" '{ok: false, error: $e}'
    return
  }
  key=$(lookup_key)
  [ -n "$key" ] || {
    jq -cn '{ok: false, error: "no API key saved"}'
    return
  }
  # The key as a header from a file descriptor, never on a command line.
  reply=$(curl -sS -m 40 -w '\n%{http_code}' "$base/v1/messages" \
    -H @<(printf 'Authorization: Bearer %s\n' "$key") \
    -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
    --data "$(jq -cn --arg m "$model" '{model: $m, max_tokens: 32, messages: [{role: "user", content: "Answer with one word: ready."}]}')" 2>&1)
  code=$(tail -n1 <<<"$reply")
  reply=$(sed '$d' <<<"$reply")
  if [ "$code" = 200 ]; then
    jq -c --arg m "$model" '{ok: true, model: (.model // $m), answer: ([.content[]? | select(.type == "text") | .text] | join("") | .[0:80])}' <<<"$reply" 2>/dev/null ||
      jq -cn '{ok: false, error: "the server answered something that is not a Messages API reply"}'
  else
    jq -cn --arg c "$code" --arg r "$reply" \
      '{ok: false, error: ("HTTP " + $c + ": " + (($r | fromjson? | .error.message // .message // .error // empty | tostring) // $r | .[0:200]))}'
  fi
}

case "${1:-}" in
run)
  shift
  cmd_run "$@"
  ;;
status) cmd_status ;;
env) cmd_env ;;
key)
  shift
  cmd_key "$@"
  ;;
test) cmd_test ;;
*)
  echo "usage: nixbook-model-provider run CMD [ARGS…] | env | status | key set|forget | test" >&2
  exit 2
  ;;
esac

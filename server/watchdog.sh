#!/usr/bin/env bash
# Сторож для claude-bot.service. Запускається з cron кожні 5 хв.
# DRY_RUN=1 -> без рестарту й без відправки пульсу (усе пишеться в лог).
set -u
export PATH=/usr/local/bin:/usr/bin:/bin
export TZ=Europe/Kyiv

BASE="$HOME/watchdog"
LOGDIR="$BASE/logs"
STATE="$BASE/state"
SERVICE="claude-bot"
SESSION="bot"
URL="https://your-instance.app.n8n.cloud/webhook/server-pulse"
MAX_RESTARTS=3
WINDOW=3600
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$LOGDIR" "$STATE"
LOG="$LOGDIR/watchdog-$(date +%F).log"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# один екземпляр за раз
exec 9>"$BASE/.lock"
flock -n 9 || { log "skip: інший запуск ще працює"; exit 0; }

# ротація логів (тільки *.log в logs/)
find "$LOGDIR" -maxdepth 1 -type f -name '*.log' -mtime +14 -delete

# ключ: читаємо з .env, у логи не пишемо
PULSE_KEY="$(grep -m1 '^PULSE_KEY=' "$BASE/.env" 2>/dev/null | cut -d= -f2-)"

pulse() { # $1=status $2=detail
  local status="$1" detail="$2" body code
  body="$(jq -nc --arg s "$status" --arg d "$detail" '{status:$s,detail:$d}')"
  if [ "$DRY_RUN" = 1 ]; then log "DRY pulse: $body"; return 0; fi
  if [ -z "$PULSE_KEY" ]; then log "pulse НЕ надіслано: PULSE_KEY порожній"; return 1; fi
  # ключ іде через @<(...), щоб не світився в ps
  code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST "$URL" \
          -H 'Content-Type: application/json' \
          -H @<(printf 'x-pulse-key: %s\n' "$PULSE_KEY") \
          -d "$body" 2>>"$LOG")" || { log "pulse $status: curl впав"; return 1; }
  log "pulse $status -> HTTP $code"
}

# повертає 0 якщо все ок; інакше друкує список проблем в $PROBLEMS
check() {
  PROBLEMS=()
  systemctl is-active --quiet "$SERVICE" || PROBLEMS+=("служба не active")
  tmux has-session -t "$SESSION" 2>/dev/null || PROBLEMS+=("нема tmux-сесії $SESSION")

  local cg procs pid cmd have_claude=0 have_bun=0
  cg="$(systemctl show -p ControlGroup --value "$SERVICE" 2>/dev/null)"
  procs="/sys/fs/cgroup${cg}/cgroup.procs"
  if [ -n "$cg" ] && [ -r "$procs" ]; then
    while read -r pid; do
      cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
      [[ "$cmd" == *claude*--channels* ]] && have_claude=1
      [[ "$cmd" =~ (^|/)bun[[:space:]].*telegram ]] && have_bun=1
    done < "$procs"
  fi
  [ "$have_claude" = 1 ] || PROBLEMS+=("нема процесу claude у cgroup служби")
  [ "$have_bun" = 1 ] || PROBLEMS+=("нема bun-плагіна telegram у cgroup служби")
  [ "${#PROBLEMS[@]}" -eq 0 ]
}

join() { local IFS='; '; echo "$*"; }

FAILED_FLAG="$STATE/failed_sent"
HIST="$STATE/restarts"

if check; then
  rm -f "$FAILED_FLAG"
  log "ok"
  pulse ok "усе працює"
  exit 0
fi

first="$(join "${PROBLEMS[@]}")"
log "проблема: $first"

# історія рестартів за останню годину
now=$(date +%s)
touch "$HIST"
awk -v lim=$((now - WINDOW)) '$1 > lim' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
count=$(wc -l < "$HIST")

if [ "$count" -ge "$MAX_RESTARTS" ]; then
  log "ліміт рестартів ($count/$MAX_RESTARTS за годину), не рестартю"
  if [ ! -e "$FAILED_FLAG" ]; then
    pulse failed "ліміт $MAX_RESTARTS рестартів/год вичерпано: $first" && touch "$FAILED_FLAG"
  else
    log "failed уже надсилали, мовчу"
  fi
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY: тут був би sudo systemctl restart $SERVICE і пауза 60с"
  pulse restarted "DRY: $first"
  exit 0
fi

echo "$now" >> "$HIST"
log "рестарт $SERVICE ($((count + 1))/$MAX_RESTARTS)"
if ! sudo -n /usr/bin/systemctl restart "$SERVICE" >>"$LOG" 2>&1; then
  log "sudo/systemctl restart не вдався"
  if [ ! -e "$FAILED_FLAG" ]; then
    pulse failed "рестарт не вдався (sudo?): $first" && touch "$FAILED_FLAG"
  fi
  exit 0
fi

sleep 60
if check; then
  rm -f "$FAILED_FLAG"
  log "після рестарту ок"
  pulse restarted "перезапущено, бо: $first"
else
  second="$(join "${PROBLEMS[@]}")"
  log "після рестарту все ще не ок: $second"
  if [ ! -e "$FAILED_FLAG" ]; then
    pulse failed "рестарт не допоміг: $second" && touch "$FAILED_FLAG"
  fi
fi

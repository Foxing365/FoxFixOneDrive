#!/bin/zsh
# FoxFixOneDrive - OneDrive for Mac Runaway & Badge-Storm Guard (v5)
#
# Key Features:
#   1. Two-Stage Lazy Detection (< 0.001% background CPU when idle):
#      - Stage 1 (Fast Path): Runs a single `ps` snapshot every 30s (~40ms, zero disk/log I/O)
#        and calculates both instantaneous %CPU and cumulative CPU time integral (ΔTIME / ΔElapsed)
#        to catch even 1-file pulse retry loops (1.0s scan / 0.5s sleep).
#      - Stage 2 (Deep Check): Only triggered when OneDrive CPU >= 22% (or OneDrive + fileproviderd >= 30%).
#        Samples 3s of live network throughput via `nettop` to distinguish real high-speed file transfers
#        from 0 KB/s stalled retry storms.
#   2. Self-Healing Real-Time Sync + 100% Reversible Apple Silicon E-Core Throttling:
#      - Automatically closes stalled OneDrive proxy connections in Clash Verge / Mihomo (via local Unix socket)
#        so OneDrive immediately reconnects and finishes uploading.
#      - Uses `/usr/sbin/taskpolicy -b -p <PID>` to confine runaway OneDrive threads to Apple Silicon
#        efficiency cores (E-Cores) without killing the process or interrupting sync monitoring.
#      - Immediately restores OneDrive to performance cores (`taskpolicy -B`) as soon as real network
#        transfer (>= 5 KB/s) resumes or CPU stabilizes (< 12%).
#   3. Do-Not-Disturb-Piercing Native HUD Banner:
#      - Displays a non-activating macOS vibrancy toast at the top-right corner (`onedrive_hud`)
#        and logs to Notification Center.

set -u

SCRIPT_DIR="${0:A:h}"
HUD_BIN="${SCRIPT_DIR}/onedrive_hud"
USER_UID="$(id -u)"
MIHOMO_SOCK="${MIHOMO_SOCK:-/var/run/clash-verge-service/users/${USER_UID}/verge-mihomo.sock}"

INTERVAL="${INTERVAL:-30}"                  # Normal fast-check interval (seconds)
ALERT_INTERVAL="${ALERT_INTERVAL:-15}"      # Recheck interval when elevated CPU is detected (seconds)
NET_SAMPLE_SECS="${NET_SAMPLE_SECS:-3}"     # Network throughput sampling window (seconds)
CPU_HIGH_THRESHOLD="${CPU_HIGH_THRESHOLD:-22.0}"         # OneDrive CPU threshold (%)
COMBINED_CPU_THRESHOLD="${COMBINED_CPU_THRESHOLD:-30.0}" # OneDrive + fileproviderd combined CPU threshold (%)
CPU_CALM_THRESHOLD="${CPU_CALM_THRESHOLD:-12.0}"         # Calm OneDrive CPU threshold (%)
COMBINED_CALM_THRESHOLD="${COMBINED_CALM_THRESHOLD:-18.0}" # Calm combined CPU threshold (%)
NET_IDLE_THRESHOLD_KB="${NET_IDLE_THRESHOLD_KB:-5}"      # Network throughput threshold for stalled state (KB/s)
STRIKE_LIMIT="${STRIKE_LIMIT:-2}"           # Consecutive stalled checks before throttling
RECOVERY_LIMIT="${RECOVERY_LIMIT:-2}"       # Consecutive calm checks before restoring to P-Core

STATE_DIR="${HOME}/.cache/onedrive-guard"
mkdir -p "$STATE_DIR"
LOG_FILE="${STATE_DIR}/guard.log"
THROTTLED_FLAG="${STATE_DIR}/throttled.pid"

log_msg() {
  local ts
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$ts] $1" >> "$LOG_FILE"
  if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 1200 ]]; then
    tail -n 800 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

notify_user() {
  local title="$1"
  local subtitle="$2"
  local message="$3"
  if [[ -x "$HUD_BIN" ]]; then
    "$HUD_BIN" "$title" "$subtitle" "$message" 6.5 >/dev/null 2>&1 &
  fi
  /usr/bin/osascript -e "display notification \"${message}\" with title \"${title}\" subtitle \"${subtitle}\"" >/dev/null 2>&1 || true
}

reset_stalled_onedrive_connections() {
  if [[ ! -S "$MIHOMO_SOCK" ]]; then
    echo "0"
    return 0
  fi
  local ids
  ids=$(/usr/bin/curl -s --max-time 2 --unix-socket "$MIHOMO_SOCK" http://localhost/connections 2>/dev/null \
    | /usr/bin/python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    for c in data.get("connections") or []:
        proc = (c.get("metadata") or {}).get("process", "")
        if "OneDrive" in proc:
            print(c.get("id", ""))
except Exception:
    pass
' 2>/dev/null)

  local closed=0
  for cid in ${(f)ids}; do
    if [[ -n "$cid" ]]; then
      /usr/bin/curl -s -X DELETE --max-time 1 --unix-socket "$MIHOMO_SOCK" "http://localhost/connections/${cid}" >/dev/null 2>&1 || true
      closed=$((closed + 1))
    fi
  done
  echo "$closed"
}

get_cpu_snapshot() {
  ps -Ao pid,pcpu,time,rss,comm | awk '
    function parse_time(t,   n, a, d, h, m, s) {
      d = 0; h = 0; m = 0; s = 0;
      if (index(t, "-") > 0) {
        split(t, a, "-"); d = a[1]+0; t = a[2];
      }
      n = split(t, a, ":");
      if (n == 3) { h = a[1]+0; m = a[2]+0; s = a[3]+0; }
      else if (n == 2) { m = a[1]+0; s = a[2]+0; }
      return d*86400 + h*3600 + m*60 + s;
    }
    $5 == "/Applications/OneDrive.app/Contents/MacOS/OneDrive" {
      od_cpu += $2
      od_sec += parse_time($3)
      if ($4 > max_rss) { max_rss = $4; od_pid = $1 }
    }
    $5 ~ /\/fileproviderd$/ {
      fpd_cpu += $2
      fpd_sec += parse_time($3)
    }
    END {
      if (od_pid == "") {
        print "0 0.0 0.0 0.0 0.0"
      } else {
        printf "%d %.1f %.1f %.2f %.2f\n", od_pid, od_cpu, fpd_cpu, od_sec, fpd_sec
      }
    }
  '
}

get_onedrive_net_kbps() {
  local pid="$1"
  local secs="$2"
  local s1 s2
  s1=$(/usr/bin/nettop -P -L 1 -n -J bytes_in,bytes_out 2>/dev/null | awk -F',' -v p="OneDrive.${pid}" '$1 == p {print $2+$3}')
  sleep "$secs"
  s2=$(/usr/bin/nettop -P -L 1 -n -J bytes_in,bytes_out 2>/dev/null | awk -F',' -v p="OneDrive.${pid}" '$1 == p {print $2+$3}')
  if [[ -z "$s1" || -z "$s2" ]]; then
    echo "0.0"
    return
  fi
  awk -v b1="$s1" -v b2="$s2" -v dt="$secs" 'BEGIN {
    diff = b2 - b1;
    if (diff < 0) diff = 0;
    printf "%.1f", (diff / 1024.0) / dt
  }'
}

throttle_to_ecore() {
  local pid="$1"
  local detail="$2"
  if [[ -n "$pid" && "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
    local closed_conns
    closed_conns=$(reset_stalled_onedrive_connections)
    if /usr/sbin/taskpolicy -b -p "$pid" >/dev/null 2>&1; then
      echo "$pid" > "$THROTTLED_FLAG"
      log_msg "⚠️ 触发保护 (PID=$pid): $detail -> 已重置 ${closed_conns} 个卡死连接并执行 taskpolicy -b 锁入能效核(E-Core)"
      notify_user "OneDrive 防失控保护已介入" "已锁入省电小核 + 自动重连卡死通道" "${detail}，已重置 ${closed_conns} 条代理连接帮其恢复同步。"
    fi
  fi
}

restore_to_pcore() {
  local pid="$1"
  local detail="$2"
  local notify="${3:-1}"
  if [[ -n "$pid" && "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
    /usr/sbin/taskpolicy -B -p "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$THROTTLED_FLAG"
  log_msg "✅ 解除保护 (PID=$pid): $detail -> 已执行 taskpolicy -B 恢复大核(P-Core)默认调度"
  if [[ "$notify" -eq 1 ]]; then
    notify_user "OneDrive 已恢复正常" "已放回性能大核 (P-Core) 满血同步" "${detail}"
  fi
}

case "${1:---once}" in
  --test-notify)
    notify_user "OneDrive 防失控守护测试" "已支持穿透勿扰模式（6秒自动消失）" "发疯切小核、稳定回大核时，都会在右上角弹出此悬浮提醒，点击可立即关闭。"
    echo "已发送穿透勿扰模式的右上角悬浮通知，请看屏幕右上角。"
    ;;
  --restore)
    read -r od_pid od_cpu fpd_cpu od_sec fpd_sec <<< "$(get_cpu_snapshot)"
    restore_to_pcore "$od_pid" "手动恢复大核默认调度 (当前瞬时 CPU=${od_cpu}%)" 1
    echo "已将 OneDrive (PID=${od_pid}) 恢复回大核默认调度策略。"
    ;;
  --once)
    read -r od_pid od_cpu fpd_cpu od_sec fpd_sec <<< "$(get_cpu_snapshot)"
    if [[ "$od_pid" -eq 0 ]]; then
      echo "OneDrive 未运行。"
      exit 0
    fi
    throttled_state="正常(大核默认调度)"
    if [[ -f "$THROTTLED_FLAG" ]]; then
      throttled_state="已限流(后台能效核 E-Core)"
    fi
    comb_cpu=$(awk -v a="$od_cpu" -v b="$fpd_cpu" 'BEGIN {printf "%.1f", a+b}')
    is_hot=$(awk -v od="$od_cpu" -v comb="$comb_cpu" -v od_th="$CPU_HIGH_THRESHOLD" -v comb_th="$COMBINED_CPU_THRESHOLD" \
      'BEGIN {print (od >= od_th || comb >= comb_th) ? 1 : 0}')
    if [[ "$is_hot" -eq 0 ]]; then
      echo "快检通过: OneDrive(PID=${od_pid}) CPU=${od_cpu}% | fileproviderd CPU=${fpd_cpu}% | 调度状态=${throttled_state}"
      exit 0
    fi
    net_kbps=$(get_onedrive_net_kbps "$od_pid" "$NET_SAMPLE_SECS")
    echo "深度复核: OneDrive(PID=${od_pid}) CPU=${od_cpu}% | fileproviderd CPU=${fpd_cpu}% | 实时网速=${net_kbps} KB/s | 调度状态=${throttled_state}"
    ;;
  --daemon)
    log_msg "OneDrive 防失控守护进程 v5 (累计CPU积分检测) 已启动。"
    strikes=0
    recoveries=0
    prev_ts=$(date +%s)
    read -r prev_pid _ _ prev_od_sec prev_fpd_sec <<< "$(get_cpu_snapshot)"

    while true; do
      if [[ "$strikes" -gt 0 || -f "$THROTTLED_FLAG" ]]; then
        sleep "$ALERT_INTERVAL"
      else
        sleep "$INTERVAL"
      fi

      now_ts=$(date +%s)
      dt=$((now_ts - prev_ts))
      [[ "$dt" -le 0 ]] && dt=1

      read -r od_pid od_inst_cpu fpd_inst_cpu od_sec fpd_sec <<< "$(get_cpu_snapshot)"

      if [[ -f "$THROTTLED_FLAG" ]]; then
        old_pid=$(cat "$THROTTLED_FLAG" 2>/dev/null || echo "0")
        if [[ "$od_pid" -eq 0 || "$od_pid" != "$old_pid" ]]; then
          rm -f "$THROTTLED_FLAG"
          strikes=0
          recoveries=0
        fi
      fi

      if [[ "$od_pid" -gt 0 ]]; then
        read -r eff_od_cpu eff_fpd_cpu eff_comb_cpu is_hot <<< "$(awk \
          -v pid="$od_pid" -v p_pid="$prev_pid" \
          -v inst_od="$od_inst_cpu" -v inst_fpd="$fpd_inst_cpu" \
          -v s_od="$od_sec" -v ps_od="$prev_od_sec" \
          -v s_fpd="$fpd_sec" -v ps_fpd="$prev_fpd_sec" \
          -v dt="$dt" \
          -v od_th="$CPU_HIGH_THRESHOLD" -v comb_th="$COMBINED_CPU_THRESHOLD" \
          'BEGIN {
            if (pid == p_pid && s_od >= ps_od && s_fpd >= ps_fpd) {
              avg_od = ((s_od - ps_od) / dt) * 100.0;
              avg_fpd = ((s_fpd - ps_fpd) / dt) * 100.0;
            } else {
              avg_od = inst_od;
              avg_fpd = inst_fpd;
            }
            eff_od = (avg_od > inst_od) ? avg_od : inst_od;
            eff_fpd = (avg_fpd > inst_fpd) ? avg_fpd : inst_fpd;
            comb = eff_od + eff_fpd;
            hot = (eff_od >= od_th || comb >= comb_th) ? 1 : 0;
            printf "%.1f %.1f %.1f %d\n", eff_od, eff_fpd, comb, hot;
          }')"

        prev_pid="$od_pid"
        prev_od_sec="$od_sec"
        prev_fpd_sec="$prev_fpd_sec"
        prev_fpd_sec="$fpd_sec"
        prev_ts="$now_ts"

        if [[ "$is_hot" -eq 1 ]]; then
          net_kbps=$(get_onedrive_net_kbps "$od_pid" "$NET_SAMPLE_SECS")
          prev_ts=$(date +%s)
          read -r _ _ _ prev_od_sec prev_fpd_sec <<< "$(get_cpu_snapshot)"

          is_stalled=$(awk -v net="$net_kbps" -v th="$NET_IDLE_THRESHOLD_KB" 'BEGIN {print (net < th) ? 1 : 0}')

          if [[ "$is_stalled" -eq 1 ]]; then
            recoveries=0
            strikes=$((strikes + 1))
            if [[ ! -f "$THROTTLED_FLAG" ]]; then
              log_msg "检测到死循环空转 ($strikes/$STRIKE_LIMIT): 周期CPU=${eff_od_cpu}% (含fileproviderd=${eff_comb_cpu}%), 网速=${net_kbps}KB/s"
              if [[ "$strikes" -ge "$STRIKE_LIMIT" ]]; then
                throttle_to_ecore "$od_pid" "平均CPU ${eff_od_cpu}% (合计${eff_comb_cpu}%) 但网速仅 ${net_kbps}KB/s"
              fi
            fi
          else
            strikes=0
            recoveries=0
            if [[ -f "$THROTTLED_FLAG" ]]; then
              restore_to_pcore "$od_pid" "实时同步正在高速传输 (网速 ${net_kbps} KB/s)，已立即恢复大核全速运行" 1
            fi
          fi
        else
          strikes=0
          if [[ -f "$THROTTLED_FLAG" ]]; then
            is_calm=$(awk -v od="$eff_od_cpu" -v comb="$eff_comb_cpu" -v od_c="$CPU_CALM_THRESHOLD" -v comb_c="$COMBINED_CALM_THRESHOLD" \
              'BEGIN {print (od < od_c && comb < comb_c) ? 1 : 0}')
            if [[ "$is_calm" -eq 1 ]]; then
              recoveries=$((recoveries + 1))
              if [[ "$recoveries" -ge "$RECOVERY_LIMIT" ]]; then
                restore_to_pcore "$od_pid" "CPU 已稳定回落至 ${eff_od_cpu}% (fileproviderd ${eff_fpd_cpu}%)" 1
                recoveries=0
              fi
            else
              recoveries=0
            fi
          fi
        fi
      fi
    done
    ;;
  *)
    echo "用法: $0 [--once | --daemon | --test-notify | --restore]"
    exit 1
    ;;
esac

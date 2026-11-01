#!/bin/zsh
# ==============================================================================
# OneDrive 防失控守护脚本 v6 (累计 CPU 积分 + 扩展进程纳管 + 脉冲退避破除本地死锁)
# 作用：
# 1. 采用【累计 CPU 时间差 (cputime delta)】计算采样周期内的真实平均 CPU（含 OneDrive、
#    OneDrive File Provider 扩展进程、以及系统 fileproviderd 守护进程）。
# 2. 当处于「高 CPU + 0 网速」死循环（无论是代理节点断流，还是本地批量生成文件引发的
#    UploadGate::RequeueOrRemoveUpload <-> fileproviderd 徽章刷新自激死锁）：
#    - 重置 Clash 卡死连接；
#    - 将 OneDrive 与 OneDrive File Provider 双双锁入能效核 (taskpolicy -b)；
#    - 注入微软漏写的【指数/脉冲退避刹车 (SIGSTOP/SIGCONT)】：每次暂停 OneDrive 3 秒让
#      fileproviderd 排空 XPC 队列、打破 hasFileChangedInternal 自激竞争，同时把活动监视器
#      里的 CPU 占用立竿见影压下来。
# 3. 一旦网速恢复 (>= 50 KB/s) 或总 CPU 彻底平息 (< 15%)，立即恢复全速大核运行。
# ==============================================================================

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

IDLE_CHECK_INTERVAL=35       # 正常态采样周期（秒）：每35秒算一次平均CPU，自身0消耗
ACTIVE_CHECK_INTERVAL=12     # 疑似/降频态采样周期（秒）
AVG_CPU_THRESHOLD=25.0       # 周期内 OneDrive 本体平均 CPU 阈值 (%)
TOTAL_CPU_THRESHOLD=45.0     # OneDrive + FileProvider扩展 + fileproviderd 合计平均 CPU 阈值 (%)
NET_SPEED_THRESHOLD_KB=10.0  # 死循环判定网速上限 (KB/s)：低于此值视为无实质传输
FAST_RECOVERY_NET_KB=50.0    # 高速同步恢复阈值 (KB/s)：高于此值立即解除限速全速上传
STRIKE_LIMIT=2               # 连续 2 个积分周期确认空转即触发保护
RECOVERY_CPU_THRESHOLD=15.0  # 恢复大核的合计平均 CPU 阈值 (%)

LOG_FILE="$HOME/.cache/onedrive-guard/guard.log"
CLASH_SOCK="/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock"
SCRIPT_DIR="${0:A:h}"
HUD_BIN="$SCRIPT_DIR/onedrive_hud"

mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

notify_user() {
    local title="$1"
    local subtitle="$2"
    local message="$3"
    if [[ -x "$HUD_BIN" ]]; then
        "$HUD_BIN" "$title" "$subtitle" "$message" >/dev/null 2>&1 &
    fi
    osascript -e "display notification \"$message\" with title \"$title\" subtitle \"$subtitle\"" >/dev/null 2>&1 &
}

get_onedrive_pid() {
    pgrep -f "/Applications/OneDrive.app/Contents/MacOS/OneDrive$" | head -n 1
}

get_fp_ext_pids() {
    pgrep -f "OneDrive File Provider"
}

get_fileproviderd_pid() {
    pgrep -x "fileproviderd" | head -n 1
}

# 将 ps 的时间格式 ([[dd-]hh:]mm:ss.xx) 转换为纯秒数 (浮点数)
get_proc_cpu_seconds() {
    local pid=$1
    [[ -z "$pid" ]] && { echo "0"; return; }
    ps -p "$pid" -o time= 2>/dev/null | awk '
    {
        gsub(/^[ \t]+|[ \t]+$/, "", $0)
        if ($0 == "") { print 0; exit }
        days = 0
        if (index($0, "-") > 0) {
            split($0, d, "-")
            days = d[1]
            $0 = d[2]
        }
        n = split($0, t, ":")
        if (n == 3) {
            secs = t[1]*3600 + t[2]*60 + t[3]
        } else if (n == 2) {
            secs = t[1]*60 + t[2]
        } else {
            secs = t[1]
        }
        printf "%.2f\n", days*86400 + secs
    }'
}

get_all_fp_ext_cpu_seconds() {
    local total=0.0
    local p s
    for p in $(get_fp_ext_pids); do
        s=$(get_proc_cpu_seconds "$p")
        total=$(awk -v a="$total" -v b="${s:-0}" 'BEGIN { printf "%.2f", a + b }')
    done
    echo "$total"
}

get_onedrive_net_bytes() {
    local pid=$1
    nettop -P -L 1 -p "$pid" -J bytes_in,bytes_out 2>/dev/null | awk -F',' '
        NR>1 && $2 != "" { sum += $2 + $3 }
        END { print sum+0 }
    '
}

# 测量一个窗口期内的平均 CPU (%) 与平均网速 (KB/s)
measure_window() {
    local pid=$1
    local duration=$2
    local fpd_pid=$(get_fileproviderd_pid)

    local cpu1=$(get_proc_cpu_seconds "$pid")
    local fpd1=$(get_proc_cpu_seconds "$fpd_pid")
    local ext1=$(get_all_fp_ext_cpu_seconds)
    local net1=$(get_onedrive_net_bytes "$pid")

    sleep "$duration"

    local cpu2=$(get_proc_cpu_seconds "$pid")
    local fpd2=$(get_proc_cpu_seconds "$fpd_pid")
    local ext2=$(get_all_fp_ext_cpu_seconds)
    local net2=$(get_onedrive_net_bytes "$pid")

    awk -v c1="${cpu1:-0}" -v c2="${cpu2:-0}" \
        -v f1="${fpd1:-0}" -v f2="${fpd2:-0}" \
        -v e1="${ext1:-0}" -v e2="${ext2:-0}" \
        -v n1="${net1:-0}" -v n2="${net2:-0}" \
        -v dt="$duration" '
    BEGIN {
        od_pct = ((c2 - c1) / dt) * 100.0
        if (od_pct < 0) od_pct = 0
        fpd_pct = ((f2 - f1) / dt) * 100.0
        if (fpd_pct < 0) fpd_pct = 0
        ext_pct = ((e2 - e1) / dt) * 100.0
        if (ext_pct < 0) ext_pct = 0
        net_kbps = ((n2 - n1) / dt) / 1024.0
        if (net_kbps < 0) net_kbps = 0
        printf "%.1f %.1f %.1f %.1f\n", od_pct, fpd_pct, ext_pct, net_kbps
    }'
}

reset_stalled_onedrive_connections() {
    if [[ ! -S "$CLASH_SOCK" ]]; then
        echo "0"
        return
    fi
    local conn_ids
    conn_ids=$(curl -s --unix-socket "$CLASH_SOCK" "http://localhost/connections" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    for c in data.get("connections", []):
        proc = c.get("metadata", {}).get("process", "")
        host = c.get("metadata", {}).get("host", "")
        if "OneDrive" in proc or any(d in host for d in ["1drv.com", "live.com", "sharepoint.com", "onedrive.com"]):
            print(c["id"])
except Exception:
    pass
' 2>/dev/null)

    local count=0
    for cid in ${(f)conn_ids}; do
        if [[ -n "$cid" ]]; then
            curl -s -X DELETE --unix-socket "$CLASH_SOCK" "http://localhost/connections/$cid" >/dev/null 2>&1
            ((count++))
        fi
    done
    echo "$count"
}

lock_to_ecores() {
    local pid=$1
    /usr/sbin/taskpolicy -b -p "$pid" >/dev/null 2>&1
    local p
    for p in $(get_fp_ext_pids); do
        /usr/sbin/taskpolicy -b -p "$p" >/dev/null 2>&1
    done
}

restore_onedrive_priority() {
    local pid=$1
    [[ -n "$pid" ]] && {
        kill -CONT "$pid" >/dev/null 2>&1
        /usr/sbin/taskpolicy -B -p "$pid" >/dev/null 2>&1
    }
    local p
    for p in $(get_fp_ext_pids); do
        /usr/sbin/taskpolicy -B -p "$p" >/dev/null 2>&1
    done
}

# 注入脉冲退避：暂停 OneDrive 几秒钟，让 fileproviderd 排空徽章队列、打破 hasFileChangedInternal 自激死锁
apply_backoff_pulse() {
    local pid=$1
    local pause_secs=${2:-3}
    local run_secs=${3:-2}
    local cycles=${4:-2}
    local i
    for (( i=1; i<=cycles; i++ )); do
        kill -0 "$pid" 2>/dev/null || return
        kill -STOP "$pid" >/dev/null 2>&1
        sleep "$pause_secs"
        kill -CONT "$pid" >/dev/null 2>&1
        sleep "$run_secs"
    done
}

# 退出时兜底恢复，绝不留下被 SIGSTOP 挂起的进程
cleanup_on_exit() {
    local pid=$(get_onedrive_pid)
    restore_onedrive_priority "$pid"
    exit 0
}
trap cleanup_on_exit EXIT INT TERM

log_msg "OneDrive 防失控守护进程 v6 (含 FileProvider 扩展纳管与脉冲退避破死锁) 已启动。"

strike_count=0
is_throttled=0
throttled_pid=""

while true; do
    pid=$(get_onedrive_pid)

    if [[ -z "$pid" ]]; then
        strike_count=0
        is_throttled=0
        throttled_pid=""
        sleep "$IDLE_CHECK_INTERVAL"
        continue
    fi

    if [[ $is_throttled -eq 1 && "$pid" != "$throttled_pid" ]]; then
        is_throttled=0
        strike_count=0
        throttled_pid=""
    fi

    window=$IDLE_CHECK_INTERVAL
    if [[ $strike_count -gt 0 || $is_throttled -eq 1 ]]; then
        window=$ACTIVE_CHECK_INTERVAL
    fi

    read -r od_cpu fpd_cpu ext_cpu net_kbps <<< "$(measure_window "$pid" "$window")"
    total_cpu=$(awk -v a="${od_cpu:-0}" -v b="${fpd_cpu:-0}" -v c="${ext_cpu:-0}" 'BEGIN { printf "%.1f", a + b + c }')

    # 判断是否处于「高CPU + 极低网速」的失控空转状态
    is_spinning=0
    if (( $(echo "$net_kbps < $NET_SPEED_THRESHOLD_KB" | bc -l) )); then
        if (( $(echo "$od_cpu > $AVG_CPU_THRESHOLD" | bc -l) )) || \
           (( $(echo "$od_cpu > 12.0 && $total_cpu > $TOTAL_CPU_THRESHOLD" | bc -l) )); then
            is_spinning=1
        fi
    fi

    if [[ $is_spinning -eq 1 ]]; then
        ((strike_count++))
        if [[ $is_throttled -eq 0 ]]; then
            log_msg "检测到死循环空转 ($strike_count/$STRIKE_LIMIT): OneDrive=${od_cpu}%, 扩展=${ext_cpu}%, fileproviderd=${fpd_cpu}% (合计=${total_cpu}%), 网速=${net_kbps}KB/s"
        fi

        if [[ $strike_count -ge $STRIKE_LIMIT && $is_throttled -eq 0 ]]; then
            closed_cnt=$(reset_stalled_onedrive_connections)
            lock_to_ecores "$pid"
            is_throttled=1
            throttled_pid="$pid"
            fp_storm=$(awk -v f="${fpd_cpu:-0}" -v e="${ext_cpu:-0}" 'BEGIN { print ((f + e) >= 15.0) ? 1 : 0 }')
            if [[ $fp_storm -eq 1 ]]; then
                log_msg "⚠️ 触发保护 (PID=$pid): 合计CPU ${total_cpu}% (OneDrive ${od_cpu}% + 扩展 ${ext_cpu}% + fpd ${fpd_cpu}%) 网速 ${net_kbps}KB/s -> 已重置 $closed_cnt 个连接、锁入小核并注入脉冲退避破除徽章死锁"
                notify_user "⚠️ OneDrive 疑似卡死空转" "已锁入小核 + 注入退避刹车 (合计CPU ${total_cpu}%)" "已重置 ${closed_cnt} 条连接并打断 FileProvider 徽章死锁，恢复传输后自动还原大核。"
                apply_backoff_pulse "$pid" 3 2 2
            else
                log_msg "⚠️ 触发保护 (PID=$pid): 合计CPU ${total_cpu}% (OneDrive ${od_cpu}% 全量目录扫描中) 网速 ${net_kbps}KB/s -> 已重置 $closed_cnt 个连接并锁入能效核静音运行"
                notify_user "⚠️ OneDrive 正在高负载扫描目录" "已锁入能效核静音运行 (CPU ${total_cpu}%)" "已重置 ${closed_cnt} 条连接并限制在小核后台扫描，待扫描完毕开始传输后自动还原大核。"
            fi
        elif [[ $is_throttled -eq 1 ]]; then
            # 仍在高负载空转中：持续补锁新派生的扩展进程；仅当存在 FileProvider 徽章风暴时才注入 SIGSTOP 脉冲
            lock_to_ecores "$pid"
            fp_storm=$(awk -v f="${fpd_cpu:-0}" -v e="${ext_cpu:-0}" 'BEGIN { print ((f + e) >= 15.0) ? 1 : 0 }')
            if [[ $fp_storm -eq 1 ]]; then
                apply_backoff_pulse "$pid" 3 2 2
            fi
        fi
    else
        if [[ $is_throttled -eq 1 ]]; then
            if (( $(echo "$net_kbps >= $FAST_RECOVERY_NET_KB" | bc -l) )); then
                restore_onedrive_priority "$pid"
                is_throttled=0
                strike_count=0
                throttled_pid=""
                log_msg "✅ 解除保护 (PID=$pid): 实时同步正在高速传输 (网速 ${net_kbps} KB/s)，已立即恢复大核全速运行"
                notify_user "✅ OneDrive 同步已恢复高速传输" "当前实时网速 ${net_kbps} KB/s" "死锁已解除，已自动恢复大核 (P-Core) 全速同步。"
            elif (( $(echo "$total_cpu < $RECOVERY_CPU_THRESHOLD" | bc -l) )); then
                restore_onedrive_priority "$pid"
                is_throttled=0
                strike_count=0
                throttled_pid=""
                log_msg "✅ 解除保护 (PID=$pid): 合计CPU 已稳定回落至 ${total_cpu}% (OneDrive ${od_cpu}%) -> 已恢复大核(P-Core)默认调度"
                notify_user "✅ OneDrive 已恢复正常" "合计CPU 已回落至 ${total_cpu}%" "空转已结束，已为您自动恢复大核 (P-Core) 默认调度。"
            else
                # 网速在 10~50 KB/s 之间但 CPU 仍高：保持小核观察，暂不盲目解封大核
                lock_to_ecores "$pid"
            fi
        else
            strike_count=0
        fi
    fi
done

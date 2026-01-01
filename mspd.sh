#!/usr/bin/env bash

# 1. ROOT CHECK
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)."
  exit 1
fi

# 2. PATHS
CONF_FILE="/etc/mspd.conf"
LOG_DIR="/var/log/mspd"
PEAK_LOG="$LOG_DIR/peaks.log"
BENCH_LOG="$LOG_DIR/benchmarks.log"

if [ ! -d "$LOG_DIR" ]; then mkdir -p "$LOG_DIR" 2>/dev/null; fi
touch "$PEAK_LOG" "$BENCH_LOG" 2>/dev/null
chmod 755 "$LOG_DIR" 2>/dev/null
chmod 666 "$PEAK_LOG" "$BENCH_LOG" 2>/dev/null

# --- ARGUMENT HANDLER ---
if [[ "$1" == "--reset" ]]; then
    read -p "Clear power history? (y/n): " confirm
    [[ "$confirm" == "y" ]] && rm -f "$PEAK_LOG" "$BENCH_LOG" && echo "History cleared."
    exit 0
fi

# Default fallback values
LINE_MAIN="▒"; LINE_SEC="-"
C_RESET="\033[0m"
COL_GAP=" | "; COL_GAP2="   |   "
REFRESH_RATE="0.025"; AVG_WINDOW=6; KWH_COST="0.12"
IDLE_THRESHOLD=15.0; HIGH_THRESHOLD=150.0
CLR_IDLE="\033[1;32m"; CLR_HIGH="\033[1;31m"; CLR_NORM="\033[0m"
EFFICIENCY_BASE=12.0; MIN_WIDTH=100; MIN_HEIGHT=28; MAX_PEAK_HISTORY=500
C_TIME="\033[1;36m"; C_CORE="\033[1;33m"; C_FREE="\033[1;32m"
C_USED="\033[1;31m"; C_MEM="\033[1;35m"; C_COMBINED="\033[1;37m"
C_COST="\033[1;32m"; C_UPTIME="\033[1;35m"

# Load config
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# 4. SETTINGS & TRACKING
MAX_CPU_W=0; MAX_RAM_W=0; MAX_GPU_W=0; MAX_DISK_W=0; MAX_COMBINED_W=0
current_gpu_w=0; current_cpu_w=0; current_ram_w=0; current_disk_total_w=0
cpu_buffer=(); gpu_buffer=()
BENCH_START=0; BENCH_SUM=0; BENCH_COUNT=0; BENCH_ACTIVE=false; LAST_BENCH_RES=""

# Runtime Visibility Toggles
SHOW_GPU=true
SHOW_STORAGE=true
SHOW_CPU=true

OS_NAME=$(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release || echo "Linux")
KERNEL_V=$(uname -r)
SH_NAME="${SHELL##*/}"

# --- MATH & LOGGING ---
calculate_avg() {
    local -n buffer=$1; local new_val=$2; local sum=0
    buffer+=("$new_val")
    if [ "${#buffer[@]}" -gt "${AVG_WINDOW:-6}" ]; then buffer=("${buffer[@]:1}"); fi
    for i in "${buffer[@]}"; do sum=$(echo "$sum + $i" | bc -l); done
    echo "scale=2; $sum / ${#buffer[@]}" | bc -l
}

get_efficiency_rating() {
    local val=$1
    local ratio=$(echo "scale=2; $val / $EFFICIENCY_BASE" | bc -l)
    if (( $(echo "$ratio <= 1.2" | bc -l) )); then echo -e "\033[1;32m[Rating: A+]\033[0m"
    elif (( $(echo "$ratio <= 2.0" | bc -l) )); then echo -e "\033[1;32m[Rating: A]\033[0m"
    elif (( $(echo "$ratio <= 4.0" | bc -l) )); then echo -e "\033[1;33m[Rating: B]\033[0m"
    elif (( $(echo "$ratio <= 8.0" | bc -l) )); then echo -e "\033[1;34m[Rating: C]\033[0m"
    else echo -e "\033[1;31m[Rating: F]\033[0m"; fi
}

update_peak_log() {
    if (( $(echo "$MAX_COMBINED_W > 0" | bc -l) )); then
       echo "[$(date '+%Y-%m-%d %H:%M:%S')] TOTAL_PEAK: ${MAX_COMBINED_W}W GPU_PEAK: ${MAX_GPU_W}W CPU_PEAK: ${MAX_CPU_W}W RAM_PEAK: ${MAX_RAM_W}W" >> "$PEAK_LOG"
    fi
}

prune_peaks() {
    if [ -f "$PEAK_LOG" ]; then
        tail -n "$MAX_PEAK_HISTORY" "$PEAK_LOG" > "$PEAK_LOG.tmp" && mv "$PEAK_LOG.tmp" "$PEAK_LOG"
        chmod 666 "$PEAK_LOG" 2>/dev/null
    fi
}

get_all_time_peaks() {
    if [ ! -f "$PEAK_LOG" ]; then echo -e "  No records."; return; fi
    local top_total=$(awk -F'TOTAL_PEAK: ' '{print $2}' "$PEAK_LOG" | awk '{print $1}' | tr -d 'W' | sort -rn | head -1)
    local top_gpu=$(awk -F'GPU_PEAK: ' '{print $2}' "$PEAK_LOG" | awk '{print $1}' | tr -d 'W' | sort -rn | head -1)
    local top_cpu=$(awk -F'CPU_PEAK: ' '{print $2}' "$PEAK_LOG" | awk '{print $1}' | tr -d 'W' | sort -rn | head -1)
    local top_ram=$(awk -F'RAM_PEAK: ' '{print $2}' "$PEAK_LOG" | awk '{print $1}' | tr -d 'W' | sort -rn | head -1)
    printf "  ${C_PEAK}HISTORIC TOTAL:${C_RESET} %-7s W${COL_GAP}${C_PEAK}GPU:${C_RESET} %-7s W${COL_GAP}${C_PEAK}CPU:${C_RESET} %-7s W${COL_GAP}${C_PEAK}DRAM:${C_RESET} %-7s W\n" \
        "${top_total:-0}" "${top_gpu:-0}" "${top_cpu:-0}" "${top_ram:-0}"
}

draw_line() {
    local width=$(tput cols); local char=${1:-=}
    [ "$width" -le 0 ] && width=80
    local line=$(printf "%${width}s" ""); echo -e "${C_SECT}${line// /$char}${C_RESET}"
}

center_text() {
    local width=$(tput cols); local text="$1"
    local padding=$(( (width - ${#text}) / 2 ))
    [ $padding -lt 0 ] && padding=0
    printf "%${padding}s${C_TITLE}%s${C_RESET}\n" "" "$text"
}

print_row() {
    local label=$1; local pwr=$2; local load=$3; local cfreq=$4; local mfreq=$5; local temp=$6; local color=$7
    printf "  [${color}%-7s${C_RESET}] " "$label"
    printf "${C_PWR}Pwr:${C_RESET} %-6s W${COL_GAP}${C_LOAD}Load:${C_RESET} %-3s %%${COL_GAP}${C_CORE}Core:${C_RESET} %-4s MHz" "$pwr" "$load" "$cfreq"
    if [[ "$mfreq" != "--" && ! -z "$mfreq" ]]; then printf "${COL_GAP}${C_MEM}Mem:${C_RESET} %-4s MHz" "$mfreq"; fi
    if [ ! -z "$temp" ] && [ "$temp" != "--" ]; then printf "${COL_GAP}${C_TEMP}Temp:${C_RESET} %-3s °C" "$temp"; fi
    echo ""
}

get_gpu_data() {
    current_gpu_w=0; local gpu_found=false
    for card in /sys/class/drm/card[0-9]; do
        for hw_dir in $card/device/hwmon/hwmon*; do
            [ -d "$hw_dir" ] || continue
            local hwpath=""
            [ -f "$hw_dir/power1_average" ] && hwpath="$hw_dir/power1_average"
            [ -z "$hwpath" ] && [ -f "$hw_dir/power1_input" ] && hwpath="$hw_dir/power1_input"
            if [ ! -z "$hwpath" ]; then
                local raw_val=$(cat "$hwpath" 2>/dev/null)
                local g_w_calc=$(echo "scale=2; $raw_val / 1000000" | bc -l)
                local g_w=$(calculate_avg gpu_buffer "$g_w_calc")
                local u_val=$( [ -f "$card/device/gpu_busy_percent" ] && cat "$card/device/gpu_busy_percent" 2>/dev/null || echo "0" )
                local t_val=$( [ -f "$hw_dir/temp1_input" ] && echo "$(cat $hw_dir/temp1_input 2>/dev/null) / 1000" | bc 2>/dev/null || echo "--" )
                local cf_val=$( [ -f "$card/device/pp_dpm_sclk" ] && grep '*' "$card/device/pp_dpm_sclk" 2>/dev/null | awk '{print $2}' | tr -d 'Mhz' || echo "0" )
                local mf_val=$( [ -f "$card/device/pp_dpm_mclk" ] && grep '*' "$card/device/pp_dpm_mclk" 2>/dev/null | awk '{print $2}' | tr -d 'Mhz' || echo "--" )
                local gpu_display_color="$C_GPU"
                if [[ "$t_val" != "--" ]] && (( $(echo "$t_val >= 80" | bc -l) )); then gpu_display_color="\033[1;31m"; fi
                current_gpu_w=$g_w; gpu_found=true
                print_row "RX 580" "$g_w" "$u_val" "$cf_val" "$mf_val" "$t_val" "$gpu_display_color"
                break 2
            fi
        done
    done
    [ "$gpu_found" = false ] && echo -e "  [${C_GPU}GPU${C_RESET}] RX 580 sensors not yet detected..."
    (( $(echo "$current_gpu_w > $MAX_GPU_W" | bc -l) )) && MAX_GPU_W=$current_gpu_w
}

get_cpu_data() {
    current_cpu_w=0
    local pkg_file="/sys/class/powercap/intel-rapl:0/energy_uj"
    local ram_file="/sys/class/powercap/intel-rapl:0:0/energy_uj"
    if [ -f "$pkg_file" ]; then
        local t1=$(cat "$pkg_file" 2>/dev/null); [ -f "$ram_file" ] && local r1=$(cat "$ram_file" 2>/dev/null)
        sleep 0.1
        local t2=$(cat "$pkg_file" 2>/dev/null); [ -f "$ram_file" ] && local r2=$(cat "$ram_file" 2>/dev/null)
        local c_w_raw=$(echo "scale=2; (($t2 - $t1) / 1000000) / 0.1" | bc -l)
        local c_w=$(calculate_avg cpu_buffer "$c_w_raw")
        current_cpu_w=$c_w
        (( $(echo "$c_w > $MAX_CPU_W" | bc -l) )) && MAX_CPU_W=$c_w
        if [ -f "$ram_file" ]; then
            current_ram_w=$(echo "scale=2; (($r2 - $r1) / 1000000) / 0.1" | bc -l)
            (( $(echo "$current_ram_w > $MAX_RAM_W" | bc -l) )) && MAX_RAM_W=$current_ram_w
        fi
        local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
        local cpu_freq=$(grep "cpu MHz" /proc/cpuinfo | head -1 | awk '{print $4}' | cut -d. -f1)
        local c_temp=$(sensors 2>/dev/null | grep -E 'Package id 0:|Core 0:' | head -1 | awk '{print $4}' | sed 's/[^0-9.]//g')
        print_row "CPU" "$c_w" "$cpu_usage" "$cpu_freq" "--" "${c_temp:---}" "$C_CPU"
        printf "  [${C_RAM}%-7s${C_RESET}] ${C_PWR}Pwr:${C_RESET} %-6s W\n" "DRAM" "$current_ram_w"
    fi
}

get_storage_data() {
    current_disk_total_w=0
    local drives=$(lsblk -dno NAME,TYPE 2>/dev/null | grep -E "disk" | grep -vE "usb|loop" | awk '{print $1}')
    local drive_rows_1=(); local drive_rows_2=()
    for drive in $drives; do
        local d_watts=2.0
        current_disk_total_w=$(echo "scale=2; $current_disk_total_w + $d_watts" | bc -l)
        local mount_pt=$(lsblk "/dev/$drive" -lno NAME,MOUNTPOINT,SIZE 2>/dev/null | grep '/' | sort -hr -k3 | head -n 1 | awk '{print $2}')
        local usage="--"; local free="--"
        if [[ "$mount_pt" == /* ]]; then
            usage=$(df -h "$mount_pt" 2>/dev/null | awk 'NR==2 {print $3}')
            free=$(df -h "$mount_pt" 2>/dev/null | awk 'NR==2 {print $4}')
        fi
        local stats=($(grep -w "$drive" /proc/diskstats 2>/dev/null))
        if [ ${#stats[@]} -gt 0 ]; then
            local r_sect=${stats[5]}; local w_sect=${stats[9]}
            local prev_r_var="PREV_R_$drive"; local prev_w_var="PREV_W_$drive"; local prev_t_var="PREV_T_$drive"
            local now=$(date +%s.%N)
            local diff_t=$(echo "$now - ${!prev_t_var:-$now}" | bc -l)
            local read_speed="0B/s"; local write_speed="0B/s"
            if (( $(echo "$diff_t > 0.001" | bc -l) )); then
                local diff_r=$(echo "($r_sect - ${!prev_r_var:-$r_sect}) * 512" | bc)
                local diff_w=$(echo "($w_sect - ${!prev_w_var:-$w_sect}) * 512" | bc)
                read_speed=$(echo "scale=1; ($diff_r / $diff_t) / 1048576" | bc -l | awk '{if ($1 >= 1) printf "%.1fMB/s", $1; else printf "%.1fKB/s", $1*1024}')
                write_speed=$(echo "scale=1; ($diff_w / $diff_t) / 1048576" | bc -l | awk '{if ($1 >= 1) printf "%.1fMB/s", $1; else printf "%.1fKB/s", $1*1024}')
            fi
            printf -v "$prev_r_var" "%s" "$r_sect"; printf -v "$prev_w_var" "%s" "$w_sect"; printf -v "$prev_t_var" "%s" "$now"

            # Compact formatted string
            local row1=$(printf "  [${C_DISK}%-4s${C_RESET}] ${C_PWR}%-3sW${C_RESET}${COL_GAP}${C_USED}Used:${C_RESET}%-5s${COL_GAP}${C_FREE}Free:${C_RESET}%-5s" "$drive" "$d_watts" "$usage" "$free")
            local row2=$(printf "         ${C_LOAD}R:${C_RESET}%-8s${COL_GAP}${C_LOAD}W:${C_RESET}%-8s" "$read_speed" "$write_speed")
            drive_rows_1+=("$row1"); drive_rows_2+=("$row2")
        fi
    done
    # Print in two columns
    local count=${#drive_rows_1[@]}
    for (( i=0; i<count; i+=2 )); do
        echo -e "${drive_rows_1[i]}   |   ${drive_rows_1[i+1]}"
        echo -e "${drive_rows_2[i]}   |   ${drive_rows_2[i+1]}"
    done
}

tput civis
trap "update_peak_log; prune_peaks; tput cnorm; clear; exit" INT TERM
clear

while true; do
    cols=$(tput cols); lines=$(tput lines)
    if [ "$cols" -lt "$MIN_WIDTH" ] || [ "$lines" -lt "$MIN_HEIGHT" ]; then
        tput cup 0 0
        echo "Window too small! Current: ${cols}x${lines} Need: ${MIN_WIDTH}x${MIN_HEIGHT}"
        sleep 1; continue
    fi

    tput cup 0 0
    draw_line "$LINE_MAIN"; center_text "MASTER SYSTEM POWER DASHBOARD"; draw_line "$LINE_MAIN"
    echo -ne "Settings: Idle: ${IDLE_THRESHOLD}W | High: ${HIGH_THRESHOLD}W | Eff-Base: ${EFFICIENCY_BASE}W | Rate: ${REFRESH_RATE}s\n"
    draw_line "$LINE_SEC"

    DISP_RES=$(xrandr 2>/dev/null | grep '*' | awk '{print $1}' | head -n1 || echo "N/A")

    echo -e "${C_TIME}Time:${C_RESET} $(date +%H:%M:%S)${COL_GAP2}${C_UPTIME}Uptime:${C_RESET} $(uptime -p | sed 's/up //')${COL_GAP2}${C_PEAK}Disp:${C_RESET} $DISP_RES"
    echo -e "${C_PEAK}OS:${C_RESET} $OS_NAME${COL_GAP2}${C_PEAK}Kernel:${C_RESET} $KERNEL_V${COL_GAP2}${C_PEAK}Shell:${C_RESET} $SH_NAME"
    echo -e "Press 'b' Benchmark | 'g' GPU | 's' Storage | 'c' CPU"

    if [ "$SHOW_GPU" = true ]; then
        echo -e "${C_SECT}─── GPU STATISTICS $(draw_line "$LINE_SEC" | cut -c20-)${C_RESET}"
        get_gpu_data; echo ""
    fi
    if [ "$SHOW_STORAGE" = true ]; then
        echo -e "${C_SECT}─── STORAGE STATISTICS $(draw_line "$LINE_SEC" | cut -c24-)${C_RESET}"
        get_storage_data;
    fi
    if [ "$SHOW_CPU" = true ]; then
        echo -e "${C_SECT}─── CPU & SYSTEM STATISTICS $(draw_line "$LINE_SEC" | cut -c28-)${C_RESET}"
        get_cpu_data; echo ""
    fi

    total_w=$(echo "scale=2; $current_gpu_w + $current_cpu_w + $current_ram_w + $current_disk_total_w" | bc -l)
    (( $(echo "$total_w > $MAX_COMBINED_W" | bc -l) )) && MAX_COMBINED_W=$total_w

    read -t 0.001 -n 1 key
    if [[ "$key" == "b" ]]; then
        if [ "$BENCH_ACTIVE" = false ]; then
            BENCH_ACTIVE=true; BENCH_START=$(date +%s); BENCH_SUM=0; BENCH_COUNT=0; LAST_BENCH_RES=""
        else BENCH_ACTIVE=false; fi
    elif [[ "$key" == "g" ]]; then
        if [ "$SHOW_GPU" = true ]; then SHOW_GPU=false; else SHOW_GPU=true; fi
    elif [[ "$key" == "s" ]]; then
        if [ "$SHOW_STORAGE" = true ]; then SHOW_STORAGE=false; else SHOW_STORAGE=true; fi
    elif [[ "$key" == "c" ]]; then
        if [ "$SHOW_CPU" = true ]; then SHOW_CPU=false; else SHOW_CPU=true; fi
    fi

    COMBINED_CLR="${CLR_NORM}"
    ALERT_TAG=""
    if (( $(echo "$total_w < $IDLE_THRESHOLD" | bc -l) )); then ALERT_TAG="${CLR_IDLE}[IDLE LOW]${C_RESET}"; COMBINED_CLR="${CLR_IDLE}"
    elif (( $(echo "$total_w > $HIGH_THRESHOLD" | bc -l) )); then ALERT_TAG="${CLR_HIGH}[HIGH LOAD]${C_RESET}"; COMBINED_CLR="${CLR_HIGH}"; fi

    cost_hour=$(echo "scale=4; ($total_w / 1000) * $KWH_COST" | bc -l)

    echo -e "${C_SECT}─── TOTAL REAL-TIME DRAW $(draw_line "$LINE_SEC" | cut -c26-)${C_RESET}"
    printf "  ${COMBINED_CLR}${C_COMBINED}COMBINED:${C_RESET} %-8.2f W${COL_GAP}${C_COST}Cost:${C_RESET} \$%0.4f/hr  %b %b\n" "$total_w" "$cost_hour" "$ALERT_TAG" "$(get_efficiency_rating "$total_w")"

    if [ "$BENCH_ACTIVE" = true ]; then
        BENCH_SUM=$(echo "$BENCH_SUM + $total_w" | bc -l); ((BENCH_COUNT++))
        elapsed=$(( $(date +%s) - BENCH_START ))
        avg_bench=$(echo "scale=2; $BENCH_SUM / $BENCH_COUNT" | bc -l)
        if [ "$elapsed" -ge 60 ]; then
            BENCH_ACTIVE=false; echo -e "\a"
            day_raw=$(echo "scale=6; ($avg_bench / 1000) * $KWH_COST * 24" | bc -l)
            month_raw=$(echo "scale=6; $day_raw * 30" | bc -l)
            year_raw=$(echo "scale=6; $month_raw * 12" | bc -l)
            day_fmt=$(printf "%.2f" "$day_raw")
            month_fmt=$(printf "%.2f" "$month_raw")
            year_fmt=$(printf "%.2f" "$year_raw")
            LAST_BENCH_RES="[$(date +%m-%d\ %H:%M)] Avg: ${avg_bench}W | Day: \$${day_fmt} | Mo: \$${month_fmt} | Yr: \$${year_fmt}"
            echo "$LAST_BENCH_RES" >> "$BENCH_LOG"
        else
            printf "  \033[1;33mBENCHMARKING:\033[0m %ds/60s ${COL_GAP} Avg: %-6s W\n" "$elapsed" "$avg_bench"
        fi
    elif [ ! -z "$LAST_BENCH_RES" ]; then
        echo -e "  \033[1;32mBENCHMARK ANALYSIS:\033[0m $LAST_BENCH_RES"
    else
        printf "\n"
    fi

    echo -e "${C_SECT}─── PEAK POWER SEEN (SESSION) $(draw_line "$LINE_SEC" | cut -c30-)${C_RESET}"
    printf "  ${C_PEAK}CPU:${C_RESET} %-7s W${COL_GAP}${C_PEAK}DRAM:${C_RESET} %-7s W${COL_GAP}${C_PEAK}GPU:${C_RESET} %-7s W${COL_GAP}${C_PEAK}TOTAL:${C_RESET} %-7s W\n" \
        "$MAX_CPU_W" "$MAX_RAM_W" "$MAX_GPU_W" "$MAX_COMBINED_W"
    echo -e "${C_SECT}─── ALL-TIME RECORDS (History) $(draw_line "$LINE_SEC" | cut -c31-)${C_RESET}"
    get_all_time_peaks; draw_line "$LINE_MAIN"
    tput ed

    update_peak_log;
    sleep "$REFRESH_RATE"
done

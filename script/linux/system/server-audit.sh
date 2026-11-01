#!/usr/bin/env bash
# Read-only audit: no installs, sudo prompts, network probes, or automatic fixes.
set -euo pipefail
export LC_ALL=C

case "${1:-}" in
  -h|--help)
    printf 'Usage: bash server-audit.sh [--help]\nRead-only Linux audit. Redirect stdout to save a report.\n'
    exit 0 ;;
  '') ;;
  *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

passed=0 warnings=0 unknown=0
result() {
  local state="$1" title="$2" detail="$3" advice="${4:-}"
  case "$state" in
    OK) passed=$((passed+1)) ;;
    PERHATIAN) warnings=$((warnings+1)) ;;
    BELUM_DICEK) unknown=$((unknown+1)) ;;
  esac
  printf '[%s] %s\n  %s\n' "$state" "$title" "$detail"
  [ -z "$advice" ] || printf '  Saran: %s\n' "$advice"
  return 0
}

progress() {
  if [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] && [ "${WF_ANIMATIONS:-1}" != 0 ]; then
    printf '[%s/7] %s\n' "$1" "$2" >&2
  fi
}

# Bound optional service queries; missing tooling means unknown, never healthy.
probe() {
  command -v timeout >/dev/null 2>&1 && command -v "$1" >/dev/null 2>&1 || return 1
  timeout 5 "$@" 2>/dev/null
}

printf 'WANFORGE - AUDIT SERVER\nWaktu UTC: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
printf 'Mode: hanya baca; tidak mengubah konfigurasi.\n\n'
if [ "$(uname -s)" != Linux ]; then
  result BELUM_DICEK 'Sistem operasi' 'Audit ini memerlukan Linux.' 'Jalankan ./wf audit pada server Linux tujuan.'
  exit 1
fi
progress 1 'Sistem dan resource'
printf 'Host: %s | Kernel: %s\n' "$(hostname 2>/dev/null || echo unknown)" "$(uname -r)"
if [ -r /etc/os-release ]; then
  sed -n 's/^PRETTY_NAME=//p' /etc/os-release
fi

cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
if [ -r /proc/loadavg ] && [[ "$cpu" =~ ^[1-9][0-9]*$ ]]; then
  read -r load _ </proc/loadavg
  if awk -v load="$load" -v cpu="$cpu" 'BEGIN {exit !(load > cpu)}'; then
    result PERHATIAN 'Beban CPU / I/O' "Load 1 menit: $load; CPU logis: $cpu." 'Periksa proses dengan ./wf monitor-system; load juga mencakup proses menunggu I/O.'
  else
    result OK 'Beban CPU / I/O' "Load 1 menit: $load; CPU logis: $cpu."
  fi
else
  result BELUM_DICEK 'Beban CPU / I/O' 'Data load tidak tersedia.'
fi

memory=$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2; found=1} END {if (total>0 && found) printf "%d", (total-available)*100/total}' /proc/meminfo 2>/dev/null || true)
if [[ "$memory" =~ ^[0-9]+$ ]]; then
  if [ "$memory" -ge 90 ]; then
    result PERHATIAN RAM "Terpakai ${memory}% (berdasarkan MemAvailable)." 'Periksa proses boros memori dan kejadian OOM lewat ./wf sys-troubleshoot.'
  else
    result OK RAM "Terpakai ${memory}% (berdasarkan MemAvailable)."
  fi
else
  result BELUM_DICEK RAM 'MemAvailable tidak tersedia.'
fi

progress 2 'Kapasitas disk dan inode'
for kind in disk inode; do
  if [ "$kind" = disk ]; then usage=$(df -P -l 2>/dev/null) || usage=''; else usage=$(df -Pi -l 2>/dev/null) || usage=''; fi
  if [ -z "$usage" ]; then
    result BELUM_DICEK "$kind" 'Data filesystem lokal tidak tersedia.'
    continue
  fi
  entries=$(printf '%s\n' "$usage" | awk 'NR>1 && $5 ~ /^[0-9]+%$/ {print}')
  if [ -z "$entries" ]; then
    result BELUM_DICEK "$kind" 'Filesystem tidak melaporkan persentase pemakaian.'
    continue
  fi
  high=$(printf '%s\n' "$entries" | awk '$5+0 >= 85 {print}')
  if [ -n "$high" ]; then
    result PERHATIAN "$kind" "$high" 'Pemakaian minimal 85%. Periksa log, backup, dan kapasitas sebelum menghapus data.'
  else
    result OK "$kind" 'Filesystem lokal yang melaporkan persentase berada di bawah 85%.'
  fi
done

progress 3 'Layanan gagal'
if services=$(probe systemctl --failed --no-legend --plain --no-pager 2>/dev/null); then
  if [ -n "$services" ]; then
    result PERHATIAN Layanan "$services" 'Periksa ./wf sys-troubleshoot dan log layanan terkait.'
  else
    result OK Layanan 'Tidak ada unit systemd berstatus failed.'
  fi
else
  result BELUM_DICEK Layanan 'systemd tidak tersedia, akses ditolak, timeout hilang, atau pemeriksaan melebihi 5 detik.'
fi

progress 4 'Firewall lokal'
firewall_seen=0
if rules=$(probe ufw status); then
  case "$rules" in
    *'Status: active'*) result INFO Firewall 'UFW aktif; aturan efektif tetap perlu ditinjau.'; firewall_seen=1 ;;
  esac
fi
if [ "$firewall_seen" = 0 ] && rules=$(probe firewall-cmd --state); then
  if [ "$rules" = running ]; then result INFO Firewall 'firewalld aktif; aturan efektif tetap perlu ditinjau.'; firewall_seen=1; fi
fi
if [ "$firewall_seen" = 0 ]; then
  if rules=$(probe nft list ruleset) && [ -n "$rules" ]; then
    result INFO Firewall 'Ruleset nftables ditemukan; keberadaan aturan bukan bukti port terlindungi.'
  elif rules=$(probe iptables -S) && [ -n "$rules" ]; then
    result INFO Firewall 'Aturan iptables ditemukan; periksa policy INPUT dan aturan ACCEPT.'
  else
    result BELUM_DICEK Firewall 'Firewall belum dapat diverifikasi dengan izin dan alat saat ini.' 'Periksa ./wf firewall-manager serta firewall milik provider.'
  fi
fi

progress 5 'Konfigurasi SSH'
# ponytail: global SSH settings only; add sshd -T -C for per-connection audits.
sshd_bin=$(command -v sshd || true)
[ -n "$sshd_bin" ] || sshd_bin=/usr/sbin/sshd
if ssh_config=$(probe "$sshd_bin" -T); then
  for setting in permitrootlogin passwordauthentication; do
    value=$(printf '%s\n' "$ssh_config" | awk -v key="$setting" '$1==key {print $2; exit}')
    case "$value" in
      yes) result PERHATIAN SSH "$setting yes (konfigurasi global)." 'Pastikan login pengguna sudo dengan SSH key berfungsi sebelum mengubah ./wf secure-ssh.' ;;
      no|prohibit-password|without-password|forced-commands-only) result INFO SSH "$setting $value (konfigurasi global; aturan Match dapat berbeda)." ;;
      *) result BELUM_DICEK SSH "Nilai $setting tidak diketahui." ;;
    esac
  done
else
  result BELUM_DICEK SSH 'Konfigurasi efektif tidak terbaca; sshd/timeout mungkin tidak tersedia atau izin kurang.' 'Jalankan audit sebagai root bila perlu; audit tidak meminta sudo otomatis.'
fi

progress 6 'Port yang mendengarkan'
if ports=$(probe ss -H -lntu); then
  if [ -n "$ports" ]; then
    result INFO 'Port lokal (maksimal 20 baris)' "$(printf '%s\n' "$ports" | sed -n '1,20p')" 'Tinjau bind 0.0.0.0/[::] dan port database. Daftar ini tidak membuktikan akses dari internet.'
  else
    result INFO 'Port lokal' 'Tidak ada socket TCP/UDP yang mendengarkan pada namespace ini.'
  fi
else
  result BELUM_DICEK 'Port lokal' 'ss/timeout tidak tersedia, akses ditolak, atau pemeriksaan timeout.'
fi

progress 7 'Ringkasan dan langkah berikutnya'
printf '\nHASIL: %d OK | %d perlu perhatian | %d belum diperiksa\n' "$passed" "$warnings" "$unknown"
printf 'INFO bukan tanda lolos keamanan. Temuan berdasarkan kondisi saat audit.\n'
printf 'Cakupan belum termasuk CVE/pembaruan, firewall provider, aturan SSH Match, atau uji pemulihan backup.\n'
printf 'Berikutnya: ./wf guide untuk konfigurasi; ./wf sys-troubleshoot untuk diagnosis mendalam.\n'

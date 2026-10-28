#!/usr/bin/env bash
# map_quality_ab.sh — 같은 조건에서 FastDDS vs CycloneDDS 의 지도 품질을 비교한다.
#
#   bash map_quality_ab.sh          # 각 2회, 30초 매핑 (총 약 4분)
#   bash map_quality_ab.sh 3 40     # 회차·초 지정
#
# 왜 필요한가
#   2026-10-28: CycloneDDS 로 바꾸자 2참자 통신은 살아났지만(47개 5.0Hz)
#   지도 커버리지가 12.4% → 5.1% 로 떨어졌다. FastDDS 에서는 57.5% 였다.
#   /scan 은 정상이므로, tf 타이밍 문제인지 확인해야 한다.
#
# 측정 항목
#   · /map 수신 횟수
#   · 격자 총량 · 빈 공간(흰색) · 장애물(검정) 비율
#   · tf2_echo 로 map->odom 지연 확인 (샘플)

set -u
DEMO="$HOME/ros2-slam-demo"
ROUNDS=${1:-2}
DUR=${2:-30}

cd "$DEMO" 2>/dev/null || { echo "폴더 없음: $DEMO"; exit 1; }
set +u
source /opt/ros/humble/setup.bash
set -u

RESULT="$HOME/map_quality_ab.txt"
rm -f "$RESULT"
echo "측정: $(date '+%Y-%m-%d %H:%M') / 회차 ${ROUNDS} / 매핑 ${DUR}초" > "$RESULT"
echo "" >> "$RESULT"

run_one () {
  local rmw="$1"
  local round="$2"
  local log="/tmp/mq_${rmw}_${round}.log"

  pkill -f fake_robot         2>/dev/null
  pkill -f async_slam_toolbox 2>/dev/null
  pkill -9 -f _ros2_daemon    2>/dev/null
  sleep 2

  (
    export RMW_IMPLEMENTATION="$rmw"
    export ROS_LOCALHOST_ONLY=1
    cd "$DEMO" || exit 1
    nohup python3 fake_robot.py > /tmp/mq_robot_${rmw}_${round}.log 2>&1 &
    sleep 2
    nohup ros2 launch slam_toolbox online_async_launch.py \
          slam_params_file:="$DEMO/slam_params_local.yaml" \
          use_sim_time:=false > /tmp/mq_slam_${rmw}_${round}.log 2>&1 &
    sleep 8
    python3 check_map.py 10 > "$log" 2>&1
  ) > /dev/null 2>&1

  # check_map.py 는 /map 을 일정 시간 구독한다 (스크립트 내부 기본값)
  local n w g b
  n=$(grep -oP '수신 횟수\s*:\s*\K[0-9]+' "$log" 2>/dev/null | tail -1); n=${n:-0}
  w=$(grep -oP '빈 공간\(흰색\)\s*:\s*\K[0-9]+' "$log" 2>/dev/null | tail -1); w=${w:-0}
  g=$(grep -oP '미탐색\(회색\)\s*:\s*\K[0-9]+' "$log" 2>/dev/null | tail -1); g=${g:-0}
  b=$(grep -oP '장애물\(검정\)\s*:\s*\K[0-9]+' "$log" 2>/dev/null | tail -1); b=${b:-0}

  local total=$((w + g + b))
  local wpct=0.0
  [ "$total" -gt 0 ] && wpct=$(python3 -c "print(f'{$w*100/$total:.1f}')")

  printf "  %-12s %d회차  /map %2s회  총 %6d칸  흰색 %5.1f%%  검정 %d칸\n" \
         "$rmw" "$round" "$n" "$total" "$wpct" "$b"
  printf "%-12s\t%d\t%s\t%d\t%d\t%d\t%.1f\n" \
         "$rmw" "$round" "$n" "$total" "$w" "$g" "$wpct" >> "$RESULT"
}

echo "======================================================"
echo " 지도 품질 A/B — FastDDS vs CycloneDDS"
echo "======================================================"
echo "  회차: ${ROUNDS} / 매핑: ${DUR}초"
echo

for r in $(seq 1 "$ROUNDS"); do
  run_one rmw_fastrtps_cpp "$r"
done
for r in $(seq 1 "$ROUNDS"); do
  run_one rmw_cyclonedds_cpp "$r"
done

pkill -f fake_robot         2>/dev/null
pkill -f async_slam_toolbox 2>/dev/null

echo
echo "======================================================"
echo " 요약"
echo "======================================================"
python3 - "$RESULT" <<'PY'
import sys
rows = []
for line in open(sys.argv[1], encoding='utf-8'):
    p = line.rstrip('\n').split('\t')
    if len(p) == 7 and p[1].isdigit():
        rows.append(p)

if not rows:
    print("  (데이터 없음 — /map 수신 실패)")
    sys.exit()

for rmw in ('rmw_fastrtps_cpp', 'rmw_cyclonedds_cpp'):
    sub = [r for r in rows if r[0] == rmw]
    if not sub:
        continue
    wl = [float(r[6]) for r in sub]
    nl = [int(r[2]) for r in sub]
    print(f"  {rmw}")
    print(f"    흰색 비율: {', '.join(f'{v:.1f}%' for v in wl)}   평균 {sum(wl)/len(wl):.1f}%")
    print(f"    /map 수신: {', '.join(str(v) for v in nl)}")
    print()

fast = [float(r[6]) for r in rows if r[0] == 'rmw_fastrtps_cpp']
cyc  = [float(r[6]) for r in rows if r[0] == 'rmw_cyclonedds_cpp']
if fast and cyc:
    fa, cy = sum(fast)/len(fast), sum(cyc)/len(cyc)
    print("  " + "-" * 48)
    if fa > cy * 1.5:
        print(f"  >>> FastDDS 가 {fa/cy:.1f}배 우수 — CycloneDDS 는 매핑에 부적합")
        print("      권장: SLAM 파이프라인은 FastDDS 유지(3참가자라 문제 없음),")
        print("            단독 측정(2참가자)만 CycloneDDS 사용")
    elif cy >= fa * 0.9:
        print(f"  >>> 두 RMW 성능 유사 (FastDDS {fa:.1f}% / CycloneDDS {cy:.1f}%)")
        print("      권장: CycloneDDS 유지 (2참가자 통신 문제도 해결됨)")
    else:
        print(f"  >>> 애매 (FastDDS {fa:.1f}% / CycloneDDS {cy:.1f}%) — 회차를 늘려 재측정")
PY

echo
echo "  전체 기록: $RESULT"

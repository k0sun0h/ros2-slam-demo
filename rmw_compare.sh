#!/usr/bin/env bash
# rmw_compare.sh — RMW 교체로 "노드 2개면 통신 실패"가 해결되는지 검증한다.
#
#   bash rmw_compare.sh            # 진단 없이 바로 측정
#   bash rmw_compare.sh --install  # CycloneDDS 먼저 설치
#
# 왜 이걸 하나
#   2026-10-27 실측: WSL2 mirrored 환경에서 참가자가 2개(발행+구독)면
#   /scan 이 수신되지 않는다. 3개(로봇+slam_toolbox+구독)면 정상.
#   원리를 못 밝혔으므로, RMW 구현을 바꿔서 증상이 사라지는지 확인한다.
#
# 측정 3개 (각 12초)
#   A. FastDDS  + ROS_LOCALHOST_ONLY=1   ← 현재 기본, 실패할 것
#   B. CycloneDDS + ROS_LOCALHOST_ONLY=1
#   C. CycloneDDS + ROS_LOCALHOST_ONLY 해제
#
# 결과는 ~/rmw_test_result.txt 에도 남는다.

set -u
DEMO="$HOME/ros2-slam-demo"
PROBE="$DEMO/check_scan_v4.py"
LOG="$HOME/rmw_test_result.txt"
DUR=12

[ -d "$DEMO" ] || { echo ">>> 폴더 없음: $DEMO"; exit 1; }
[ -f "$PROBE" ] || { echo ">>> 없음: $PROBE"; exit 1; }

set +u
source /opt/ros/humble/setup.bash
set -u

echo "======================================================"
echo " RMW 비교 — 노드 2개 통신 실패가 사라지는가"
echo "======================================================"
echo

# ---------------------------------------------- 설치 (선택)
if [ "${1:-}" = "--install" ]; then
  echo "---------- CycloneDDS 설치 ----------"
  if dpkg -l | grep -q ros-humble-rmw-cyclonedds-cpp; then
    echo "  이미 설치됨"
  else
    sudo apt install -y ros-humble-rmw-cyclonedds-cpp || {
      echo "  >>> 설치 실패. apt update 후 재시도:"; 
      echo "      sudo apt update && sudo apt install -y ros-humble-rmw-cyclonedds-cpp"
      exit 1
    }
  fi
  echo
fi

# 사용 가능한 RMW 확인
echo "---------- 사용 가능한 RMW ----------"
ls /opt/ros/humble/lib/ 2>/dev/null | grep -E '^librmw_' | sed 's/^/  /' || echo "  (목록 실패)"
CYCLONE_OK=0
if [ -f /opt/ros/humble/lib/librmw_cyclonedds_cpp.so ]; then
  CYCLONE_OK=1
  echo "  → rmw_cyclonedds_cpp 사용 가능"
else
  echo "  → rmw_cyclonedds_cpp 없음 (--install 로 설치하세요)"
fi
echo

# ---------------------------------------------- 측정 함수
run_case () {
  local label="$1"; shift
  local envset="$1"; shift
  local dur="${1:-12}"

  echo "======================================================"
  echo " $label"
  echo "======================================================"

  pkill -f fake_robot         2>/dev/null
  pkill -f async_slam_toolbox 2>/dev/null
  pkill -9 -f _ros2_daemon    2>/dev/null
  sleep 2

  # 환경 변수를 적용해 측정
  (
    eval "$envset"
    echo "  RMW_IMPLEMENTATION = ${RMW_IMPLEMENTATION:-(기본 fastrtps)}"
    echo "  ROS_LOCALHOST_ONLY = ${ROS_LOCALHOST_ONLY:-(없음)}"
    cd "$DEMO" || exit 1
    python3 "$PROBE" "$dur" --spawn > /tmp/rmw_case.log 2>&1
  )

  grep -E "발행자 [0-9]" /tmp/rmw_case.log | tail -3 | sed 's/^/  /'
  local N
  N=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/rmw_case.log | tail -1)
  N=${N:-0}
  echo "  ----------------------------------------"
  echo "  >>> 수신: ${N}개"
  echo
  echo "$N" >> /tmp/rmw_counts.txt
  echo "$label : ${N}개" >> "$LOG"
  sleep 2
}

rm -f "$LOG" /tmp/rmw_counts.txt
echo "측정 시각: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
echo "환경: WSL2 + ROS2 Humble" >> "$LOG"
echo "" >> "$LOG"

# ---------------------------------------------- A. FastDDS (기준)
run_case "A. FastDDS + LOCALHOST_ONLY=1 (현재 기본)" \
         "export RMW_IMPLEMENTATION=rmw_fastrtps_cpp; export ROS_LOCALHOST_ONLY=1" 12
A=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/rmw_case.log | tail -1); A=${A:-0}

# ---------------------------------------------- B. CycloneDDS + LOCALHOST_ONLY
B=0
if [ "$CYCLONE_OK" = "1" ]; then
  run_case "B. CycloneDDS + LOCALHOST_ONLY=1" \
           "export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp; export ROS_LOCALHOST_ONLY=1" 12
  B=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/rmw_case.log | tail -1); B=${B:-0}

  # ---------------------------------------------- C. CycloneDDS, LOCALHOST_ONLY 해제
  run_case "C. CycloneDDS + LOCALHOST_ONLY 해제" \
           "export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp; unset ROS_LOCALHOST_ONLY" 12
  C=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/rmw_case.log | tail -1); C=${C:-0}
else
  C=0
  echo "  (CycloneDDS 없어 B·C 생략)"
  echo
fi

pkill -f fake_robot 2>/dev/null
pkill -f async_slam_toolbox 2>/dev/null

# ---------------------------------------------- 판정
echo "======================================================"
echo " 결과 요약"
echo "======================================================"
echo
printf "  %-42s %s\n" "A. FastDDS    + LOCALHOST_ONLY=1" "${A}개"
printf "  %-42s %s\n" "B. CycloneDDS + LOCALHOST_ONLY=1" "${B}개"
printf "  %-42s %s\n" "C. CycloneDDS + LOCALHOST_ONLY 해제" "${C}개"
echo

{
  echo ""
  echo "결과:"
  echo "  A. FastDDS    + LOCALHOST_ONLY=1 : ${A}개"
  echo "  B. CycloneDDS + LOCALHOST_ONLY=1 : ${B}개"
  echo "  C. CycloneDDS + LOCALHOST_ONLY 해제 : ${C}개"
} >> "$LOG"

echo "======================================================"
if [ "$B" -gt 0 ] || [ "$C" -gt 0 ]; then
  echo " >>> 해결 — CycloneDDS 로 바꾸면 2참가자 통신이 정상"
  echo "======================================================"
  echo
  echo "  영구 적용하려면 ~/.bashrc 에 추가:"
  if [ "$B" -gt 0 ]; then
    echo "    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
    echo "    export ROS_LOCALHOST_ONLY=1"
    echo "  (B 가 성공했으므로 기존 LOCALHOST_ONLY 설정 유지 가능)"
  else
    echo "    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
    echo "    # ROS_LOCALHOST_ONLY 는 주석 처리"
    echo "  (C 만 성공 — LOCALHOST_ONLY 를 끄면 멀티캐스트로 붙는 것으로 보임)"
  fi
else
  echo " >>> CycloneDDS 로도 해결 안 됨"
  echo "======================================================"
  echo
  echo "  붙여줄 것:"
  echo "    cat $LOG"
  echo "    cat /tmp/rmw_case.log"
  echo
  echo "  다음 후보: ROS_DOMAIN_ID 변경, WSL networkingMode 를 NAT 로 되돌리기"
fi
echo
echo "  전체 기록: $LOG"

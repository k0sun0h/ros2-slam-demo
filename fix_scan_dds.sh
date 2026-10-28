#!/usr/bin/env bash
# fix_scan_dds.sh — "/scan 이 발행자도 구독자도 보이는데 데이터가 안 온다" 를 잡는다.
#
# 증상 (2026-10-27 실측)
#   발행자 1 · 구독자 1 · 수신 0개 · 로봇은 계속 살아 있음  → 전송 계층 실패
#
# 원인 후보 1순위: Fast DDS 공유메모리(/dev/shm/fastrtps_*) 잔여 파일
#   pkill -9 로 프로세스를 강제 종료하면 SHM 파일이 남는다.
#   Fast DDS 는 "이미 있는 파일은 덮어쓰지 않는다" 고 문서에 명시한다.
#   그래서 새 프로세스는 발행/구독에 성공(디스커버리는 UDP)하는데
#   실제 데이터(기본값 SHM)는 못 받는다. → 우리 증상과 정확히 일치.
#
# 이 스크립트가 하는 일
#   1) 남은 노드 정리
#   2) /dev/shm 상태 출력 → 잔여 SHM 파일 삭제
#   3) 정리 후 재측정
#   4) 그래도 0개면 SHM 을 끄고(UDP 전용 프로필) 재측정
#
#   bash fix_scan_dds.sh

DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO" 2>/dev/null || { echo "폴더 없음: $DEMO"; exit 1; }

if [ ! -f /opt/ros/humble/setup.bash ]; then
  echo ">>> ROS2 없음"; exit 1
fi
set +u
source /opt/ros/humble/setup.bash
set -u

echo "======================================================"
echo " /scan 전송 진단 + SHM 정리"
echo "======================================================"

echo
echo "---------- 1. 남은 노드 정리 ----------"
pkill -f fake_robot          2>/dev/null
pkill -f async_slam_toolbox  2>/dev/null
pkill -f check_scan          2>/dev/null
pkill -9 -f _ros2_daemon     2>/dev/null
sleep 2
pgrep -af "fake_robot|slam_toolbox|check_scan" || echo "(남은 프로세스 없음)"

echo
echo "---------- 2. /dev/shm 상태 ----------"
df -h /dev/shm | tail -1
SHM_N=$(ls /dev/shm 2>/dev/null | grep -c 'fastrtps' || true)
echo "  fastrtps 관련 파일: ${SHM_N}개"
ls -la /dev/shm 2>/dev/null | grep fastrtps | head -10
if [ "${SHM_N:-0}" -gt 0 ]; then
  echo "  >>> 잔여 SHM 파일 삭제 (프로세스가 모두 죽은 상태라 안전)"
  rm -f /dev/shm/fastrtps_* 2>/dev/null
  rm -f /dev/shm/sem.fastrtps_* 2>/dev/null
  rm -f /dev/shm/fast_datasharing_* 2>/dev/null
  sleep 1
  echo "  삭제 후: $(ls /dev/shm 2>/dev/null | grep -c 'fastrtps' || echo 0)개"
else
  echo "  (잔여 파일 없음 — SHM 원인이 아닐 수 있음)"
fi

echo
echo "---------- 3. 정리 후 재측정 (12초) ----------"
python3 check_scan_v4.py 12 --spawn > /tmp/scan_test1.log 2>&1
grep -E "발행자|수신 [0-9]+개|첫 메시지" /tmp/scan_test1.log | tail -8

N1=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/scan_test1.log | tail -1)
N1=${N1:-0}
echo
echo "  >>> 정리 후 수신: ${N1}개"

if [ "$N1" -gt 0 ]; then
  echo
  echo "======================================================"
  echo " >>> 해결됨 — 원인은 SHM 잔여 파일이었습니다"
  echo "======================================================"
  echo
  echo "  앞으로는 pkill -9 대신 pkill (SIGTERM) 를 쓰고,"
  echo "  비정상 종료 후에는 이 스크립트를 한 번 돌리면 됩니다."
  exit 0
fi

echo
echo "---------- 4. SHM 을 끄고 재측정 (12초) ----------"
if [ ! -f "$DEMO/udp_only.xml" ]; then
  echo "  >>> udp_only.xml 이 없습니다. 같은 폴더에 받아두세요."; exit 1
fi
export FASTRTPS_DEFAULT_PROFILES_FILE="$DEMO/udp_only.xml"
export FASTDDS_DEFAULT_PROFILES_FILE="$DEMO/udp_only.xml"
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
echo "  프로필: $FASTRTPS_DEFAULT_PROFILES_FILE"
python3 check_scan_v4.py 12 --spawn > /tmp/scan_test2.log 2>&1
grep -E "발행자|수신 [0-9]+개|첫 메시지" /tmp/scan_test2.log | tail -8

N2=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/scan_test2.log | tail -1)
N2=${N2:-0}
echo
echo "  >>> UDP 전용 수신: ${N2}개"

echo
echo "======================================================"
if [ "$N2" -gt 0 ]; then
  echo " >>> 해결됨 — SHM 전송이 문제였습니다 (UDP 로 우회 성공)"
  echo "======================================================"
  echo "  ~/.bashrc 에 아래 두 줄을 추가하면 항상 UDP 로 동작합니다:"
  echo "    export FASTRTPS_DEFAULT_PROFILES_FILE=\$HOME/slam_demo/udp_only.xml"
  echo "    export FASTDDS_DEFAULT_PROFILES_FILE=\$HOME/slam_demo/udp_only.xml"
else
  echo " >>> 여전히 0개 — SHM 문제가 아닙니다"
  echo "======================================================"
  echo "  붙여줄 것:"
  echo "    cat /tmp/scan_test2.log"
  echo "    cat /tmp/scan_probe_robot.log"
  echo "  다음 의심: RMW 교체 (sudo apt install ros-humble-rmw-cyclonedds-cpp)"
fi

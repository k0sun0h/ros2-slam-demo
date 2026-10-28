#!/usr/bin/env bash
# isolate_scan.sh — "/scan 데이터가 안 온다" 의 남은 변수 2개를 하나씩 소거한다.
#
# 오늘 관측 정리 (2026-10-27)
#   4b  : slam_toolbox 실행 중 + 로봇 18초 경과 → 49개 수신   (유일한 성공)
#   v2  : 로봇 4초 후 구독 → 0
#   v3  : 구독자 먼저, 로봇 1초 후 → 0  (순서 가설 반증)
#   v4  : 16초 관찰 → 0
#   SHM : /dev/shm 잔여 4개 삭제 후 → 0  (SHM 가설 반증)
#   UDP : SHM 끄고 UDP 전용 → 0
#
# 남은 변수는 두 개뿐이다.
#   (가) 로봇이 충분히 오래 돌아야 하나?      → 1단계: 로봇 20초 대기 후 구독
#   (나) 참가자가 3개 이상 있어야 하나?        → 2단계: slam_toolbox 추가 후 구독
#
#   bash isolate_scan.sh

DEMO="$HOME/slam_demo"
cd "$DEMO" 2>/dev/null || { echo "폴더 없음: $DEMO"; exit 1; }
set +u
source /opt/ros/humble/setup.bash
set -u

PROBE="$DEMO/check_scan_v4.py"
[ -f "$PROBE" ] || PROBE="$DEMO/check_scan_v3.py"
[ -f "$PROBE" ] || { echo ">>> check_scan_v3/v4.py 가 없습니다"; exit 1; }

echo "======================================================"
echo " /scan 전송 진단 — 변수 소거"
echo "======================================================"

echo
echo "---------- 0. 정리 ----------"
pkill -f fake_robot          2>/dev/null
pkill -f async_slam_toolbox  2>/dev/null
pkill -9 -f _ros2_daemon     2>/dev/null
sleep 2
pgrep -af "fake_robot|slam_toolbox" || echo "(깨끗함)"

echo
echo "---------- 0b. /scan QoS ----------"
timeout 12 ros2 topic info /scan --verbose --no-daemon 2>&1 | grep -iE "Type:|Publisher count|Subscription count|Reliability|Durability|History|Depth" | head -14 || \
  echo "  (QoS 를 못 읽음 — ros2 CLI 지연)"

echo
echo "======================================================"
echo " 1단계 — 시간 가설: 로봇을 20초 먼저 돌린 뒤 구독"
echo "======================================================"
nohup python3 fake_robot.py > /tmp/iso_robot.log 2>&1 &
sleep 20
echo "  (로봇 20초 경과)"
python3 "$PROBE" 12 > /tmp/iso_step1.log 2>&1
grep -E "발행자|수신 [0-9]+개|첫 메시지|판정" /tmp/iso_step1.log | tail -8
N1=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/iso_step1.log | tail -1)
N1=${N1:-0}
echo
echo "  >>> 1단계 수신: ${N1}개"

pkill -f fake_robot 2>/dev/null
sleep 2

if [ "$N1" -gt 0 ]; then
  echo
  echo "======================================================"
  echo " >>> 확정: 시간 문제 — 로봇이 20초쯤 돌면 데이터가 흐른다"
  echo "======================================================"
  echo "  대책: 측정 전 로봇을 15~20초 먼저 돌려둔다."
  echo "        (원인: WSL2 mirrored 모드에서 DDS 초기 매칭 지연으로 추정)"
  exit 0
fi

echo
echo "======================================================"
echo " 2단계 — 참가자 가설: slam_toolbox 를 추가로 띄우고 구독"
echo "======================================================"
nohup python3 fake_robot.py > /tmp/iso_robot2.log 2>&1 &
sleep 2
nohup ros2 launch slam_toolbox online_async_launch.py \
      slam_params_file:="$DEMO/slam_params_local.yaml" \
      use_sim_time:=false > /tmp/iso_slam.log 2>&1 &
sleep 10
echo "  (로봇 + slam_toolbox 실행 중)"
python3 "$PROBE" 12 > /tmp/iso_step2.log 2>&1
grep -E "발행자|수신 [0-9]+개|첫 메시지|판정" /tmp/iso_step2.log | tail -8
N2=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/iso_step2.log | tail -1)
N2=${N2:-0}
echo
echo "  >>> 2단계 수신: ${N2}개"

pkill -f fake_robot          2>/dev/null
pkill -f async_slam_toolbox  2>/dev/null
sleep 2
echo "정리 완료"

echo
echo "======================================================"
if [ "$N2" -gt 0 ]; then
  echo " >>> 확정: 참가자 3개 이상 필요 (WSL2 mirrored 특성)"
  echo "======================================================"
  echo "  측정할 때는 slam_toolbox 와 함께 띄우면 정상 수신됩니다."
  echo "  지도 생성에는 영향 없음 (slam_toolbox 는 실제로 스캔을 받고 있었음)."
else
  echo " >>> 둘 다 0개 — 시간·참가자 가설 모두 반증"
  echo "======================================================"
  echo "  붙여줄 것:"
  echo "    cat /tmp/iso_step2.log"
  echo "    cat /tmp/iso_robot2.log"
  echo "    tail -20 /tmp/iso_slam.log"
  echo "  다음: RMW 교체 (sudo apt install ros-humble-rmw-cyclonedds-cpp)"
fi

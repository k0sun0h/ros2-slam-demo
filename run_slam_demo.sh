#!/usr/bin/env bash
# 10/20 SLAM 실습 원클릭 실행  (가짜 로봇 + slam_toolbox)
#
#   사용: bash run_slam_demo.sh [관찰초]
#
# 터미널 3개를 쓸 필요 없이 백그라운드로 띄우고, /map 이 실제로 나오는지 검증한다.
#
# 주의: set -u 를 쓰면 ROS2 setup.bash 가 죽는다 (AMENT_TRACE_SETUP_FILES).
# v2 (2026-10-27): 2단계 /scan 검사를 check_scan.py 직접 구독 방식으로 교체.

OBSERVE="${1:-40}"
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ROBOT=/tmp/slam_robot.log
LOG_SLAM=/tmp/slam_toolbox.log

cd "$DEMO" || { echo "폴더 없음: $DEMO"; exit 1; }

if [ ! -f /opt/ros/humble/setup.bash ]; then
  echo ">>> ROS2 가 없습니다"; exit 1
fi
set +u
source /opt/ros/humble/setup.bash
set -u

if [ ! -f /opt/ros/humble/share/slam_toolbox/package.xml ]; then
  echo ">>> slam_toolbox 가 없습니다. 먼저 설치하세요:"
  echo "    sudo apt install -y ros-humble-slam-toolbox ros-humble-nav2-map-server"
  exit 1
fi

echo "======================================================"
echo " SLAM 데모 (가짜 로봇 + slam_toolbox)"
echo "======================================================"

echo
echo "---------- 0. 정리 ----------"
pkill -f fake_robot           2>/dev/null
pkill -f async_slam_toolbox   2>/dev/null
pkill -9 -f _ros2_daemon      2>/dev/null
sleep 2
pgrep -af "fake_robot|slam_toolbox" || echo "(남은 노드 없음 — 깨끗함)"

echo
echo "---------- 1. 가짜 로봇 시작 ----------"
nohup python3 fake_robot.py > "$LOG_ROBOT" 2>&1 &
sleep 2
tail -3 "$LOG_ROBOT"

echo
echo "---------- 2. /scan 확인 ----------"
# ★ 2026-10-27 수정: ros2 CLI(topic hz)는 WSL2 미러링에서 6초 안에 답을 못 내
#   "안 흐릅니다" 라고 거짓 보고를 했다. 노드와 같은 DDS 로 직접 구독해 센다.
if [ -f "$DEMO/check_scan.py" ]; then
  python3 "$DEMO/check_scan.py" 6 || true
else
  echo "(check_scan.py 없음 — ros2 CLI 로 대체, 결과는 참고만)"
  timeout 8 ros2 topic hz /scan --no-daemon 2>&1 | grep -m1 "average rate" \
    || echo ">>> CLI 로는 확인 실패 (지도 결과로 최종 판단)"
fi

echo
echo "---------- 3. slam_toolbox 시작 ----------"
# ★ use_sim_time:=false 가 핵심 — 기본값이 true 라서, 그대로 두면
#   가짜 시계(/clock)를 영원히 기다리며 스캔을 처리하지 않는다.
nohup ros2 launch slam_toolbox online_async_launch.py \
      slam_params_file:="$DEMO/slam_params_local.yaml" \
      use_sim_time:=false > "$LOG_SLAM" 2>&1 &
sleep 8
tail -15 "$LOG_SLAM"

echo
echo "---------- 4. tf 확인 (slam_toolbox 가 map->odom 을 발행해야 함) ----------"
timeout 6 ros2 run tf2_ros tf2_echo map odom 2>&1 | head -12 \
  || echo ">>> map->odom 이 없습니다 → slam_toolbox 가 아직 활성화되지 않음"

echo
echo "---------- 5. ${OBSERVE}초 관찰 후 /map 검증 ----------"
python3 check_map.py "$OBSERVE" "$DEMO/map_preview.png"
MAP_RC=$?

echo
echo "---------- 6. 정리 ----------"
pkill -f fake_robot           2>/dev/null
pkill -f async_slam_toolbox   2>/dev/null
sleep 2
echo "정리 완료"

echo
echo "======================================================"
if [ "$MAP_RC" = "0" ]; then
  echo " >>> SLAM 지도 생성 성공"
  echo "======================================================"
  echo
  echo "미리보기: $DEMO/map_preview.png"
  echo
  echo "지도 저장 (P gm + yaml):"
  echo "  ros2 run nav2_map_server map_saver_cli -f $DEMO/room"
  echo
  echo "pose-graph 직렬화(이어서 매핑/로컬라이즈용) — 서비스 타입 먼저 확인:"
  echo "  ros2 service list --no-daemon | grep slam_toolbox"
  echo "  ros2 service type /slam_toolbox/serialize_map"
else
  echo " >>> 실패 (코드=$MAP_RC)"
  echo "======================================================"
  echo "붙여줄 것:"
  echo "  tail -20 $LOG_ROBOT"
  echo "  tail -30 $LOG_SLAM"
fi

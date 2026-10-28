#!/usr/bin/env bash
# save_map_demo.sh — SLAM 을 띄운 채로 지도를 '저장'까지 하는 스크립트
#
#   bash save_map_demo.sh            # 90초 매핑 후 저장
#   bash save_map_demo.sh 150        # 관찰시간 지정
#   bash save_map_demo.sh 90 room2   # 저장 이름 지정 (기본 room)
#
# 왜 따로 필요한가
#   run_slam_demo.sh 는 검증이 끝나면 노드를 전부 종료한다.
#   그런데 map_saver_cli 는 slam_toolbox 가 '살아 있는 동안' 에만 지도를 받을 수 있다.
#   그래서 저장용은 이 스크립트로 따로 돌린다.
#
# 저장되는 것
#   ~/slam_demo/<이름>.pgm   격자 그림 (지도)
#   ~/slam_demo/<이름>.yaml  해상도·원점·임계값 (지도 해석 정보)
#
# 주의: set -u 를 쓰면 ROS2 setup.bash 가 죽는다 (AMENT_TRACE_SETUP_FILES).
# v2 (2026-10-27): 2단계 CLI 검사 → 환경 덤프로, /scan 실검사는 4b(check_scan.py)로 이동.

OBSERVE="${1:-90}"
NAME="${2:-room}"
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DEMO/$NAME"
LOG_ROBOT=/tmp/slam_robot.log
LOG_SLAM=/tmp/slam_toolbox.log
LOG_SAVE=/tmp/slam_save.log

cd "$DEMO" 2>/dev/null || { echo "폴더 없음: $DEMO"; exit 1; }

if [ ! -f /opt/ros/humble/setup.bash ]; then
  echo ">>> ROS2 가 없습니다"; exit 1
fi
if [ ! -d /opt/ros/humble/share/slam_toolbox ]; then
  echo ">>> slam_toolbox 가 없습니다. 설치:"
  echo "    sudo apt install -y ros-humble-slam-toolbox ros-humble-nav2-map-server"
  exit 1
fi

set +u
source /opt/ros/humble/setup.bash
set -u

echo "======================================================"
echo " SLAM 지도 저장  (관찰 ${OBSERVE}초 · 이름 ${NAME})"
echo "======================================================"

# ---------------------------------------------- 0. 이전 것 정리
echo
echo "---------- 0. 정리 ----------"
pkill -f fake_robot           2>/dev/null
pkill -f async_slam_toolbox   2>/dev/null
pkill -9 -f _ros2_daemon      2>/dev/null
rm -f "$OUT.pgm" "$OUT.yaml" 2>/dev/null     # 이전 결과 지우기 (새로 만든 건지 확인하려고)
sleep 2
pgrep -af "fake_robot|slam_toolbox" || echo "(남은 노드 없음 — 깨끗함)"

# ---------------------------------------------- 1. 가짜 로봇
echo
echo "---------- 1. 가짜 로봇 시작 ----------"
nohup python3 fake_robot.py > "$LOG_ROBOT" 2>&1 &
ROBOT_PID=$!
sleep 2
tail -3 "$LOG_ROBOT"

# ---------------------------------------------- 2. /scan 확인
echo
echo "---------- 2. 환경 확인 ----------"
# ★ 2026-10-27 수정: ros2 topic hz 는 WSL2 미러링에서 6~8초 안에 답을 못 내
#   "안 흐릅니다" 라고 거짓 보고를 한다(지도는 정상 생성됐다).
#   /scan 실제 수신 검사는 DDS 가 예열된 4b 단계에서 check_scan.py 로 한다.
echo "  ROS_LOCALHOST_ONLY = ${ROS_LOCALHOST_ONLY:-<없음>}"
echo "  ROS_DOMAIN_ID      = ${ROS_DOMAIN_ID:-<없음>}  (없으면 0)"
echo "  RMW_IMPLEMENTATION = ${RMW_IMPLEMENTATION:-<기본: rmw_fastrtps_cpp>}"
pgrep -af fake_robot || echo "  >>> 로봇 프로세스가 없습니다"

# ---------------------------------------------- 3. slam_toolbox
echo
echo "---------- 3. slam_toolbox 시작 ----------"
# ★ use_sim_time:=false — 기본값 true 라서 그대로 두면 /clock 을 영원히 기다린다.
nohup ros2 launch slam_toolbox online_async_launch.py \
      slam_params_file:="$DEMO/slam_params_local.yaml" \
      use_sim_time:=false > "$LOG_SLAM" 2>&1 &
sleep 8
tail -8 "$LOG_SLAM"

# ---------------------------------------------- 4. map->odom tf 확인
echo
echo "---------- 4. map->odom 발행 확인 ----------"
if timeout 8 ros2 run tf2_ros tf2_echo map odom 2>&1 | head -8; then
  :
else
  echo ">>> map->odom 이 없습니다 → slam_toolbox 가 아직 활성화되지 않음"
fi

# ---------------------------------------------- 4b. /scan 실제 수신 (직접 구독)
echo
echo "---------- 4b. /scan 실제 수신 확인 (10초) ----------"
if [ -f "$DEMO/check_scan.py" ]; then
  python3 "$DEMO/check_scan.py" 10 || echo "  (수신 0 — 로봇 로그: tail -20 $LOG_ROBOT)"
else
  echo "  (check_scan.py 없음 — 건너뜀. 지도 결과로 최종 판단)"
fi

# ---------------------------------------------- 5. 매핑될 때까지 기다리기
echo
echo "---------- 5. 매핑 ${OBSERVE}초 진행 ----------"
echo "    (이 동안 로봇이 방을 돌며 /map 이 자랍니다)"
for i in $(seq 1 "$OBSERVE"); do
  if [ $((i % 15)) -eq 0 ]; then
    echo "    ... ${i}초"
  fi
  sleep 1
done

# ---------------------------------------------- 6. 지도 저장
echo
echo "---------- 6. 지도 저장 ----------"
echo "  \$ ros2 run nav2_map_server map_saver_cli -f $OUT"
timeout 60 ros2 run nav2_map_server map_saver_cli -f "$OUT" > "$LOG_SAVE" 2>&1
cat "$LOG_SAVE"

# 첫 시도가 실패하면 timeout 을 늘려서 한 번 더 (지도가 아직 안 왔을 수 있음)
if [ ! -f "$OUT.pgm" ]; then
  echo
  echo "  >>> 첫 시도 실패. 저장 대기시간을 늘려서 재시도합니다."
  echo "  \$ ... map_saver_cli -f $OUT --ros-args -p save_map_timeout:=15.0"
  timeout 60 ros2 run nav2_map_server map_saver_cli -f "$OUT" \
      --ros-args -p save_map_timeout:=15.0 > "$LOG_SAVE" 2>&1
  cat "$LOG_SAVE"
fi

# ---------------------------------------------- 7. 결과 확인
echo
echo "---------- 7. 저장 결과 ----------"
SAVED=0
if [ -f "$OUT.pgm" ] && [ -f "$OUT.yaml" ]; then
  SAVED=1
  ls -la "$OUT.pgm" "$OUT.yaml"
  echo
  echo "--- $NAME.yaml 내용 (지도 해석 정보) ---"
  cat "$OUT.yaml"
else
  echo ">>> .pgm / .yaml 이 안 만들어졌습니다."
  echo "    확인 순서:"
  echo "      1) /map 이 흐르나      python3 check_scan.py 10  (또는 ros2 topic hz /map)"
  echo "      2) map_saver 로그      cat $LOG_SAVE"
  echo "      3) slam_toolbox 로그   tail -20 $LOG_SLAM"
fi

# ---------------------------------------------- 8. pose graph 직렬화 (선택)
echo
echo "---------- 8. pose graph 직렬화 (선택 — 이어서 매핑하려면 필요) ----------"
echo "  서비스 타입 먼저 확인:"
timeout 10 ros2 service list --no-daemon 2>/dev/null | grep slam_toolbox || \
  echo "  (서비스 목록을 못 가져옴 — ros2 CLI 데몬 문제일 수 있음)"
echo
STYPE=$(timeout 10 ros2 service type /slam_toolbox/serialize_map --no-daemon 2>/dev/null)
if [ -n "$STYPE" ]; then
  echo "  타입: $STYPE"
  echo "  \$ ros2 service call /slam_toolbox/serialize_map $STYPE \"{filename: '$OUT'}\""
  timeout 20 ros2 service call /slam_toolbox/serialize_map "$STYPE" \
      "{filename: '$OUT'}" 2>&1 | tail -5
  ls -la "$OUT.posegraph" "$OUT.data" 2>/dev/null || \
    echo "  (posegraph 파일은 안 만들어졌을 수 있음 — 지도 저장(.pgm/.yaml)만으로도 충분)"
else
  echo "  (타입을 못 읽어 건너뜀 — .pgm/.yaml 만으로도 지도는 저장된 것)"
fi

# ---------------------------------------------- 9. 정리
echo
echo "---------- 9. 정리 ----------"
pkill -f fake_robot           2>/dev/null
pkill -f async_slam_toolbox   2>/dev/null
sleep 2
echo "정리 완료"

# ---------------------------------------------- 최종
echo
echo "======================================================"
if [ "$SAVED" = "1" ]; then
  echo " >>> 지도 저장 성공"
  echo "======================================================"
  echo
  echo "  지도    : $OUT.pgm"
  echo "  해석정보: $OUT.yaml"
  echo
  echo "  캡처할 것:"
  echo "    - 위 두 파일이 보이는 ls -la 출력"
  echo "    - $OUT.yaml 내용 (해상도·원점)"
  echo "    - $DEMO/map_preview.png (check_map.py 로 만든 미리보기)"
  echo
  echo "  다음 확인 (선택):"
  echo "    python3 -c \"from PIL import Image; im=Image.open('$OUT.pgm'); print(im.size, im.mode)\""
  echo "    -> 격자 크기(width x height) 가 나오면 정상"
else
  echo " >>> 지도 저장 실패"
  echo "======================================================"
  echo "  붙여줄 것: cat $LOG_SAVE / tail -20 $LOG_SLAM"
fi

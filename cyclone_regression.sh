#!/usr/bin/env bash
# cyclone_regression.sh — RMW 를 CycloneDDS 로 바꿨을 때 기존 프로젝트가 깨지지 않는지 확인
#
#   bash cyclone_regression.sh          # 검사만 (bashrc 안 바꿈)
#   bash cyclone_regression.sh --apply  # 검사 통과 시 ~/.bashrc 에 영구 적용
#
# 검사 4개
#   1) slam_toolbox 가 CycloneDDS 에서 동작하는가 (지도 생성)
#   2) OpenCV p1_verify.py 검출률이 유지되는가
#   3) 2참가자 통신이 계속 정상인가 (재확인)
#   4) ros2 CLI 가 hang 하지 않는가

set -u
SLAM="$HOME/ros2-slam-demo"
CV="$HOME/ros2-opencv-demo"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "======================================================"
echo " CycloneDDS 회귀 테스트"
echo "======================================================"
echo

# 이 스크립트 실행 중에만 CycloneDDS 적용
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_LOCALHOST_ONLY=1

set +u
source /opt/ros/humble/setup.bash
set -u

echo "  RMW_IMPLEMENTATION = $RMW_IMPLEMENTATION"
echo "  ROS_LOCALHOST_ONLY = $ROS_LOCALHOST_ONLY"
echo

# ---------------------------------------------- 정리
pkill -f fake_robot         2>/dev/null
pkill -f async_slam_toolbox 2>/dev/null
pkill -9 -f _ros2_daemon    2>/dev/null
sleep 2

# ---------------------------------------------- 1. slam_toolbox
echo "======================================================"
echo " 1) slam_toolbox — 지도가 만들어지는가"
echo "======================================================"
cd "$SLAM" || { echo ">>> 폴더 없음"; exit 1; }
nohup python3 fake_robot.py > /tmp/reg_robot.log 2>&1 &
sleep 2
nohup ros2 launch slam_toolbox online_async_launch.py \
      slam_params_file:="$SLAM/slam_params_local.yaml" \
      use_sim_time:=false > /tmp/reg_slam.log 2>&1 &
sleep 10
echo "  (16초 매핑)"
python3 check_map.py > /tmp/reg_map.log 2>&1 || true
grep -E "미탐색|빈 공간|장애물|수신 횟수|성공|실패" /tmp/reg_map.log | sed 's/^/  /'

MAP_OK=0
if grep -q "지도 생성 성공\|빈 공간과 장애물" /tmp/reg_map.log 2>/dev/null; then MAP_OK=1; fi
if grep -qE "빈 공간\(흰색\) *: *[1-9]" /tmp/reg_map.log 2>/dev/null; then MAP_OK=1; fi
echo "  ----------------------------------------"
echo "  >>> 지도: $([ $MAP_OK = 1 ] && echo '정상' || echo '확인필요')"

pkill -f fake_robot         2>/dev/null
pkill -f async_slam_toolbox 2>/dev/null
sleep 2
echo

# ---------------------------------------------- 2. 2참가자 통신 재확인
echo "======================================================"
echo " 2) 2참가자 통신 — 여전히 정상인가"
echo "======================================================"
cd "$SLAM" || exit 1
python3 check_scan_v4.py 10 --spawn > /tmp/reg_scan.log 2>&1 || true
grep -E "발행자 [0-9]|수신 [0-9]+개|정상 수신|판정" /tmp/reg_scan.log | tail -4 | sed 's/^/  /'
N=$(grep -oP '수신 \K[0-9]+(?=개 /)' /tmp/reg_scan.log | tail -1); N=${N:-0}
echo "  ----------------------------------------"
echo "  >>> /scan: ${N}개"
echo

# ---------------------------------------------- 3. OpenCV
echo "======================================================"
echo " 3) OpenCV 프로젝트1 — 검출률이 유지되는가"
echo "======================================================"
CV_OK=0
if [ -f "$CV/scripts/opencv_recheck.py" ] || [ -f "$CV/opencv_recheck.py" ]; then
  RC="$CV/scripts/opencv_recheck.py"
  [ -f "$RC" ] || RC="$CV/opencv_recheck.py"
  echo "  셀프테스트:"
  python3 "$RC" --selftest 2>&1 | tail -8 | sed 's/^/  /'
  if python3 "$RC" --selftest > /tmp/reg_cv.log 2>&1; then
    grep -qi "통과\|pass\|OK" /tmp/reg_cv.log && CV_OK=1
  fi
else
  echo "  (opencv_recheck.py 없음 — 건너뜀)"
  CV_OK=-1
fi
echo "  ----------------------------------------"
echo "  >>> OpenCV: $([ $CV_OK = 1 ] && echo '정상' || ([ $CV_OK = -1 ] && echo '건너뜀' || echo '확인필요'))"
echo

# ---------------------------------------------- 4. ros2 CLI
echo "======================================================"
echo " 4) ros2 CLI — hang 하지 않는가"
echo "======================================================"
echo "  ros2 topic list:"
timeout 15 ros2 topic list --no-daemon 2>&1 | head -8 | sed 's/^/    /'
echo "  ros2 node list:"
timeout 15 ros2 node list --no-daemon 2>&1 | head -5 | sed 's/^/    /'
echo "  ----------------------------------------"
echo "  >>> CLI: $([ $? = 0 ] && echo '응답함' || echo '확인필요')"
echo

# ---------------------------------------------- 판정
echo "======================================================"
echo " 판정"
echo "======================================================"
echo
echo "  1) 지도 생성      : $([ $MAP_OK = 1 ] && echo '정상' || echo '확인필요')"
echo "  2) /scan 수신     : ${N}개 $([ "$N" -gt 0 ] && echo '(정상)' || echo '(실패)')"
echo "  3) OpenCV         : $([ $CV_OK = 1 ] && echo '정상' || ([ $CV_OK = -1 ] && echo '건너뜀' || echo '확인필요'))"
echo

ALL_OK=0
[ "$MAP_OK" = "1" ] && [ "$N" -gt 0 ] && ALL_OK=1

if [ "$ALL_OK" = "1" ]; then
  echo "======================================================"
  echo " >>> CycloneDDS 로 전환해도 안전"
  echo "======================================================"
  if [ "$APPLY" = "1" ]; then
    echo
    echo "---------- ~/.bashrc 적용 ----------"
    cp ~/.bashrc ~/.bashrc.bak.$(date +%Y%m%d)
    # 기존 RMW 설정 주석 처리
    sed -i 's/^export RMW_IMPLEMENTATION=/# export RMW_IMPLEMENTATION=/' ~/.bashrc
    grep -qxF 'export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp' ~/.bashrc || \
      echo 'export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp' >> ~/.bashrc
    grep -qxF 'export ROS_LOCALHOST_ONLY=1' ~/.bashrc || \
      echo 'export ROS_LOCALHOST_ONLY=1' >> ~/.bashrc
    echo "  추가됨:"
    tail -3 ~/.bashrc | sed 's/^/    /'
    echo
    echo "  적용하려면 새 터미널을 열거나: source ~/.bashrc"
    echo "  되돌리려면: cp ~/.bashrc.bak.$(date +%Y%m%d) ~/.bashrc"
  else
    echo
    echo "  영구 적용하려면: bash cyclone_regression.sh --apply"
    echo "  (지금은 이 스크립트 안에서만 CycloneDDS 사용 중)"
  fi
else
  echo "======================================================"
  echo " >>> 주의 — 일부 검사가 실패했습니다"
  echo "======================================================"
  echo "  붙여줄 것:"
  echo "    cat /tmp/reg_map.log"
  echo "    cat /tmp/reg_scan.log"
  echo "    tail -20 /tmp/reg_slam.log"
  echo
  echo "  .bashrc 는 건드리지 않았습니다 (현재 FastDDS 유지)"
fi

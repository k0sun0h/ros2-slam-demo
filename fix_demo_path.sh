#!/usr/bin/env bash
# fix_demo_path.sh — 스크립트들이 자기 폴더를 기준으로 동작하게 고친다.
#
#   bash fix_demo_path.sh          # 미리보기
#   bash fix_demo_path.sh --run    # 실제 수정 + 커밋
#
# 문제 (2026-10-28 발견)
#   ros2-slam-demo 로 옮겼는데 run_slam_demo.sh 등이
#   DEMO="$HOME/slam_demo" 로 하드코딩돼 있어 옛 폴더 파일을 썼다.
#   → 스크립트가 어디 있든 그 폴더의 파일을 쓰도록 바꾼다.

set -u
REPO="$HOME/ros2-slam-demo"
RUN=0
[ "${1:-}" = "--run" ] && RUN=1
cd "$REPO" 2>/dev/null || { echo ">>> 저장소 없음: $REPO"; exit 1; }

TARGETS="run_slam_demo.sh save_map_demo_v2.sh check_scan_v4.py isolate_scan.sh fix_scan_dds.sh"

echo "======================================================"
echo " DEMO 경로 수정  ($([ $RUN = 1 ] && echo 실행 || echo 미리보기))"
echo "======================================================"
echo
echo "  대상 파일과 현재 경로 설정:"
for f in $TARGETS; do
  [ -f "$f" ] || { printf "  %-24s (없음)\n" "$f"; continue; }
  line=$(grep -nE '^(DEMO=|DEMO =)' "$f" | head -1)
  printf "  %-24s %s\n" "$f" "${line:-（경로 설정 없음）}"
done
echo
echo "  변경 후: 스크립트 자신의 폴더를 쓴다 (어디서 실행해도 동일)"
echo

if [ "$RUN" = "0" ]; then
  echo ">>> 진행하려면: bash fix_demo_path.sh --run"
  exit 0
fi

echo "---------- 백업 ----------"
mkdir -p /tmp/demo_path_bak
for f in $TARGETS; do
  [ -f "$f" ] && cp "$f" "/tmp/demo_path_bak/$f.$(date +%s)" 2>/dev/null
done
echo "  /tmp/demo_path_bak 에 저장"

echo
echo "---------- 수정 ----------"
for f in $TARGETS; do
  [ -f "$f" ] || continue
  if grep -q 'DEMO="\$HOME/slam_demo"' "$f" 2>/dev/null; then
    # bash 스크립트: 스크립트 위치 기준
    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = 'DEMO="$HOME/slam_demo"'
new = 'DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
if old in s:
    s = s.replace(old, new)
    open(p, 'w', encoding='utf-8').write(s)
    print(f'  수정: {p}')
else:
    print(f'  건너뜀: {p}')
PY
  elif grep -q 'os.path.expanduser' "$f" 2>/dev/null; then
    # python 스크립트: __file__ 기준
    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
marker = "os.path.join(os.path.expanduser('~'), 'slam_demo')"
alt    = "os.path.join(os.path.expanduser('~'), 'ros2-slam-demo')"
changed = False
if marker in s:
    s = s.replace(marker, "os.path.dirname(os.path.abspath(__file__))")
    changed = True
if alt in s:
    s = s.replace(alt, "os.path.dirname(os.path.abspath(__file__))")
    changed = True
if changed:
    open(p, 'w', encoding='utf-8').write(s)
    print(f'  수정: {p}')
else:
    print(f'  해당없음: {p}')
PY
  else
    echo "  해당없음: $f"
  fi
done

echo
echo "---------- 문법 검사 ----------"
for f in $TARGETS; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) bash -n "$f" && echo "  OK   $f" || echo "  FAIL $f" ;;
    *.py) python3 -m py_compile "$f" && echo "  OK   $f" || echo "  FAIL $f" ;;
  esac
done

echo
echo "---------- 결과 확인 ----------"
for f in $TARGETS; do
  [ -f "$f" ] || continue
  grep -nE '^(DEMO=|DEMO =|.*dirname)' "$f" | head -2 | sed "s|^|  $f: |"
done

echo
echo "---------- 커밋 ----------"
git add -A
git status --short
git commit -q -m "fix: 스크립트가 저장소 위치 기준으로 동작하도록 경로 수정

- DEMO=\"\$HOME/slam_demo\" 하드코딩 → 스크립트 자신의 폴더 기준
- ros2-slam-demo 로 옮긴 뒤에도 옛 폴더(~/slam_demo)를 읽던 문제 해결
- 대상: run_slam_demo.sh, save_map_demo_v2.sh, check_scan_v4.py,
        isolate_scan.sh, fix_scan_dds.sh" || echo "  (커밋할 변경 없음)"

echo
echo "======================================================"
echo " 완료"
echo "======================================================"
git log --oneline -2
echo
echo "  push: git push origin main"
echo "  되돌리기: cp /tmp/demo_path_bak/<파일>.* ."

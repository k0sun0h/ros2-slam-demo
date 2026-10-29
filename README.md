# slam_demo — 가짜 로봇 + slam_toolbox 2D 매핑

라이다 스캔만으로 **처음 보는 방의 지도를 그리는** 최소 예제.
실제 로봇 없이 `fake_robot.py` 가 방(8×6m)을 돌며 `/scan` 을 발행하고,
`slam_toolbox` 가 그 스캔을 이어 붙여 격자 지도(`/map`)를 만든다.

```
[fake_robot.py]  --/scan (LaserScan, 360빔 5Hz)-->  [slam_toolbox]
   방 8x6m, 기둥 2개, 3바퀴 주행                        online_async
   odom->base_link tf (일부러 3% 오차)                        |
   base_link->base_laser tf_static                      /map (OccupancyGrid)
                                                             |
                                                    [map_saver_cli]
                                                             |
                                                    room.pgm + room.yaml
```

| 토픽 / tf | 타입 | 방향 |
|---|---|---|
| `/scan` | `sensor_msgs/LaserScan` | 발행 (360빔, 5Hz, 0.05~12m) |
| `/map` | `nav_msgs/OccupancyGrid` | 발행 (2초마다) |
| `odom → base_link` | `tf2` | 발행 (일부러 3% 거리 과대 + 요 편향) |
| `map → odom` | `tf2` | 발행 (slam_toolbox 가 보정) |

## 요구사항

| 항목 | 값 |
|---|---|
| OS | WSL2 Ubuntu 22.04 |
| ROS2 | Humble |
| 패키지 | `ros-humble-slam-toolbox` (2.6.10), `ros-humble-nav2-map-server` (1.1.20) |
| Python | `rclpy`, `PIL` (Pillow) |

설치:

```bash
sudo apt install -y ros-humble-slam-toolbox ros-humble-nav2-map-server
```

## 실행

### 1) 20초 검증 — 파이프라인이 도는지만 확인

```bash
bash run_slam_demo.sh 20
```

마지막에 `>>> SLAM 지도 생성 성공` 이 나오면 정상.
`/map` 수신 10회, 격자 192×168 정도가 나온다.

### 2) 60초 매핑 — 지도가 어떻게 자라는지 관찰

```bash
bash run_slam_demo.sh 60
python3 check_map.py          # 통계 + map_preview.png 생성
```

### 3) 90초 + 지도 저장 — 결과물을 파일로 남긴다

```bash
bash save_map_demo_v2.sh 90 room
```

`room.pgm`(격자 그림)과 `room.yaml`(해석 정보)이 생긴다.

> `run_slam_demo.sh` 는 검증이 끝나면 노드를 전부 종료한다.
> 그런데 `map_saver_cli` 는 slam_toolbox 가 **살아 있는 동안**에만 지도를 받을 수 있다.
> 그래서 저장용은 `save_map_demo_v2.sh` 로 따로 돌린다.

## 저장 결과 (10/27 실측)

| 항목 | 값 |
|---|---|
| `room.pgm` | 30,822 bytes · **189 × 163 격자** |
| `room.yaml` | 121 bytes |
| resolution | **0.05 m/격자** (5cm) |
| origin | `[-1.13, -1.1, 0]` |
| mode | `trinary` (회색/흰색/검정 3종) |
| occupied_thresh / free_thresh | 0.65 / 0.25 |
| 실면적 | 9.45 × 8.15 m |

픽셀 분포 (실측):

| 값 | 의미 | 칸 수 | 비율 |
|---|---|---|---|
| `0` | 장애물 (벽·기둥) | 975 | 3.16% |
| `205` | 미탐색 | 11,275 | 36.60% |
| `254` | 빈 공간 | 18,557 | 60.24% |
| 합계 | | **30,807** | = 189×163 |

흰색 18,557칸 ÷ 방 안쪽 19,200칸 = **96.65%** — 방을 사실상 다 그렸다.

```bash
# 픽셀 분포 직접 확인
python3 -c "from PIL import Image; import collections; \
im=Image.open('room.pgm'); print(im.size, im.mode); \
print(sorted(collections.Counter(im.getdata()).items()))"
```

## 파라미터 — 기본값에서 바꾼 것 4개

`slam_params_local.yaml` 은 upstream 기본 설정에서 4개만 바꿨다.

| 파라미터 | 기본값 | 이 파일 | 이유 |
|---|---|---|---|
| `base_frame` | `base_footprint` | `base_link` | tf 트리에 `base_footprint` 가 없어서 |
| `max_laser_range` | 20.0 | 12.0 | 가짜 라이다 사거리와 일치 |
| `map_update_interval` | 5.0 | 2.0 | 지도 갱신을 눈으로 빨리 보려고 |
| `minimum_travel_distance` | 0.5 | 0.3 | 작은 방에서 노드를 촘촘히 |

## 파라미터 — 실제로 지도에 영향을 주는 8개

| 파라미터 | 값 | 하는 일 |
|---|---|---|
| `mode` | `mapping` | 새 지도 그리기(`mapping`) vs 기존 지도에서 위치 찾기(`localization`) |
| `resolution` | 0.05 | 격자 한 칸 크기(m). 0.05 = 5cm → 8×6m 방이 160×120칸 |
| `map_update_interval` | 2.0 | 몇 초마다 `/map` 을 발행할지. 20초에 10회, 60초에 30회 |
| `transform_publish_period` | 0.02 | `map→odom` tf 주기 (50Hz). **0 이면 tf 를 아예 발행하지 않는다** |
| `minimum_travel_distance` | 0.3 | 0.3m 이동할 때마다 지도에 노드(기준점)를 만든다 |
| `minimum_travel_heading` | 0.3 | 0.3rad(약 17도) 회전할 때마다 노드를 만든다 |
| `use_scan_matching` | `true` | **odom 오차를 지도가 스스로 보정한다** |
| `do_loop_closing` | `true` | 왔던 곳 재방문 시 전체 지도를 재정렬 (CeresSolver 가 담당) |
| `max_laser_range` | 12.0 | 이 거리 밖 스캔은 무시. 센서 사거리보다 크게 두면 없는 벽을 그린다 |

`use_scan_matching: true` 가 핵심이다. `fake_robot.py` 는 일부러 거리 3% 과대와
요 편향을 주입하는데, 지도가 정상으로 나오는 이유가 이 값이다.
`false` 로 두면 벽이 두 겹으로 겹쳐 보인다.

## 실험 결론

### 1) 경로가 지도를 결정한다 — 시간이 아니다

20초 / 60초 / 90초 세 회차를 같은 방에서 돌린 결과:

| 회차 | 격자 총량 | 흰색(빈 공간) | 회색(미탐색) |
|---|---|---|---|
| 20초 | 32,256 (192×168) | **18,556** | 12,791 |
| 60초 | 37,400 (200×187) | **18,555** | 17,864 |
| 90초 | 30,807 (189×163) | **18,557** | 11,275 |

흰색이 18,556 ± 1칸 — 세 번 다 같다. 회색(미탐색)은 12,791 → 17,864 → 11,275 로
크게 달라지지만, 이는 지도 경계 상자 크기가 달라진 결과다.

- 격자 총량 감소: 37,400 → 30,807 = −6,593칸
- 미탐색 감소: 17,864 → 11,275 = −6,589칸

두 숫자가 거의 같다. **실제로 그린 면적은 세 번 모두 동일하다.**
레이저가 360빔에 사거리 12m 이고 방 대각선이 약 10m 라서, 방 안 어디에 있든
방 전체가 한 번에 보이기 때문이다.

→ 볼록한 방에서는 오래 돌려도 커버리지가 늘지 않는다.
→ 복도·다중 방처럼 가려진 곳이 생기는 공간에서는 시간이 곧 커버리지가 된다.
→ **볼록한가 아닌가가 갈림길이다.**

### 2) 노드 2개 구성은 이 환경에서 통신이 깨진다 (WSL2 mirrored)

`/scan` 이 안 보이는 원인을 찾느라 8회 측정했다.

| # | 구성 | 발행자 | 결과 |
|---|---|---|---|
| 1 | 로봇 + slam_toolbox + 구독자 | 1 | **61개 수신 (5.0Hz)** |
| 2 | 로봇 → 4초 뒤 구독자 (2개) | 1 | 0개 |
| 3 | 구독자 → 1초 뒤 로봇 (2개) | 1 | 0개 |
| 4 | 로봇 20초 먼저 → 구독자 (2개) | **0** | 0개 |
| 5 | `/dev/shm` fastrtps 파일 4개 삭제 후 | 1 | 0개 |
| 6 | SHM 끄고 UDP 전용 프로필 | 1 | 0개 |
| 7 | 로봇 + slam_toolbox + 구독자 | 1 | **61개 수신** |

성공한 두 번은 모두 참가자 3개, 실패한 다섯 번은 모두 2개였다.
실패 양상도 두 가지로 갈린다 — 발행자가 아예 안 보이는 경우(#4)와
발행자는 보이는데 데이터가 안 오는 경우(#2,#3,#5,#6).

반증된 가설: 측정 순서 문제, `/dev/shm` 잔여 파일, SHM 전송 자체, 로봇 예열 시간,
중복 배달로 인한 6.2Hz 오독. **원리까지는 규명하지 못했다** — 상관관계는 2회
재현됐지만 메커니즘은 가설 단계다.

→ 실용 규칙: **측정할 때는 파이프라인 전체를 띄운 상태에서 한다.**
→ "노드를 띄웠는데 데이터가 안 온다"면 코드보다 참가자 수를 먼저 센다.

### 3) 측정 도구를 의심하라

`ros2 topic hz /scan` 은 WSL2 에서 DDS 디스커버리가 느려 6~8초 안에 답을 못 낸다.
그런데 스크립트가 이를 실패로 처리해 "안 흐릅니다" 라고 **거짓 보고**를 했다.
같은 시점에 지도는 정상으로 만들어지고 있었다.

→ `ros2` CLI 를 안 거치고 노드와 같은 DDS 로 직접 구독하면 정확하다
(`check_scan_v4.py`).
→ 발행자/구독자 수를 함께 찍어야 **탐색 실패**와 **전송 실패**를 구분할 수 있다.

## 실험: RMW(DDS) 교체가 지도 품질을 망친 건

같은 스크립트·같은 30초·같은 파라미터로 DDS 구현만 바꿔 측정했다.

### 1) 통신 성공 여부

| 조건 | `/scan` 수신 | 실효 주기 |
|---|---|---|
| A. FastDDS + `ROS_LOCALHOST_ONLY=1` | **0개** | — |
| B. CycloneDDS + `ROS_LOCALHOST_ONLY=1` | 57개 | 4.75 Hz |
| C. CycloneDDS + localhost 해제 | 58개 | 4.83 Hz |

같은 `ROS_LOCALHOST_ONLY=1` 조건에서 DDS만 바꿨더니 0개 → 57개. 이 시점에 "CycloneDDS가 낫다"고 판단할 뻔했다. 틀렸다.

원인은 **참가자(participant) 수**였다. 참가자 3개일 때 47~61개가 정상 수신되고, 2개일 때 0개가 된다. 6가지 가설(CLI 종류, 실행 순서, SHM 잔여물, UDP 전용 강제, 20초 대기, 중복 배달)을 세워 하나씩 반증했고 전부 아니었다.

### 2) 그런데 지도는 반대로 나왔다

| 조건 | 회차 | 흰색(빈 공간) | 검정(점유) |
|---|---|---|---|
| FastDDS | 1 | **55.6%** | 740 |
| FastDDS | 2 | **55.6%** | 724 |
| CycloneDDS | 1 | **5.1%** | 71 |
| CycloneDDS | 2 | **5.1%** | 71 |

**빈 공간 비율이 10.9배 차이**난다. CycloneDDS 쪽은 16초·20초·30초를 각각 돌려도 5.1%가 4회 재현됐고, 격자 크기 25,454가 매번 동일했다. 지도가 특정 시점 이후 **갱신을 멈춘 것**으로 보이는데, 원리는 규명하지 못했다.

### 3) 결론과 되돌리기

`ros2 topic hz`로 "통신이 되네"를 확인하는 것과 "지도가 제대로 그려지네"는 완전히 다른 문제다. 통신 지표만 보고 DDS를 바꾸면 지도가 조용히 망가진다. 그래서 **FastDDS로 되돌렸다.**

- `cp ~/.bashrc.bak.20261028 ~/.bashrc` 로 백업 복원, `echo $RMW_IMPLEMENTATION` 이 빈 값임을 확인
- 복원 후 재검증: **191x167, 흰색 18,553칸(58.2%), 검정 905칸(2.8%), `/map` 10회 수신** — 10/27 측정값(57.5% / 909칸)과 3~4칸 차이로 일치

CycloneDDS는 이제 **단독 측정(참가자 2개 환경)을 할 때만, 그 명령에 한해서** 쓴다. `.bashrc`에 상시로 넣지 않는다.

### 재현

    ./rmw_compare.sh          # A/B/C 통신량 비교
    ./map_quality_ab.sh       # 같은 조건으로 지도 품질 비교 (각 2회)
    ./cyclone_regression.sh   # CycloneDDS 5.1% 재현 확인

---

## 함정

| 함정 | 증상 | 대응 |
|---|---|---|
| `use_sim_time` 기본값이 `true` | `/clock` 이 없어 slam_toolbox 가 스캔을 처리하지 않음 | launch 에서 `use_sim_time:=false` |
| `set -u` + `source setup.bash` | `AMENT_TRACE_SETUP_FILES: unbound variable` 즉사 | `set +u` 로 감싼 뒤 source |
| `ros2` CLI 데몬 hang | `ros2 topic list` 등이 멈춤 | `--no-daemon` 붙이기 |
| 노드 2개 구성 | 발행자는 보이는데 수신 0 | 파이프라인 전체를 띄우고 측정 |
| `map_saver_cli` 가 지도를 못 받음 | `.pgm` 미생성 | slam_toolbox 살아 있는 동안 실행, `save_map_timeout:=15.0` |

## 파일

| 경로 | 역할 |
|---|---|
| `fake_robot.py` | 가짜 로봇 — 방 8×6m 주행, `/scan` 5Hz, odom 오차 주입 |
| `slam_params_local.yaml` | slam_toolbox 설정 (기본값에서 4개 변경) |
| `run_slam_demo.sh` | 20/60초 실행 + 검증 (끝나면 노드 정리) |
| `save_map_demo_v2.sh` | 90초 매핑 + 지도 저장 (`.pgm`/`.yaml`) |
| `check_map.py` | `/map` 통계 + `map_preview.png` 생성 |
| `check_scan_v4.py` | `/scan` 수신 진단 (발행자/구독자 수 포함) |
| `isolate_scan.sh` | 통신 실패 원인 소거 (시간·참가자 수 가설) |
| `fix_scan_dds.sh` | `/dev/shm` 잔여 파일 정리 + UDP 전용 재측정 |
| `udp_only.xml` | SHM 을 끄고 UDPv4 만 쓰는 Fast DDS 프로필 |
| `room.pgm` / `room.yaml` | 저장된 지도 결과물 |

## 다음 단계

- RMW 를 CycloneDDS 로 교체해 2참가자 통신이 정상화되는지 확인
- pose graph 직렬화(`/slam_toolbox/serialize_map`) — 이어서 매핑·로컬라이즈에 필요
- LIO-SAM · FAST-LIO 비교 (3D LiDAR SLAM)

#!/usr/bin/env python3
"""지도(/map)를 받아서 통계를 찍고 PNG 로 저장한다.

rviz 없이도 SLAM 결과를 '눈으로' 확인하기 위한 도구다.
(OccupancyGrid: -1=미탐색, 0=빈공간, 100=장애물)

사용법:
    source /opt/ros/humble/setup.bash
    python3 check_map.py                    # 15초 관찰 후 PNG 저장
    python3 check_map.py 25 out_room.png    # 관찰시간 / 저장경로 지정
"""
import math
import sys

import rclpy
from nav_msgs.msg import OccupancyGrid
from rclpy.node import Node


class MapCheck(Node):
    def __init__(self):
        super().__init__('map_check')
        self.last = None
        self.count = 0
        self.create_subscription(OccupancyGrid, '/map', self.on_map, 10)

    def on_map(self, msg):
        self.count += 1
        self.last = msg


def render(msg, path):
    """OccupancyGrid -> PNG (PIL). 위아래를 뒤집는다(원점이 왼쪽 아래)."""
    try:
        from PIL import Image
    except ImportError:
        print('PIL 이 없어 PNG 저장을 건너뜁니다 (sudo apt install python3-pil)')
        return False

    w, h = msg.info.width, msg.info.height
    r = msg.info.resolution
    px = bytearray()
    for y in range(h - 1, -1, -1):           # 위에서 아래로
        for x in range(w):
            v = msg.data[y * w + x]
            if v < 0:
                px += b'\x80\x80\x80'        # 미탐색 = 회색
            else:
                g = int(255 - (v / 100.0) * 255)
                px += bytes((g, g, g))       # 점유 = 검정
    img = Image.frombytes('RGB', (w, h), bytes(px))
    img = img.resize((w * 4, h * 4), Image.NEAREST)
    img.save(path)
    print(f'PNG 저장: {path}  ({w}x{h} 격자, {r} m/격자 → 실면적 '
          f'{w * r:.1f} x {h * r:.1f} m)')
    return True


def main():
    duration = float(sys.argv[1]) if len(sys.argv) > 1 else 15.0
    out_path = sys.argv[2] if len(sys.argv) > 2 else 'map_preview.png'

    rclpy.init(args=[])
    node = MapCheck()
    print(f'{duration:.0f}초 동안 /map 을 구독합니다...')

    import time
    end = time.time() + duration
    while time.time() < end:
        rclpy.spin_once(node, timeout_sec=0.1)

    print()
    print('=' * 54)
    print(' /map 결과')
    print('=' * 54)

    if node.last is None:
        print('>>> /map 메시지를 한 번도 못 받았습니다')
        print('    확인 순서:')
        print('      1) slam_toolbox 가 떴나      → ros2 node list --no-daemon')
        print('      2) /scan 이 흐르나            → ros2 topic hz /scan')
        print('      3) tf odom->base_link 있나    → ros2 run tf2_ros tf2_echo odom base_link')
        print('      4) use_sim_time 이 false 인가 (가짜 시계를 기다리면 영원히 대기)')
        rclpy.shutdown()
        return 1

    m = node.last
    total = m.info.width * m.info.height
    unknown = sum(1 for v in m.data if v < 0)
    occupied = sum(1 for v in m.data if v >= 50)
    free = total - unknown - occupied

    print(f'/map 수신 횟수   : {node.count}회')
    print(f'격자 크기        : {m.info.width} x {m.info.height} '
          f'({m.info.resolution} m/격자)')
    print(f'원점(좌하단)     : ({m.info.origin.position.x:.2f}, '
          f'{m.info.origin.position.y:.2f})')
    print(f'실제 크기        : {m.info.width * m.info.resolution:.1f} x '
          f'{m.info.height * m.info.resolution:.1f} m')
    print()
    print(f'미탐색(회색)     : {unknown:>7} 격자 ({100.0 * unknown / total:5.1f} %)')
    print(f'빈 공간(흰색)    : {free:>7} 격자 ({100.0 * free / total:5.1f} %)')
    print(f'장애물(검정)     : {occupied:>7} 격자 ({100.0 * occupied / total:5.1f} %)')
    print()

    ok = occupied > 0 and free > 0
    if ok:
        print('>>> 지도 생성 성공 (빈 공간과 장애물이 모두 있음)')
    else:
        print('>>> 지도가 비어 있음 — 로봇이 안 움직였거나 스캔이 안 들어옴')

    render(m, out_path)

    rclpy.shutdown()
    return 0 if ok else 2


if __name__ == '__main__':
    sys.exit(main())

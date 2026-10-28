#!/usr/bin/env python3
"""check_scan_v4.py — '/scan 이 안 보인다'를 '탐색 실패'와 '전송 실패'로 갈라낸다.

v1~v3 는 모두 "수신 0개" 라는 결과만 줬다. 그런데 0개가 나오는 원인은 두 가지로
완전히 다르다.

  (A) 탐색(discovery) 실패 — 구독자가 발행자의 존재 자체를 모른다.
      진단: count_publishers('/scan') == 0
      처방: DDS 설정 · ROS_LOCALHOST_ONLY · RMW 교체

  (B) 전송(data plane) 실패 — 발행자는 보이는데 데이터가 안 온다.
      진단: count_publishers('/scan') >= 1 인데 수신 0개
      처방: QoS 불일치 · 전송 계층(SHM/UDP)

그래서 이 스크립트는 매 2초마다 발행자/구독자 수를 찍는다.
그리고 로봇의 stdout 을 파일로 받아 마지막에 그대로 보여준다
(v3 는 로봇 출력을 PIPE 로만 잡아서 로봇이 죽었는지 조차 알 수 없었다).

사용법
    python3 check_scan_v4.py 16 --spawn
"""
import os
import signal
import subprocess
import sys
import time

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import LaserScan

ROBOT_LOG = '/tmp/scan_probe_robot.log'


class Probe(Node):
    def __init__(self):
        super().__init__('scan_probe_v4')
        self.stamps = []
        self.recv = []
        self.first_at = None
        self.t0 = time.time()
        self.create_subscription(LaserScan, '/scan', self.on_scan, 10)

    def on_scan(self, msg):
        now = time.time()
        if self.first_at is None:
            self.first_at = now - self.t0
            print(f'  *** 첫 메시지 도착 (구독자 생성 후 {self.first_at:.2f}초)')
        self.stamps.append((msg.header.stamp.sec, msg.header.stamp.nanosec))
        self.recv.append(now)


def main():
    duration = 16.0
    spawn = '--spawn' in sys.argv
    for a in sys.argv[1:]:
        if not a.startswith('-'):
            try:
                duration = float(a)
            except ValueError:
                pass

    print('=' * 56)
    print(' 환경')
    print('=' * 56)
    for k in ('ROS_LOCALHOST_ONLY', 'ROS_AUTOMATIC_DISCOVERY_RANGE',
              'RMW_IMPLEMENTATION', 'ROS_DOMAIN_ID', 'ROS_STATIC_PEERS'):
        print(f'  {k:28s} = {os.environ.get(k, "<없음>")}')
    try:
        import importlib.util
        import rclpy.utilities as _u  # noqa: F401
    except Exception:
        pass

    rclpy.init(args=[])
    node = Probe()
    print(f'  노드 이름                    = {node.get_name()}')

    proc = None
    robot_log = None
    if spawn:
        demo = os.path.join(os.path.expanduser('~'), 'slam_demo')
        robot = os.path.join(demo, 'fake_robot.py')
        if not os.path.isfile(robot):
            robot = 'fake_robot.py'
        print(f'\n  구독자 먼저 → 1초 뒤 로봇: {robot}')
        end = time.time() + 1.0
        while time.time() < end:
            rclpy.spin_once(node, timeout_sec=0.05)
        robot_log = open(ROBOT_LOG, 'w', encoding='utf-8')
        proc = subprocess.Popen([sys.executable, robot],
                                stdout=robot_log, stderr=subprocess.STDOUT,
                                text=True,
                                cwd=demo if os.path.isdir(demo) else None)
        print(f'  로봇 pid {proc.pid} (출력 → {ROBOT_LOG})')

    print()
    print('=' * 56)
    print(' 관찰 — 발행자/구독자 수 (2초 간격)')
    print('=' * 56)
    obs_end = time.time() + duration
    next_tick = time.time() + 2.0
    while time.time() < obs_end:
        rclpy.spin_once(node, timeout_sec=0.05)
        if time.time() >= next_tick:
            next_tick += 2.0
            t = time.time() - node.t0
            pub = node.count_publishers('/scan')
            sub = node.count_subscribers('/scan')
            alive = '살아있음' if (proc is None or proc.poll() is None) else f'죽음(코드 {proc.returncode})'
            print(f'  {t:5.1f}초  발행자 {pub}  구독자 {sub}  수신 {len(node.recv)}  로봇 {alive}')

    if proc is not None:
        still = proc.poll() is None
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        if robot_log is not None:
            robot_log.close()
        print(f'\n  로봇은 20초 동안 {"계속 살아 있었음" if still else "중간에 종료됨"}')

    print()
    print('=' * 56)
    print(' 판정')
    print('=' * 56)
    n = len(node.recv)
    unique = len(set(node.stamps))
    pub_now = node.count_publishers('/scan')

    print(f'  수신 {n}개 / 고유 stamp {unique}개 / 현재 발행자 {pub_now}개')
    if robot_log is not None and os.path.isfile(ROBOT_LOG):
        with open(ROBOT_LOG, encoding='utf-8', errors='replace') as f:
            tail = [ln.rstrip() for ln in f.readlines() if ln.strip()][:6]
        print('\n  로봇 출력 (앞 6줄):')
        for ln in tail:
            print(f'    {ln}')
        if not tail:
            print('    (출력 없음 — 로봇이 시작조차 못 했을 수 있음)')

    print()
    if n == 0 and pub_now == 0:
        print('  >>> (A) 탐색 실패 확정 — 발행자가 아예 안 보임')
        print('      다음: RMW 교체 또는 ROS_LOCALHOST_ONLY 해제 후 재측정')
    elif n == 0 and pub_now >= 1:
        print('  >>> (B) 전송 실패 확정 — 발행자는 보이는데 데이터가 안 옴')
        print('      다음: QoS(durability/reliability) 확인')
    else:
        print(f'  >>> 정상 수신 — {(unique - 1) / max(node.recv[-1] - node.recv[0], 1e-6):.2f} Hz (중복 제외)')
        if n != unique:
            print(f'      중복 {n - unique}개 → 실제는 5Hz 근처, DDS 경로 중복')

    node.destroy_node()
    rclpy.shutdown()
    return 0


if __name__ == '__main__':
    sys.exit(main())

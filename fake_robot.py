#!/usr/bin/env python3
"""가짜 로봇 — 2D 라이다 + odom 을 발행해서 slam_toolbox 를 돌린다.

로봇/라이다가 없어도 SLAM 을 재현할 수 있게 만든 시뮬레이터다.

발행하는 것
    /scan        sensor_msgs/LaserScan   360빔, 방 벽+기둥까지의 거리 (실측값 = '진실')
    /tf          odom -> base_link        **일부러 오차를 넣은** 오도메트리
    /tf_static   base_link -> base_laser  센서 장착 위치

핵심 아이디어
    - 스캔은 **진실 좌표**에서 계산한다 (센서는 정확)
    - odom 은 **누적 오차**를 넣는다 (실제 로봇처럼)
    -> slam_toolbox 가 스캔 정합으로 odom 오차를 보정해야만 지도가 맞는다.
       즉 '보정이 실제로 일어나는지'를 눈으로 확인할 수 있다.

좌표계 (10/10 tf2 트리와 동일)
    map -> odom -> base_link -> base_laser
    (map->odom 은 slam_toolbox 가 발행, 나머지는 이 노드가 발행)

사용법:
    source /opt/ros/humble/setup.bash
    python3 fake_robot.py                 # 기본 3바퀴
    python3 fake_robot.py --ros-args -p loops:=5
"""
import math

import rclpy
from rclpy.executors import ExternalShutdownException
from geometry_msgs.msg import TransformStamped
from rclpy.node import Node
from sensor_msgs.msg import LaserScan
from tf2_ros import StaticTransformBroadcaster, TransformBroadcaster

# ---------------- 방 구조 (m) ----------------
ROOM_W = 8.0
ROOM_H = 6.0
# 기둥 (cx, cy, 가로, 세로) — 없으면 사각형만이라 스캔 정합이 애매해진다
PILLARS = [(3.0, 3.2, 0.5, 0.5), (5.6, 1.8, 0.5, 0.5)]

# ---------------- 주행 경로 ----------------
WAYPOINTS = [(1.0, 1.0), (7.0, 1.0), (7.0, 5.0), (1.0, 5.0)]


def _segments():
    """벽과 기둥을 '선분 목록' 으로 만든다 (광선-선분 교차로 거리 계산)."""
    segs = [
        ((0.0, 0.0), (ROOM_W, 0.0)),
        ((ROOM_W, 0.0), (ROOM_W, ROOM_H)),
        ((ROOM_W, ROOM_H), (0.0, ROOM_H)),
        ((0.0, ROOM_H), (0.0, 0.0)),
    ]
    for cx, cy, cw, ch in PILLARS:
        x0, x1 = cx - cw / 2.0, cx + cw / 2.0
        y0, y1 = cy - ch / 2.0, cy + ch / 2.0
        segs += [
            ((x0, y0), (x1, y0)),
            ((x1, y0), (x1, y1)),
            ((x1, y1), (x0, y1)),
            ((x0, y1), (x0, y0)),
        ]
    return segs


SEGMENTS = _segments()


def _cross(ax, ay, bx, by):
    return ax * by - ay * bx


def ray_hit(ox, oy, dx, dy):
    """원점 (ox,oy) 에서 방향 (dx,dy) 로 쏜 광선이 만나는 최단 거리. 없으면 None."""
    best = None
    for (ax, ay), (bx, by) in SEGMENTS:
        ex, ey = bx - ax, by - ay
        den = _cross(dx, dy, ex, ey)
        if abs(den) < 1e-12:
            continue                      # 평행
        vx, vy = ax - ox, ay - oy
        t = _cross(vx, vy, ex, ey) / den  # 광선 파라미터
        u = _cross(vx, vy, dx, dy) / den  # 선분 파라미터
        if t > 1e-6 and 0.0 <= u <= 1.0:
            if best is None or t < best:
                best = t
    return best


class FakeRobot(Node):
    def __init__(self):
        super().__init__('fake_robot')

        self.declare_parameter('loops', 3)              # 경로 몇 바퀴
        self.declare_parameter('speed', 0.6)            # m/s
        self.declare_parameter('turn_speed', 1.4)       # rad/s
        self.declare_parameter('scan_hz', 5.0)
        self.declare_parameter('tf_hz', 20.0)
        self.declare_parameter('n_beams', 360)
        self.declare_parameter('range_max', 12.0)
        self.declare_parameter('odom_dist_scale', 1.03)   # 3% 거리 과대
        self.declare_parameter('odom_yaw_bias', 0.0016)   # rad/step 누적 편향

        self.loops = int(self.get_parameter('loops').value)
        self.v_max = float(self.get_parameter('speed').value)
        self.w_max = float(self.get_parameter('turn_speed').value)
        self.scan_hz = float(self.get_parameter('scan_hz').value)
        self.tf_hz = float(self.get_parameter('tf_hz').value)
        self.n_beams = int(self.get_parameter('n_beams').value)
        self.range_max = float(self.get_parameter('range_max').value)
        self.dist_scale = float(self.get_parameter('odom_dist_scale').value)
        self.yaw_bias = float(self.get_parameter('odom_yaw_bias').value)

        # --- 진실 좌표 (스캔 계산에 쓴다) ---
        self.x, self.y = WAYPOINTS[0]
        self.yaw = 0.0
        self.wp_i = 1
        self.lap = 0

        # --- 오도메트리 좌표 (일부러 틀리게 적분한다) ---
        self.o_x, self.o_y, self.o_yaw = self.x, self.y, self.yaw

        self.scan_pub = self.create_publisher(LaserScan, '/scan', 10)
        self.tf_bc = TransformBroadcaster(self)
        self.static_bc = StaticTransformBroadcaster(self)

        self._send_static_laser_tf()

        self.dt = 1.0 / self.tf_hz
        self.create_timer(self.dt, self.step)
        self.create_timer(1.0 / self.scan_hz, self.publish_scan)

        self.get_logger().info(
            f'가짜 로봇 시작 — 방 {ROOM_W}x{ROOM_H}m, 기둥 {len(PILLARS)}개, '
            f'{self.loops}바퀴, 스캔 {self.scan_hz:.0f}Hz, odom 오차 주입 ON')
        self.get_logger().info(
            f'발행: /scan (LaserScan), odom->base_link (tf), base_link->base_laser (tf_static)')

    # ---------- 센서 장착 위치 ----------
    def _send_static_laser_tf(self):
        t = TransformStamped()
        t.header.stamp = self.get_clock().now().to_msg()
        t.header.frame_id = 'base_link'
        t.child_frame_id = 'base_laser'
        t.transform.translation.x = 0.0   # 평면 오프셋 0 → 스캔 원점과 정확히 일치
        t.transform.translation.y = 0.0
        t.transform.translation.z = 0.20
        t.transform.rotation.w = 1.0
        self.static_bc.sendTransform(t)

    # ---------- 주행 ----------
    def _normalize(self, a):
        while a > math.pi:
            a -= 2.0 * math.pi
        while a < -math.pi:
            a += 2.0 * math.pi
        return a

    def step(self):
        wx, wy = WAYPOINTS[self.wp_i]
        dx, dy = wx - self.x, wy - self.y
        dist = math.hypot(dx, dy)

        if dist < 0.15:
            self.wp_i += 1
            if self.wp_i >= len(WAYPOINTS):
                self.wp_i = 0
                self.lap += 1
                self.get_logger().info(f'{self.lap} / {self.loops} 바퀴 완료')
                if self.lap >= self.loops:
                    self.get_logger().info('주행 종료 (계속 실행 중 — Ctrl+C 로 정지)')
                    return
            return

        target = math.atan2(dy, dx)
        err = self._normalize(target - self.yaw)

        if abs(err) > 0.25:                      # 방향 먼저 맞춘다
            v = 0.0
            w = max(-self.w_max, min(self.w_max, 1.8 * err))
        else:                                    # 전진하며 미세 조향
            v = self.v_max
            w = max(-0.8, min(0.8, 2.0 * err))

        dt = self.dt
        # 진실 좌표 갱신
        self.yaw = self._normalize(self.yaw + w * dt)
        self.x += v * math.cos(self.yaw) * dt
        self.y += v * math.sin(self.yaw) * dt

        # 오도메트리 갱신 — 거리 3% 과대 + 요 편향 누적 : SLAM 이 잡아야 할 오차
        self.o_yaw = self._normalize(self.o_yaw + w * self.dist_scale * dt + self.yaw_bias)
        self.o_x += v * self.dist_scale * dt * math.cos(self.o_yaw)
        self.o_y += v * self.dist_scale * dt * math.sin(self.o_yaw)

        self._send_odom_tf()

    def _send_odom_tf(self):
        t = TransformStamped()
        t.header.stamp = self.get_clock().now().to_msg()
        t.header.frame_id = 'odom'
        t.child_frame_id = 'base_link'
        t.transform.translation.x = self.o_x
        t.transform.translation.y = self.o_y
        t.transform.rotation.z = math.sin(self.o_yaw / 2.0)
        t.transform.rotation.w = math.cos(self.o_yaw / 2.0)
        self.tf_bc.sendTransform(t)

    # ---------- 스캔 (진실 좌표 기준) ----------
    def publish_scan(self):
        msg = LaserScan()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = 'base_laser'
        msg.angle_min = -math.pi
        msg.angle_max = math.pi
        msg.angle_increment = 2.0 * math.pi / self.n_beams
        msg.time_increment = 0.0
        msg.scan_time = 1.0 / self.scan_hz
        msg.range_min = 0.05
        msg.range_max = self.range_max

        ranges = []
        for i in range(self.n_beams):
            a = msg.angle_min + i * msg.angle_increment
            wa = self.yaw + a                     # 월드 좌표계 광선 각도
            d = ray_hit(self.x, self.y, math.cos(wa), math.sin(wa))
            ranges.append(float(d) if d is not None and d <= self.range_max
                          else float('inf'))
        msg.ranges = ranges
        self.scan_pub.publish(msg)


def main(args=None):
    rclpy.init(args=args)
    node = FakeRobot()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        # pkill / Ctrl+C 로 죽을 때 rclpy 가 먼저 context 를 내리는 경우가 있다.
        # 그 뒤 shutdown() 을 또 부르면 RCLError 가 나므로 조용히 넘긴다.
        pass
    finally:
        try:
            node.destroy_node()
        except Exception:
            pass
        try:
            rclpy.shutdown()
        except Exception:
            pass


if __name__ == '__main__':
    main()

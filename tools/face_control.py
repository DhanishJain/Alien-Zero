#!/usr/bin/env python3
"""Webcam face control for ISS: Last Survivor.

Tracks your face with MediaPipe and streams six booleans over UDP to the game
(scripts/face_input.gd listens on 127.0.0.1:4242):

    head UP / DOWN      -> up / down arrow
    head TURN LEFT/RIGHT-> left / right arrow
    MOUTH OPEN          -> Z      (stun)
    EYES CLOSED / BLINK -> SPACE  (hold to repair; keep eyes shut, or blink repeatedly, to keep holding)

Usage:
    pip install -r tools/requirements.txt
    python tools/face_control.py            # start this, then start the game (or the other way round)

Keys in the preview window:  C = recalibrate (neutral face!)   Q / ESC = quit
Options: --camera N  --port N  --no-window  --sens 1.0 (higher = more sensitive)
"""
import argparse
import json
import socket
import time

import cv2
import mediapipe as mp

# MediaPipe FaceMesh landmark indices
NOSE, CHIN = 1, 152
CHEEK_A, CHEEK_B = 234, 454
EYE_OUTER_L, EYE_OUTER_R = 33, 263
LIP_UP, LIP_LOW, MOUTH_L, MOUTH_R = 13, 14, 78, 308
EYE_L = (33, 160, 158, 133, 153, 144)      # p1 p2 p3 p4 p5 p6
EYE_R = (362, 385, 387, 263, 373, 380)

CALIB_SECONDS = 2.0
BLINK_LATCH = 0.35        # a blink keeps SPACE held this long; repeated blinks keep holding it
BLINK_FRAMES = 2          # eyes must look closed this many frames in a row (filters tracking noise)


def dist(a, b):
    return ((a.x - b.x) ** 2 + (a.y - b.y) ** 2) ** 0.5


def eye_ratio(lm, idx):
    p1, p2, p3, p4, p5, p6 = (lm[i] for i in idx)
    return (dist(p2, p6) + dist(p3, p5)) / (2.0 * dist(p1, p4) + 1e-6)


def measure(lm):
    """Returns (yaw, pitch, mouth, eyes): yaw rises when you turn right, pitch rises when you tilt down."""
    lo, hi = sorted((lm[CHEEK_A].x, lm[CHEEK_B].x))
    yaw = (lm[NOSE].x - lo) / (hi - lo + 1e-6)
    eye_y = (lm[EYE_OUTER_L].y + lm[EYE_OUTER_R].y) / 2.0
    pitch = (lm[NOSE].y - eye_y) / (lm[CHIN].y - eye_y + 1e-6)
    mouth = dist(lm[LIP_UP], lm[LIP_LOW]) / (dist(lm[MOUTH_L], lm[MOUTH_R]) + 1e-6)
    eyes = (eye_ratio(lm, EYE_L) + eye_ratio(lm, EYE_R)) / 2.0
    return yaw, pitch, mouth, eyes


class Hyst:
    """On above `on`, off again below `off` (stops flicker at the threshold)."""
    def __init__(self):
        self.state = False

    def update(self, value, on, off):
        if self.state:
            self.state = value > off
        else:
            self.state = value > on
        return self.state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--port", type=int, default=4242)
    ap.add_argument("--no-window", action="store_true")
    ap.add_argument("--sens", type=float, default=1.0)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    target = ("127.0.0.1", args.port)
    cap = cv2.VideoCapture(args.camera)
    if not cap.isOpened():
        raise SystemExit("Cannot open the webcam (try --camera 1).")
    mesh = mp.solutions.face_mesh.FaceMesh(
        max_num_faces=1, refine_landmarks=True,
        min_detection_confidence=0.5, min_tracking_confidence=0.5)

    base = None                     # neutral (yaw, pitch, mouth, eyes)
    calib_start = time.time()
    calib = []
    sm_yaw = sm_pitch = None
    h_left, h_right, h_up, h_down, h_mouth = Hyst(), Hyst(), Hyst(), Hyst(), Hyst()
    closed_frames = 0
    last_closed = -10.0
    s = max(0.2, args.sens)

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        frame = cv2.flip(frame, 1)                    # mirror: turning right looks like moving right
        res = mesh.process(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        now = time.time()
        out = {"left": False, "right": False, "up": False, "down": False, "stun": False, "interact": False}
        info = "no face"

        if res.multi_face_landmarks:
            lm = res.multi_face_landmarks[0].landmark
            yaw, pitch, mouth, eyes = measure(lm)
            sm_yaw = yaw if sm_yaw is None else sm_yaw * 0.5 + yaw * 0.5
            sm_pitch = pitch if sm_pitch is None else sm_pitch * 0.5 + pitch * 0.5

            if base is None:
                info = "CALIBRATING - neutral face, eyes open, mouth closed"
                calib.append((sm_yaw, sm_pitch, mouth, eyes))
                if now - calib_start >= CALIB_SECONDS and len(calib) > 10:
                    base = tuple(sum(v[i] for v in calib) / len(calib) for i in range(4))
                    info = "calibrated"
            else:
                dyaw = (sm_yaw - base[0]) * s
                dpit = (sm_pitch - base[1]) * s
                dmouth = mouth - base[2]
                eye_rel = eyes / max(base[3], 1e-6)

                out["right"] = h_right.update(dyaw, 0.10, 0.06)
                out["left"] = h_left.update(-dyaw, 0.10, 0.06)
                out["down"] = h_down.update(dpit, 0.055, 0.03)    # nose moves away from the eye line
                out["up"] = h_up.update(-dpit, 0.055, 0.03)       # nose moves toward the eye line
                out["stun"] = h_mouth.update(dmouth * s, 0.22, 0.12)

                if eye_rel < 0.62:
                    closed_frames += 1
                else:
                    closed_frames = 0
                if closed_frames >= BLINK_FRAMES:
                    last_closed = now
                out["interact"] = (now - last_closed) < BLINK_LATCH
                info = "yaw %+.2f pitch %+.2f mouth %+.2f eyes %.2f" % (dyaw, dpit, dmouth, eye_rel)
        else:
            closed_frames = 0

        sock.sendto(json.dumps(out).encode("utf-8"), target)

        if not args.no_window:
            y = 24
            cv2.putText(frame, info, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)
            names = {"left": "LEFT", "right": "RIGHT", "up": "UP", "down": "DOWN",
                     "stun": "STUN (mouth)", "interact": "SPACE (blink)"}
            for k, label in names.items():
                y += 24
                col = (0, 255, 120) if out[k] else (120, 120, 120)
                cv2.putText(frame, label, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, col, 2)
            cv2.putText(frame, "C: recalibrate   Q: quit", (10, frame.shape[0] - 12),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)
            cv2.imshow("ISS face control", frame)
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("c"):
                base, calib, calib_start = None, [], time.time()
        else:
            time.sleep(0.005)

    sock.sendto(json.dumps({k: False for k in ("left", "right", "up", "down", "stun", "interact")}).encode(), target)
    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()

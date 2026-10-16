# ISS: Last Survivor

2D zero-gravity survival game made in **Godot 4.3+**.

Everyone aboard the ISS is dead except you. An alien is hunting you through the wrecked station.
Repair 5 systems, reach the airlock, put on your spacesuit, pull the shaft lever and blow the alien into space.
You are tethered to the ISS - but if the alien touches you, you die and the level restarts.

## Run it
1. Install Godot 4.3 or newer (https://godotengine.org).
2. Open Godot -> **Import** -> select `project.godot`.
3. Press **F5**.

## Controls (that's all you can use)
| Key | Action |
|---|---|
| Arrow keys | Thrust (you drift - zero gravity!) and aim - the aim sweeps smoothly toward the held direction, so tap briefly to aim at any angle |
| Z | Stun weapon - stuns the alien for 3 seconds (aim assist helps) |
| SPACE | Hold to repair / put on suit / pull lever. Also retry after death |

## Face control (webcam)
Play with your face instead of the keyboard (the keyboard still works too).

| Face | Same as |
|---|---|
| Head up / down (tilt) | Up / Down arrow |
| Turn head left / right | Left / Right arrow |
| Open mouth | Z (stun) |
| Close eyes / blink | SPACE (hold). Keep eyes shut, or blink repeatedly, to keep holding while repairing |

1. `pip install -r tools/requirements.txt` (Python 3.9-3.12; uses `mediapipe==0.10.14`)
2. Start the game (F5), then in a terminal: `python tools/face_control.py`
3. Look straight at the camera, neutral face, eyes open, mouth closed for ~2 s (calibration). Press **C** in the preview window to recalibrate, **Q** to quit.
4. The top-right of the game shows `FACE CONTROL: ON` once connected. If it is too/not sensitive use `--sens 1.3` / `--sens 0.8`; `--camera 1` picks another webcam.

The tracker sends its state over UDP (127.0.0.1:4242) to `scripts/face_input.gd`, which presses the same input actions as the keys, so game rules are unchanged. Good, even lighting helps a lot.

## Tips
- Momentum is your friend and enemy: tap to nudge, don't hold arrows into walls.
- Stun the alien, then run to a console. A stun gives you 3 seconds.
- The alien gets faster with every system you repair.
- Before pulling the shaft lever, stun the alien so it can't reach you while the vacuum drags it out.

Art lives in `assets/` (alien, astronaut, station interior, animated space background).

See `AGENTS.md` for the full game rules and project conventions.

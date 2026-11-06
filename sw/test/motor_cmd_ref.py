"""M11b M2 wheel-command conversion: the single Python reference.

cmd = sign(v) * min(1000, (|v| * 1000) >> 7)   (contract v2 sec. 9, v3)
Firmware twin: sw/firmware/motor_cmd.inc (motor_cmd_conv). Simulation only.
"""


def motor_cmd(v: int) -> int:
    mag = min(1000, (abs(v) * 1000) >> 7)
    return -mag if v < 0 else mag


def pwm_high_cycles(cmd: int, period: int) -> int:
    """PWM high cycles per period = floor(|cmd| * PERIOD / 1000)."""
    return (abs(cmd) * period) // 1000

/* ============================================================================
 * motor_cmd.inc -- M11b M2 wheel-command conversion (contract v2 sec. 9 / v3)
 *
 *   cmd = sign(v) * min(1000, (|v| * 1000) >> 7)
 *
 * Sign-magnitude so it is symmetric (+1 -> +7, -1 -> -7). Saturates at
 * |v| >= 128, so the firmware v_wheel domain [-256, 254] is safe.
 * Python reference: sw/test/motor_cmd_ref.py (motor_cmd). Must stay bit-exact
 * (V-CONV, sim/tb_motor_conv.v + sw/test/test_motor_conv_parity.py).
 *
 * In : a0 = v_wheel (signed 32-bit)
 * Out: a0 = cmd in [-1000, 1000]
 * Clobbers: t0, t1 only. Leaf routine (no stack).
 * SIMULATION ONLY so far. Not a physical speed scale (driver/B2 open).
 * ========================================================================== */
motor_cmd_conv:
    mv   t0, a0
    bgez a0, 1f
    neg  t0, a0               /* t0 = |v| */
1:  li   t1, 1000
    mul  t0, t0, t1
    srli t0, t0, 7            /* (|v|*1000) >> 7 */
    ble  t0, t1, 2f
    mv   t0, t1               /* min(1000, .) */
2:  bgez a0, 3f
    neg  t0, t0               /* restore sign */
3:  mv   a0, t0
    ret

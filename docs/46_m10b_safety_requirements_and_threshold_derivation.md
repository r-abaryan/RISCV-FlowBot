# M10b: robot safety requirements and stop-distance threshold derivation (DRAFT)

Status: DRAFT for owner review. Documentation only. No code, policy, RTL or firmware change. Simulation-level facts only; no hardware has been measured. Every value marked TBD must come from the real robot. Nothing here approves a margin for deployment.

## 1. Facts read from the repository (CONFIRMED in code, not hardware data)
| Item | Python sim | Firmware | Source |
|---|---|---|---|
| Robot radius | 0.25 m (assumed in sim) | not encoded | sim/robot_env.py |
| Max linear speed | 0.8 m/s (env), filter v_max=env.v_max | 64 Q7 LSB, commented as about 0.50 m/s | robot_env.py, safety_driver.h:13 |
| Max angular rate | 1.5 rad/s | 64 Q7 LSB, commented as about 1.0 rad/s | same |
| Control period | dt = 0.1 s | comments assume 50 Hz | robot_env.py, safety_driver.h:91 |
| Stop margin | d_margin = radius + 0.15 = 0.40 m (measured from robot centre) | MIN_STOP_DISTANCE_CM = 25 (reference point not documented) | m6_common.py:38, safety_driver.h:16 |
| Slew limit | a_max = 2.0 m/s^2 | 8 Q7 LSB per tick | same |
| Sensor max range | 4.0 m, 8 rays | distance input is one min value | robot_env.py, m6_common.py:53 |

Parity findings that the specification must resolve (not yet resolved):
- P1: v_max, control period and margin differ between Python and firmware. The two layers are not the same filter on the same units.
- P2: it is undocumented whether the firmware 25 cm is measured from the sensor face, the chassis edge or the robot centre. The Python 40 cm is from the centre.
- P3: the firmware scaling comment (64 LSB = 0.5 m/s) implies 128 LSB per m/s, while the sim uses 0.8 m/s full scale. Needs one table-driven definition (docs/35 section 7, item 2).

## 2. Requirements (proposed, owner to accept or change)
Numbering for traceability. "Verify" says how it would be shown, and at which evidence level.

| ID | Requirement | Verify |
|---|---|---|
| SR-1 | A physical, hardware-only E-stop, reachable on all sides, removes motor power without firmware or FPGA action. | Board/robot test (not done) |
| SR-2 | Motor driver enable defaults to disabled at power-up, on FPGA reset, on configuration loss and on watchdog timeout. | RTL sim, then board test |
| SR-3 | The neural policy output never reaches actuators except through the deterministic firmware filter. | Code review, host parity test |
| SR-4 | The robot shall stop before contact from V_max, for the worst-case sensor error and latency (section 3). | Derivation, then braking test on the robot |
| SR-5 | Every direction in which the robot can move shall be covered by a sensor with the required range, or motion in that direction shall be prevented. | Sensor layout review |
| SR-6 | Invalid, missing or stale distance readings shall be treated as contact (stop). | Host and SoC vector tests |
| SR-7 | Firmware filter output shall equal the Python golden model for all vectors, zero mismatches, including boundaries. | Host parity run |
| SR-8 | Safety logic shall be reviewed and its tests run by a person independent of the author. | Review record |
| SR-9 | First moves are supervised, low speed, with E-stop in hand, on a bench (wheels off the ground) before floor tests. | Test log |

## 3. Stop-distance derivation
Define, all measured along the direction of travel from the sensor reference point to the obstacle:

- v = speed at the time the obstacle appears. Use V_max as allowed by the filter.
- t_lat = total latency from the obstacle entering the sensor beam to the motor torque actually being removed: sensor update period + sensor processing + firmware loop period + filter + PWM or driver response. TBD, measure.
- d_brake = braking distance after torque is removed or reversed, from the real robot: v^2 / (2 a_brake), with a_brake TBD measured on the actual floor and load (not the 2.0 m/s^2 slew value, which is a command limit, not a measured deceleration).
- e_sensor = worst-case sensor error (accuracy, resolution, dropout, angle or surface effects). TBD from the datasheet and bench test.
- L_ref = distance from the sensor reference point to the chassis edge in the direction of travel. TBD, measured.
- c = additional clearance chosen by the owner (for example, tolerance on the above). Owner decision.

Required trigger distance, measured at the sensor:

    d_stop >= L_ref + v * t_lat + d_brake + e_sensor + c

The firmware threshold MIN_STOP_DISTANCE_CM must be at least d_stop, expressed in the same reference as the sensor reading, and the proportional cap beyond the threshold must still let the robot decelerate to zero at the threshold (check that the 5/8 LSB-per-cm slope is consistent with a_brake and t_lat; this is not yet checked).

Note on sensitivity (arithmetic only, no robot data): at a speed v the term v * t_lat grows linearly. For example, at 0.5 m/s a total latency of 0.1 s alone contributes 5 cm, and a braking deceleration of 1 m/s^2 contributes 12.5 cm. These are illustrations of the formula, not measurements, and are not proposed values.

## 4. Sensor coverage requirement
Known limitation, confirmed from code: the filter receives min over all eight rays, so a side obstacle limits forward speed like a frontal one (docs/35 section 7). The reverse direction and blind sectors between rays are not characterised. Requirements to settle before physical navigation:
- SC-1: the physical sensor layout (type, count, mounting, field of view, minimum range) is not defined. Owner decision.
- SC-2: rear and side coverage if reverse or in-place rotation can sweep the chassis into obstacles. Rotation of a non-circular chassis needs its swept radius.
- SC-3: blind sectors, minimum sensing range (many ultrasonic and ToF sensors read badly closer than a few cm) and height of obstacles relative to sensor plane.
Label note: SC-1 to SC-3 are sensor-coverage items local to this document. The labels B1 to B3 belong to docs/37 section 11.1 (25 MHz watchdog timing, unconfigured pin and reset behaviour, independent E-stop and power cutoff) and are used in the same sense in docs/45. They are not used here.

Authority: docs/37 is the authority for the requirement set (SR list, parameter table, blockers, owner input list). Sections 2 and 5 here repeat it for convenience only; if they differ, docs/37 wins. The new content of this document is the stop-distance derivation in section 3.

## 5. Open inputs needed from the owner (blocking)
1. Chassis dimensions and shape; wheel and motor choice; mass.
2. Sensor choice and positions.
3. Maximum speed allowed for first tests (a lower V_max reduces d_stop; no change is made here).
4. Whether distance safety stays firmware-only with the RTL watchdog independent (docs/35 item 5).
5. Required stall behaviour (stop, escalate, recover).
6. Name of the independent reviewer.
7. Permission to measure t_lat and a_brake on a bench or the robot once built.

## 6. Next steps once inputs exist
1. Fill the TBD values, compute d_stop, record it with the calculation.
2. Make a single table-driven constants file; check Python and firmware derive from it (resolves P1 to P3).
3. Host parity test and SoC vector test (SR-6, SR-7).
4. Only then consider M10c direction-aware filtering, as a separate approved change.

## 7. Evidence status
Implemented: current filter (25 cm, firmware). Simulated: Python sim results in earlier docs. Synthesized, routed, board-tested, robot-tested: none for any item in this document. Derived thresholds: none (inputs missing).

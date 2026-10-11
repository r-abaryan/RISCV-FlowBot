// ============================================================================
// File: safety_driver.h
// Description: Deterministic Safety Supervisor Driver for Robot Control
// Implements Kinematic Limits, Slew Rate Clamping, Proximity Filter & HW Interlock
// ============================================================================

#ifndef SAFETY_DRIVER_H
#define SAFETY_DRIVER_H

#include "soc_regs.h"

// Kinematic limits in Q7 fixed-point representation
#define MAX_LINEAR_VEL_Q7    64   // ~0.50 m/s
#define MAX_ANGULAR_VEL_Q7   64   // ~1.00 rad/s
#define MAX_ACCEL_SLEW_Q7    8    // Maximum velocity delta per control tick
#define MIN_STOP_DISTANCE_CM 25   // Safety boundary threshold

typedef struct {
    int8_t  last_v;
    int8_t  last_w;
    uint8_t fault_count;
} safety_state_t;

static inline void safety_hw_enable(uint32_t timeout_cycles) {
    SAFETY_REG_TIMEOUT = timeout_cycles;
    SAFETY_REG_CTRL    = 1;
}

static inline void safety_hw_heartbeat(void) {
    SAFETY_REG_HEARTBEAT = SAFETY_HEARTBEAT_KEY;
}

static inline uint32_t safety_is_hardware_disarmed(void) {
    return (SAFETY_REG_STATUS & SAFETY_DISARM_BIT);
}

static inline void safety_hw_force_disarm(void) {
    SAFETY_REG_FORCE_DIS = 1;
}

// Deterministic software safety filter checking AI policy outputs
static inline void safety_filter_command(
    safety_state_t *state,
    int8_t  raw_v,
    int8_t  raw_w,
    int16_t min_distance_cm,
    int8_t *safe_v,
    int8_t *safe_w
) {
    int8_t target_v = raw_v;
    int8_t target_w = raw_w;

    // 1. Proximity override: if obstacle detected within stopping distance, force zero linear velocity
    if (min_distance_cm <= MIN_STOP_DISTANCE_CM) {
        if (target_v > 0) {
            target_v = 0; // Immediate halt
        }
    }

    // 2. Absolute Kinematic Clamping
    if (target_v > MAX_LINEAR_VEL_Q7)  target_v = MAX_LINEAR_VEL_Q7;
    if (target_v < -MAX_LINEAR_VEL_Q7) target_v = -MAX_LINEAR_VEL_Q7;
    if (target_w > MAX_ANGULAR_VEL_Q7)  target_w = MAX_ANGULAR_VEL_Q7;
    if (target_w < -MAX_ANGULAR_VEL_Q7) target_w = -MAX_ANGULAR_VEL_Q7;

    // 3. Dynamic Acceleration Slew Rate Limiter
    int16_t delta_v = (int16_t)target_v - (int16_t)state->last_v;
    if (delta_v > MAX_ACCEL_SLEW_Q7) {
        target_v = state->last_v + MAX_ACCEL_SLEW_Q7;
    } else if (delta_v < -MAX_ACCEL_SLEW_Q7) {
        target_v = state->last_v - MAX_ACCEL_SLEW_Q7;
    }

    int16_t delta_w = (int16_t)target_w - (int16_t)state->last_w;
    if (delta_w > MAX_ACCEL_SLEW_Q7) {
        target_w = state->last_w + MAX_ACCEL_SLEW_Q7;
    } else if (delta_w < -MAX_ACCEL_SLEW_Q7) {
        target_w = state->last_w - MAX_ACCEL_SLEW_Q7;
    }

    // Update state
    state->last_v = target_v;
    state->last_w = target_w;

    *safe_v = target_v;
    *safe_w = target_w;
}

#endif // SAFETY_DRIVER_H

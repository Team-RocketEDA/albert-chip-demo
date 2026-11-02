#!/usr/bin/env python3
"""olp_digitizer.py — ADC + calibration model (matches blocks/02, 09 §6).

7-bit SAR quantize of V_int over Vref, then per-column slope/offset +
drift-compensated rescale, requantized to int8. Pure model of the digital
calib ALU; the analog side is ngspice. Also usable standalone for sweeps.
Time base: t and t0 are in DAYS (paper drift timescale: 30-day test, nu in
[0.01, 0.10]); drift_gain is the power-law compensation multiplier.
Behavioral stand-in for vendor/SKY130_SAR-ADC1 (12b diff SAR, async
start/finished handshake): take macro result bits [11:5] as the 7b OLP
code; slope/offset/dequant here mirror the macro's digital backend.
"""
VREF = 1.2
ADC_BITS = 7
ADC_MAX = (1 << ADC_BITS) - 1


def quantize(v_int, vref=VREF, bits=ADC_BITS):
    v = max(0.0, min(v_int, vref))
    return int(round(v / vref * ((1 << bits) - 1)))


def calibrate(d_raw, slope=1.0, offset=0.0, drift_gain=1.0):
    y = (d_raw * slope + offset) * drift_gain
    return max(-128, min(127, int(round(y))))


def drift_gain(t, t0=1.0, nu=0.05):
    # t, t0 in days. Power-law compensation gain (t/t0)^nu for log-G decay;
    # paper nu in [0.01, 0.10]; nu=0 disables compensation (PARAMS §8).
    return (t / t0) ** nu


if __name__ == "__main__":
    import sys
    v = float(sys.argv[1]) if len(sys.argv) > 1 else 0.5
    slope = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    off = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    d = quantize(v)
    print(f"V_int={v}V -> d_raw={d}/{ADC_MAX} -> y_cal={calibrate(d, slope, off)}")

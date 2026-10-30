import '../models/seismic_models.dart';

/// Homogeneous half-space velocity model shared by stage 3 (association
/// gate) and stage 4 (hypocentre estimator), so both agree on what "the
/// expected arrival time" means for a given phase. Previously each stage
/// had (or would have had) its own copy of these numbers; a single source
/// of truth avoids the two silently drifting apart if one gets tuned later.
///
/// Vp = 6.0 km/s, Vs/surface-wave representative = 3.5 km/s - see
/// ARCHITECTURE.md ("Velocity model") for why this is a deliberately
/// simple homogeneous model, and why P and "S-or-surface" is the finest
/// split that's meaningful given what stage 2 (phase ID) actually
/// distinguishes.
const double pVelocityMps = 6000.0;
const double sOrSurfaceVelocityMps = 3500.0;

double velocityForPhase(WavePhase phase) => phase == WavePhase.p ? pVelocityMps : sOrSurfaceVelocityMps;

/// distance = k * (t_S - t_P), the classic single-station S-P interval
/// distance formula, k = Vp*Vs/(Vp-Vs). With the constants above this
/// comes out to 8400 - close to the "~8 km per second of S-P interval"
/// rule of thumb seismologists commonly cite for continental crust, which
/// is a reasonable sanity check on the two velocities chosen above.
const double sMinusPDistanceConstantMps = pVelocityMps * sOrSurfaceVelocityMps / (pVelocityMps - sOrSurfaceVelocityMps);

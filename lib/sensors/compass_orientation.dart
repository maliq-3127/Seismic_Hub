import 'dart:math' as math;

/// A vector expressed in local East-North-Up coordinates.
class EnuVector {
  final double east;
  final double north;
  final double up;
  const EnuVector({required this.east, required this.north, required this.up});

  double get horizontalMagnitude => math.sqrt(east * east + north * north);

  /// Compass bearing in degrees, 0 = north, 90 = east, clockwise, [0, 360).
  double get azimuthDegrees {
    double deg = math.atan2(east, north) * 180.0 / math.pi;
    if (deg < 0) deg += 360.0;
    return deg;
  }
}

/// Fix #7: "use the standard methods that a phone would normally use to
/// determine true North and East."
///
/// This is the standard tilt-compensated compass construction (the same
/// gravity + magnetic-field fusion Android's SensorManager.getRotationMatrix
/// and iOS's CMDeviceMotion.heading compute internally): the accelerometer
/// gives the local "up" direction (device is stationary, so its raw reading
/// is dominated by the reaction to gravity - see sensors_plus docs), the
/// magnetometer gives magnetic north, and their cross products give an
/// orthonormal (East, North, Up) frame expressed in device coordinates.
/// Any device-frame vector (e.g. the HPF'd horizontal disturbance
/// acceleration) can then be projected onto that frame by dot product.
///
/// Both inputs are low-pass filtered (separately from the HPF used for
/// disturbance detection) so a brief violent disturbance doesn't itself
/// corrupt the orientation reference; only ambient, slowly-varying gravity
/// and field readings feed this class.
///
/// This gives *magnetic* north. True-north correction (declination) is
/// applied afterwards via [applyDeclination] using a single configurable
/// constant rather than a full World Magnetic Model - see ARCHITECTURE.md
/// for why.
class CompassOrientation {
  final double gravityLpfAlpha;
  final double magnetLpfAlpha;

  double _gx = 0.0, _gy = 0.0, _gz = 9.81;
  double _mx = 0.0, _my = 0.0, _mz = 0.0;
  bool _hasMagSample = false;
  bool _hasAccelSample = false;

  CompassOrientation({this.gravityLpfAlpha = 0.02, this.magnetLpfAlpha = 0.05});

  void updateAccelerometer(double x, double y, double z) {
    if (!_hasAccelSample) {
      // Seed instantly on the first sample instead of slowly LPF-ing in from
      // an arbitrary default, so orientation is usable immediately.
      _gx = x;
      _gy = y;
      _gz = z;
      _hasAccelSample = true;
      return;
    }
    _gx += gravityLpfAlpha * (x - _gx);
    _gy += gravityLpfAlpha * (y - _gy);
    _gz += gravityLpfAlpha * (z - _gz);
  }

  void updateMagnetometer(double x, double y, double z) {
    if (!_hasMagSample) {
      _mx = x;
      _my = y;
      _mz = z;
      _hasMagSample = true;
      return;
    }
    _mx += magnetLpfAlpha * (x - _mx);
    _my += magnetLpfAlpha * (y - _my);
    _mz += magnetLpfAlpha * (z - _mz);
  }

  bool get isReady => _hasMagSample && _hasAccelSample;

  static double _norm3(double x, double y, double z) => math.sqrt(x * x + y * y + z * z);

  /// Projects a device-frame vector onto (East, North, Up). Returns null
  /// until both an accelerometer and a magnetometer sample have been seen,
  /// or if the magnetometer reading is degenerate (parallel to gravity -
  /// e.g. sitting directly on a magnet, or a very poorly calibrated sensor).
  EnuVector? projectToEnu(double vx, double vy, double vz) {
    if (!isReady) return null;

    final gNorm = _norm3(_gx, _gy, _gz);
    if (gNorm < 1e-6) return null;
    final upX = _gx / gNorm, upY = _gy / gNorm, upZ = _gz / gNorm;

    // East (unnormalized) = magnetic field x up.
    final exRaw = _my * upZ - _mz * upY;
    final eyRaw = _mz * upX - _mx * upZ;
    final ezRaw = _mx * upY - _my * upX;
    final eNorm = _norm3(exRaw, eyRaw, ezRaw);
    if (eNorm < 1e-6) return null;
    final eastX = exRaw / eNorm, eastY = eyRaw / eNorm, eastZ = ezRaw / eNorm;

    // North = up x east (completes the right-handed ENU frame).
    final northX = upY * eastZ - upZ * eastY;
    final northY = upZ * eastX - upX * eastZ;
    final northZ = upX * eastY - upY * eastX;

    final east = vx * eastX + vy * eastY + vz * eastZ;
    final north = vx * northX + vy * northY + vz * northZ;
    final up = vx * upX + vy * upY + vz * upZ;
    return EnuVector(east: east, north: north, up: up);
  }
}

/// True bearing = magnetic bearing + declination (declination positive when
/// magnetic north sits east of true north). Wraps into [0, 360).
double applyDeclination(double magneticAzimuthDegrees, double declinationDegrees) {
  double trueAz = (magneticAzimuthDegrees + declinationDegrees) % 360.0;
  if (trueAz < 0) trueAz += 360.0;
  return trueAz;
}

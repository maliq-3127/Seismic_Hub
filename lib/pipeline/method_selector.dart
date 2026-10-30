import '../models/seismic_models.dart';

/// What one associated node's data may be used for in this update, after
/// the accelerometer-saturation override has already been applied.
class NodeTrust {
  final String nodeId;
  final bool useAzimuth;
  final bool useApparentVelocity;
  final bool useAmplitude;
  final bool useSMinusP;
  final double reliabilityWeight;
  const NodeTrust({
    required this.nodeId,
    required this.useAzimuth,
    required this.useApparentVelocity,
    required this.useAmplitude,
    required this.useSMinusP,
    required this.reliabilityWeight,
  });
}

class MethodSelection {
  final String methodLabel;
  final MethodMaturity maturity;
  final bool depthLikelyResolvable;
  final Map<String, NodeTrust> trustByNodeId;
  const MethodSelection({
    required this.methodLabel,
    required this.maturity,
    required this.depthLikelyResolvable,
    required this.trustByNodeId,
  });
}

/// Fix item 1 ("what I need you to produce"): a formalized version of the
/// node-count x channel-dominance decision table, including exactly how the
/// accelerometer-saturated override interacts with it.
///
/// Rather than a dozen separately-coded algorithms (one per table cell),
/// every cell below feeds the SAME recursive estimator (hypocentre_estimator
/// .dart) with a different combination of trusted observation types per
/// node - this is what actually varies between cells. Depth availability is
/// modelled the same way: rather than special-casing "depth unresolved
/// below N nodes", the estimator's depth prior is simply wide/uninformative
/// until enough nodes constrain it, and [depthLikelyResolvable] is only a
/// label for the UI, not something the estimator branches on.
///
/// The saturation override ("this should override the normal channel logic
/// regardless of node count, for whichever nodes it's detected at") is
/// applied per node, before the aggregate node-count/channel-mix label is
/// chosen: a saturated node's accelerometer amplitude is untrustworthy
/// (clipped), but its gyroscope is still recording a clean, unclipped
/// signal, so that node is treated as contributing both-channels-usable
/// data (azimuth + apparent velocity), just with amplitude excluded - and
/// this happens independent of what every other node in the same event is
/// doing.
class MethodSelector {
  static MethodSelection select(List<TriggerObservation> associatedObservations) {
    final n = associatedObservations.length;
    final trust = <String, NodeTrust>{};
    int effectiveBothChannelsCount = 0;

    for (final obs in associatedObservations) {
      final effectiveBoth = obs.accelerometerSaturated || obs.channelState == ChannelDominanceState.bothChannelsUsable;
      if (effectiveBoth) effectiveBothChannelsCount++;

      final surfaceWeight = obs.surfaceType == SurfaceType.soft ? 0.6 : 1.0;

      trust[obs.nodeId] = NodeTrust(
        nodeId: obs.nodeId,
        // Azimuth comes from the *direction* of the compass-rotated
        // disturbance vector, not its magnitude, so it survives clipping
        // more gracefully than a magnitude-dependent quantity does - though
        // asymmetric clipping across axes could still bias it in ways this
        // doesn't attempt to detect.
        useAzimuth: obs.azimuthDegrees != null,
        // Apparent velocity is translational velocity - integrated from the
        // accelerometer - divided by rotation rate. A saturated
        // accelerometer under-reports that integral exactly the way it
        // under-reports amplitude, regardless of how clean the gyroscope
        // is, so this has to be excluded on saturation too. (Previously
        // wasn't - a saturated node's apparent velocity was trusted while
        // its amplitude, for the same underlying reason, was not.)
        useApparentVelocity: effectiveBoth && !obs.accelerometerSaturated && obs.apparentVelocityMps != null,
        // A saturated accelerometer's amplitude is clipped, so it cannot be
        // used for the distance-implying amplitude bound even though its
        // gyroscope is trustworthy for azimuth.
        useAmplitude: !obs.accelerometerSaturated,
        // S-P interval is a timing measurement (when did P cross threshold
        // vs. when did S), not a magnitude one, so unlike amplitude and
        // apparent velocity it isn't corrupted by a clipped accelerometer -
        // no saturation guard needed here.
        useSMinusP: obs.sMinusPSeconds != null,
        reliabilityWeight: surfaceWeight,
      );
    }

    final allBoth = n > 0 && effectiveBothChannelsCount == n;
    final anyBoth = effectiveBothChannelsCount > 0;

    String label;
    MethodMaturity maturity;
    bool depthOk;

    if (n <= 1) {
      if (allBoth) {
        label = 'Six-component single-station (azimuth + local velocity + rough distance)';
        maturity = MethodMaturity.exotic;
      } else {
        label = 'Single-station P-polarisation + S-P time (weak; 180deg azimuth ambiguity)';
        maturity = MethodMaturity.mature;
      }
      depthOk = false;
    } else if (n == 2) {
      if (allBoth) {
        label = 'Two independent single-station 6C solves, cross-checked';
        maturity = MethodMaturity.exotic;
      } else {
        label = 'Backazimuth crossing';
        maturity = MethodMaturity.mature;
      }
      depthOk = false;
    } else if (n == 3) {
      if (allBoth) {
        label = 'Rotation-augmented beamforming';
        maturity = MethodMaturity.exotic;
      } else {
        label = 'S-P interval circles (three-circle epicentre fix)';
        maturity = MethodMaturity.mature;
      }
      depthOk = false;
    } else if (n <= 5) {
      if (allBoth) {
        label = 'Geiger-style triangulation, rotation-tilt-corrected with azimuth cross-check';
      } else {
        label = 'Geiger-style arrival-time triangulation';
      }
      maturity = MethodMaturity.mature;
      depthOk = true;
    } else if (n <= 8) {
      if (allBoth) {
        label = 'Joint inversion (rotation + translation)';
        maturity = MethodMaturity.exotic;
      } else {
        label = 'Over-determined arrival-time triangulation';
        maturity = MethodMaturity.mature;
      }
      depthOk = true;
    } else {
      label = anyBoth
          ? 'Dense back-projection (translational; rotation role unestablished at this scale)'
          : 'Dense back-projection (translational)';
      maturity = MethodMaturity.mature;
      depthOk = true;
    }

    return MethodSelection(
      methodLabel: label,
      maturity: maturity,
      depthLikelyResolvable: depthOk,
      trustByNodeId: trust,
    );
  }
}

import Foundation

// Cross-slice conformances added at integration (stage 3). Each slice declared its half
// over the stage-1.5 baseline, which did not contain the other slice's type, so the
// one-line joins live here. See Docs/notes/integration.md.

/// Spin's "Open in Lab" → Spectroscopy lab, NMR sample, Earth-field (live |B|) mode.
/// `SpectrumModel.openEarthFieldLab()` already exists (spectrum-ui-requests §1, spin-ui-requests §1).
extension SpectrumModel: SpinEarthFieldLab {}

/// Spin shows the magnetometer's calibration next to f_L through this protocol instead of
/// reading `accuracy` by reflection (spin-ui-requests §5).
extension MagnetometerChannel: SpinCalibrationReporting {}

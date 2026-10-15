// Compiled only by Tools/check-rf.sh in the app's isolation mode (Swift 6, default MainActor):
// proves the RF engine's public API is callable from nonisolated code and from detached tasks,
// and that its values are Sendable across isolation boundaries. Never part of the app target.
import Foundation
import simd

nonisolated func rfProbeNonisolated() -> Double {
  var total = RF.Const.c + RF.Units.dB(power: 2) + RF.Special.Q(1) + RF.Numerology.NR.tc + RF.Numerology.GSM.symbolPeriod
  total += RF.Propagation.fsplDB(distance: 10, frequency: 2.45e9)
  total += RF.Propagation.TR38901.indoorOfficeLOS.pathLossDB(distance3D: 10, frequencyGHz: 5.5)
  total += RF.Atmosphere.gasAttenuationDBPerKm(frequencyGHz: 60) + RF.Atmosphere.rainAttenuationDBPerKm(frequencyGHz: 28, rainRate: 25)
  total += RF.Building.entryLossDB(frequencyGHz: 3.5, building: .traditional) + RF.Building.O2IModel.lowLoss.wallLossDB(frequencyGHz: 3.5)
  total += RF.Fading.maxDoppler(speed: 30, frequency: 3.5e9) + RF.Noise.floorDBm(bandwidth: 20e6, noiseFigureDB: 7)
  total += RF.ErrorRates.bpskBER(ebN0DB: 6) + RF.AnalogTheory.carrierNullBeta + RF.Arrays.gratingFreeSpacing(steerTheta: 1)
  total += RF.Antennas.airyHalfPowerArgument + RF.Antennas.ThinDipole(lengthWavelengths: 0.5).directivity
  let model = RF.AntennaModel(RF.AntennaParameters(style: .patch))
  total += model.directivityDBi + Double(RF.PatternMesh(model: model, rows: 9, columns: 12).values.count)
  total += model.apertureDistribution()?.factor(directionCosine: 0.3).magnitude ?? 0
  var chirpTX = RF.Transmitter(RF.WaveformSettings(waveform: .chirp(bandwidth: 1e9, duration: 2.048e-6)))
  total += chirpTX.sweep(count: 64).meanPower + (RF.ChannelConfig(snrDB: .nan).sanitized().snrDB ?? 0)
  total += RF.LinkBudget.evaluate(RF.LinkBudgetInput(frequency: 2.45e9, bandwidth: 20e6)).snrDB
  total += Double(RF.SystemsCatalog.all.count) + Double(RF.Constellation(.qam16).points.count)
  var link = RF.BasebandLink(RF.BasebandLinkConfig(system: RF.SystemsCatalog.all[0]))
  total += Double(link.next().rx.count)
  var analyzer = RF.SpectrumAnalyzer(count: 64)!
  total += Double(analyzer.powerDB(RF.IQBuffer(count: 64)).count)
  var rng = RF.SeededRandom(seed: 1)
  total += rng.gaussian()
  return total
}

/// Values cross from a detached task back to the main actor: they must be Sendable.
@MainActor func rfProbeMainActor() async -> Double {
  let model = await Task.detached { RF.AntennaModel(RF.AntennaParameters(style: .phasedArray)) }.value
  let frame = await Task.detached { () -> RF.BasebandFrame in
    var link = RF.BasebandLink(RF.BasebandLinkConfig(waveform: .ofdm(modulation: .qam64, config: .wifiLegacy)))
    return link.next()
  }.value
  let mesh = await Task.detached { RF.PatternMesh(model: model) }.value
  let aperture = await Task.detached { model.apertureDistribution(plane: .e) }.value
  let catalog: [RF.RadioSystem] = await Task.detached { RF.SystemsCatalog.all }.value
  let budget = await Task.detached { RF.LinkBudget.evaluate(RF.LinkBudgetInput(frequency: 1e9, bandwidth: 1e6)) }.value
  return model.directivity + Double(frame.rx.count) + Double(mesh.values.count) + Double(catalog.count) + budget.snrDB
    + Double(aperture?.positions.count ?? 0) + rfProbeNonisolated()
}

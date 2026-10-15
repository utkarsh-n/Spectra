import SwiftUI

/// Settings is a `Form` in a sheet with its own `NavigationStack` (house rule 5): Feedback,
/// Sensors (with the Sensor census), Units, Privacy, About. Changes apply live; Done
/// dismisses. Identifiers: `settings-form`, `settings-sound`, `settings-haptics`,
/// `settings-strength`, `settings-hum`, `settings-feel`, `settings-census`, `settings-done`.
struct SettingsSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var app = app
    NavigationStack {
      Form {
        Section {
          Toggle(isOn: $app.settings.soundOn) {
            Label("Sound", systemImage: "speaker.wave.2.fill")
          }
          .accessibilityIdentifier("settings-sound")
          Toggle(isOn: $app.settings.hapticsOn) {
            Label("Haptics", systemImage: "hand.tap")
          }
          .accessibilityIdentifier("settings-haptics")
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Haptic strength")
              Spacer()
              Text("\(Int((app.settings.hapticStrength * 100).rounded())) %")
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.amber)
            }
            Slider(value: $app.settings.hapticStrength, in: 0.2...1, step: 0.05) { editing in
              if !editing { Haptics.shared.detent(normalized: 0.5) }
            }
            .accessibilityLabel("Haptic strength")
            .accessibilityValue("\(Int((app.settings.hapticStrength * 100).rounded())) percent")
            .accessibilityIdentifier("settings-strength")
          }
          .disabled(!app.settings.hapticsOn)
          Button {
            Haptics.shared.detent()
          } label: {
            Label("Feel a detent", systemImage: "dial.medium")
          }
          .disabled(!app.settings.hapticsOn)
          .accessibilityIdentifier("settings-feel")
          Toggle(isOn: $app.settings.continuousHum) {
            Label("Continuous hum", systemImage: "waveform.path.ecg")
          }
          .disabled(!app.settings.hapticsOn)
          .accessibilityIdentifier("settings-hum")
        } header: {
          Text("Feedback")
        } footer: {
          Text(
            "Sound plays tones at a pitch mapped from frequency, and Spin plays the true pitch of precession. It follows the silent switch. Continuous hum lets live signal strength and spin run a steady vibration while you watch them."
          )
        }

        Section {
          ForEach(SensorID.allCases) { id in
            Toggle(isOn: sensorBinding(id)) {
              Label(id.title, systemImage: id.symbol)
            }
            .accessibilityIdentifier("settings-sensor-\(id.rawValue)")
          }
          #if DEBUG
            Picker("Simulated sensors", selection: $app.settings.simulation) {
              ForEach(SimulationPreference.allCases) { Text($0.title).tag($0) }
            }
          #endif
          NavigationLink {
            SensorCensusView()
          } label: {
            Label("Sensor census", systemImage: "list.bullet.rectangle")
          }
          .accessibilityIdentifier("settings-census")
        } header: {
          Text("Sensors")
        } footer: {
          Text(
            "A sensor that is off never starts, even when a card or node asks for it. Spectra asks for permission the first time you start a sensor, not before."
          )
        }

        Section("Units") {
          Picker("Power", selection: $app.settings.powerUnit) {
            ForEach(PowerUnit.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          Picker("Distance", selection: $app.settings.distanceUnit) {
            ForEach(DistanceUnit.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
        }

        Section {
          LabeledContent("Version", value: Self.version)
          Text("Field notes for each tab are behind the ⓘ button. They say what is measured, what is modeled, and where the numbers come from.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Button("Restore default settings", role: .destructive) {
            app.resetSettings()
            Haptics.shared.success()
          }
        } header: {
          Text("About")
        } footer: {
          Text(
            "Privacy: Spectra keeps everything on this iPhone. Sensor readings, sound and camera frames are used live and never recorded, stored or sent."
          )
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.background)
      .accessibilityIdentifier("settings-form")
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            Haptics.shared.tap()
            dismiss()
          }
          .accessibilityIdentifier("settings-done")
        }
      }
    }
    .presentationDragIndicator(.visible)
  }

  private func sensorBinding(_ id: SensorID) -> Binding<Bool> {
    Binding(
      get: { app.settings.isEnabled(id) },
      set: { on in
        if on { app.settings.disabledSensors.remove(id) } else { app.settings.disabledSensors.insert(id) }
      })
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "\(short) (\(build))"
  }
}

/// Settings → Sensors → Sensor census. The live slice's `LiveCensusView` (state, provenance,
/// measured rate, streams, a Run switch and the capability flags of `sdk-sensors.md` §7) is
/// the one census; this name stays for API stability (integration, live-requests §1).
/// Rows carry `live-census-<id>`, Run switches `live-census-run-<id>`.
struct SensorCensusView: View {
  var body: some View { LiveCensusView() }
}

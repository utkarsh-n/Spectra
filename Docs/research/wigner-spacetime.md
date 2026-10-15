# Spacetime Wigner distribution (Utkarsh's construction) — reference for Spectra

Source: Utkarsh, 2026-10-03, with the "Spacetime Wigner Distribution" poster. Notation and convention are his; Spectra must use them exactly and credit them in the field notes.

## Convention (C)
- ψ̃(k,ν) = ∫ ψ(x,t) e^{−i(k·x − 2πνt)} d³x dt
- ψ(x,t) = ∫ ψ̃(k,ν) e^{+i(k·x − 2πνt)} dν d³k/(2π)³

k is angular wavenumber (rad/m, measure d³k/(2π)³); ν is ordinary frequency (Hz, measure dν). A plane wave e^{i(k₀·x − 2πν₀t)} transforms to (2π)³δ³(k−k₀)δ(ν−ν₀), i.e. it lands at (+k₀, +ν₀).

## Definition
Φ(ν,k;x,t) = ∫∫ ψ*(x−ξ/2, t−τ/2) ψ(x+ξ/2, t+τ/2) e^{−i(k·ξ − 2πντ)} d³ξ dτ

## Marginals and identities
- (M1) ∫ Φ dν d³k/(2π)³ = |ψ(x,t)|²
- (M2) ∫ Φ d³x dt = |ψ̃(k,ν)|²
- (P) ∫ Φ d³x dt dν d³k/(2π)³ = ∫|ψ|² d³x dt = ∫|ψ̃|² dν d³k/(2π)³
- Reality: Φ* = Φ (ξ → −ξ, τ → −τ). Not positive in general (quasidistribution; interference cross terms).
- Dimensions: [Φ] = [ψ]² L³ T.
- Partial marginals: ∫Φ dν = spatial Wigner W(x,k) at fixed t; ∫Φ d³k/(2π)³ = temporal Wigner W(t,ν) at fixed x.
- Plane-wave limit: Φ = (2π)³ δ³(k−k₀) δ(ν−ν₀), uniform in x and t.

## Verification (orchestrator, 2026-10-03)
Analytic: every step of the derivation re-done by hand: inverse pair, M1 deltas, M2 change of variables (unit Jacobian, phase factorisation into ψ̃ψ̃*), plane-wave limit, reality, dimensions, partial marginals. All correct.

Numerical (numpy, 1 space dimension + time, two Gaussian wave packets, scripts reproduced below in spirit):
- M1 holds to 1.6e-15 (pointwise), total P to 1e-15 relative.
- Φ is real to round-off; two packets give min Φ / max Φ = −1.0 (the interference cross term between them); a single Gaussian packet is non-negative (Hudson's theorem).
- M2 holds pointwise to 2e-4 once the discrete construction is done right (see below).

## Implementation rules learned from the check (discrete Φ)
1. **No double counting of lags.** On a periodic grid of even length P, the map (i, m) → (i−m, i+m) hits every pair twice ((i+P/2, m+P/2) aliases), which turns M2 into a checkerboard (half the k bins doubled, half zero) even though the totals agree. Fix: zero-pad the field ≥2× and restrict half-lags to |m| < P/4 (lag window ≤ half the padded grid); use the k/ν grid of that lag length.
2. **2× oversampling or the analytic signal.** The half-lag product makes the discrete Wigner periodic with half the usual period, so content above half the grid Nyquist aliases. Sample ≥2× or use the analytic signal.
3. **Real physical signals** (an E-field component, a magnetometer axis, a microphone) have ±ν mirror images whose cross term sits at ν = 0. Use the analytic signal (one-sided spectrum via FFT Hilbert transform) → the Wigner–Ville distribution. Same for k in space.
4. **"Same information"** holds up to a global phase: Φ determines ψ up to e^{iθ}.
5. **Readability vs exactness.** Cross terms oscillate halfway between components. Offer the exact Wigner (diverging colour map: positive warm, negative cool, as in the poster), a pseudo-Wigner (lag window), a smoothed pseudo-Wigner, and the spectrogram (always ≥ 0, blurred) side by side; marginals are exact only for the unsmoothed Φ.
6. **Free fields live on their dispersion shell.** For a field that obeys a dispersion relation ω(k), the (k,ν) marginal is supported on ν = ω(k)/2π: the light line in vacuum, Sellmeier-curved in glass, the hyperbola ω² = ω_p² + c²k² in a plasma (the ionosphere), the cut-off branch in a waveguide. Propagation shears Φ in x along the group velocity, and Fresnel diffraction shears the spatial Wigner (x → x + z k/k₀). An aperture's far-field radiation pattern is its spatial-frequency marginal with k_x = k sin θ.

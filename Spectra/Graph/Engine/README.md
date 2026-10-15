# Graph/Engine

Owner: **patch**. The pure node-graph engine (SPEC.md §3.6): typed ports and payloads (`GraphTypes`), the node catalogue (`GraphCatalog`), the Codable patch document with cycle-checked editing and Kahn order (`GraphDocument`), the evaluator and block scheduler (`GraphEvaluator`), node processors (`GraphSourceNodes`, `GraphModemNodes`, `GraphProcessNodes`) and the eight presets with card geometry (`GraphPresets`).

Foundation, simd and the pure engines (RF, Phase, Spin, Core) only; every type is `nonisolated` and `Sendable`, so it compiles in the app and in a macOS `swiftc` harness. API: `Docs/API-patch.md`.

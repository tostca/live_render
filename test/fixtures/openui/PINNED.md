# Vendored OpenUI conformance fixtures

- Source: https://github.com/thesysdev/openui, `spec/fixtures/1.0/`
- Commit: `fbba7b1c51d8bd01c43a6aa9aff4d7508ab09b53` (2026-11-07)
- Spec revision: OpenUI 1.1 (language.md 1.1, 2026-11-04; prompt.md unchanged since 1.0). The
  `1.0/` fixtures are byte-identical to those at the previous pin, `8d9c4c3` (2026-10-16); 1.1
  added no fixtures, so its changes are covered by LiveRender's own tests.
- License: MIT, see `LICENSE` in this folder

The files under `1.0/` are copied unchanged. To update, copy the folder from a newer
upstream commit, update the hash above, and run `mix test test/live_render/openui/conformance_test.exs`.
Never edit an `expected.json` to make a case pass.

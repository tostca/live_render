# Vendored OpenUI conformance fixtures

- Source: https://github.com/thesysdev/openui, `spec/fixtures/1.0/`
- Commit: `8d9c4c3b108a7b5352192a6a9d7327bdf7ea19b5` (2026-10-16)
- Spec revision: OpenUI 1.0 (language.md and prompt.md, changelog entry 2026-10-12)
- License: MIT, see `LICENSE` in this folder

The files under `1.0/` are copied unchanged. To update, copy the folder from a newer
upstream commit, update the hash above, and run `mix test test/live_render/openui/conformance_test.exs`.
Never edit an `expected.json` to make a case pass.

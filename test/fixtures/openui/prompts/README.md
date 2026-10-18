# Prompt goldens

Each directory is one case for `LiveRender.OpenUI.Prompt.generate/2`:

- `input.json`: `library` (a LibrarySpec, or a path to one relative to the case directory),
  optional `libraryOverrides` (top-level LibrarySpec keys replaced before generation, such as
  `componentGroups`), and `promptOptions` (the reference's camelCase prompt options).
- `prompt.txt`: the system prompt the reference implementation renders for that input.

`test/live_render/openui/prompt_test.exs` loads each case with `Library.from_json/2`, maps the
options to snake_case and asserts the output is byte-identical to `prompt.txt`.

## How the goldens were made

The prompts were rendered by `generateSystemPrompt({ library, promptOptions })` from
`packages/lang-core/src/parser/prompt.ts` of [openui](https://github.com/thesysdev/openui) at
commit `8d9c4c3b108a7b5352192a6a9d7327bdf7ea19b5`, bundled with esbuild and run on Node 26 with
zod 4.4.3 (the version in the upstream lockfile).

```sh
# in an empty directory next to an openui checkout at the pinned commit
npm init -y
npm i zod@4.4.3 esbuild ci-info @modelcontextprotocol/sdk
cp <this dir>/cases.mjs <this dir>/generate.ts .
npx esbuild generate.ts --bundle --platform=node --format=esm --outfile=generate.bundle.mjs \
  --alias:@openui/lang-core=../openui/packages/lang-core \
  --external:zod --external:ci-info --external:@modelcontextprotocol/sdk
node cases.mjs <this dir>              # writes every input.json
node generate.bundle.mjs <this dir>    # writes every prompt.txt
```

`cases.mjs` is the source of the inputs; edit it and rerun both commands to add a case.

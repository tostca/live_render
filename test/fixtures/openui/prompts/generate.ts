// Renders prompt.txt for every case directory under the given root, with the upstream
// generateSystemPrompt({ library, promptOptions }).
import { readdirSync, readFileSync, writeFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { generateSystemPrompt } from "@openui/lang-core/src/parser/prompt";

const root = process.argv[2];

for (const name of readdirSync(root).sort()) {
  const dir = join(root, name);
  if (!statSync(dir).isDirectory()) continue;
  const input = JSON.parse(readFileSync(join(dir, "input.json"), "utf8"));
  const library =
    typeof input.library === "string"
      ? JSON.parse(readFileSync(resolve(dirname(join(dir, "input.json")), input.library), "utf8"))
      : input.library;
  const merged = { ...library, ...(input.libraryOverrides ?? {}) };
  const prompt = generateSystemPrompt({ library: merged, promptOptions: input.promptOptions });
  writeFileSync(join(dir, "prompt.txt"), prompt);
  console.log(`${name}: ${prompt.length} chars`);
}

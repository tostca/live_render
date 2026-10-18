// Writes the input.json of every prompt golden case.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = process.argv[2];
const FIXTURE = "../../1.0/library.json";

const tools = [
  "search",
  {
    name: "listTickets",
    description: "List support tickets",
    inputSchema: {
      type: "object",
      properties: {
        status: { type: "string", enum: ["open", "closed"] },
        limit: { type: "integer" },
        tags: { type: "array", items: { type: "string" } },
        filter: {
          type: "object",
          properties: { q: { type: "string" }, exact: { type: "boolean" } },
          required: ["q"],
        },
        raw: {},
        ids: { type: "array" },
      },
      required: ["status"],
    },
    outputSchema: {
      type: "object",
      properties: {
        rows: {
          type: "array",
          items: {
            type: "object",
            properties: { id: { type: "number" }, title: { type: "string" } },
            required: ["id"],
          },
        },
        total: { type: "integer" },
        ok: { type: "boolean" },
        meta: { type: "object" },
        note: { type: "string" },
        extra: { description: "untyped" },
      },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "createTicket",
    description: "Create a ticket",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" },
        priority: { type: "string", enum: ["low", "high"] },
      },
      required: ["title"],
    },
    outputSchema: { type: "string" },
    annotations: { destructiveHint: false },
  },
  { name: "ping", inputSchema: {}, outputSchema: {} },
  { name: "noOutput", description: "Has no output schema", inputSchema: { type: "object" } },
  "lookup",
];

const extras = {
  preamble: "You build support dashboards for Acme.",
  examples: [
    'root = Stack([title])\ntitle = Text("Hello", "heading")',
    'root = Stack([m])\nm = Metric("Open", 3)',
  ],
  toolExamples: [
    'root = Stack([t])\ndata = Query("listTickets", {}, {rows: []})\nt = Text("" + @Count(data.rows))',
  ],
  additionalRules: ["Keep labels short.", "Never use more than three Metric components."],
};

// Small libraries. Each is a full LibrarySpec so the Elixir side can load it with from_json.
const text = {
  type: "object",
  description: "A run of text",
  properties: { text: { type: "string" } },
  required: ["text"],
};

const minimal = {
  root: "Card",
  schema: {
    properties: { Card: { $ref: "#/$defs/Card" } },
    $defs: {
      Card: {
        type: "object",
        description: "Root",
        properties: { children: { type: "array" } },
        required: ["children"],
      },
    },
  },
  components: { Card: { signature: "Card(children: Component[])", description: "Root" } },
};

const customActionsOnly = {
  root: "Text",
  schema: {
    properties: { Text: { $ref: "#/$defs/Text" } },
    $defs: { Text: text },
    actions: {
      CopyToClipboard: {
        description: "Copies text to the clipboard",
        params: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
      },
      Notify: {
        description: "",
        params: { type: "object", properties: {}, required: [] },
      },
    },
  },
  components: { Text: { signature: "Text(text: string)", description: "A run of text" } },
  actions: {
    CopyToClipboard: {
      signature: "CopyToClipboard(text: string)",
      description: "Copies text to the clipboard",
    },
    Notify: { signature: "Notify()", description: "" },
  },
};

const customFunctionsOnly = {
  root: "Text",
  schema: {
    properties: { Text: { $ref: "#/$defs/Text" }, Note: { $ref: "#/$defs/Note" } },
    $defs: {
      Text: text,
      Note: { type: "object", properties: { body: { type: "string" } }, required: ["body"] },
    },
    functions: {
      Percent: {
        description: "Formats part / total",
        params: {
          type: "object",
          properties: { part: { type: "number" }, total: { type: "number" } },
          required: ["part"],
        },
        returns: { type: "string" },
      },
      Today: {
        description: "",
        params: { type: "object", properties: {}, required: [] },
        returns: { type: "string" },
      },
    },
  },
  components: {
    Text: { signature: "Text(text: string)", description: "A run of text" },
    Note: { signature: "Note(body: string)", description: "" },
  },
  functions: {
    Percent: {
      signature: "Percent(part: number, total?: number) → string",
      description: "Formats part / total",
    },
    Today: { signature: "Today() → string", description: "" },
  },
};

const noRoot = {
  schema: {
    properties: { Field: { $ref: "#/$defs/Field" } },
    $defs: {
      Field: {
        type: "object",
        description: "A bound text field",
        properties: { value: { type: "string" } },
        required: [],
      },
    },
  },
  components: {
    Field: { signature: "Field(value?: $binding<string>)", description: "A bound text field" },
  },
};

const groups = [
  {
    name: "Layout",
    components: ["Stack", "Card"],
    notes: ["- Use Stack for rows and columns.", "- Card needs a title."],
  },
  { name: "Content", components: ["Text", "Tag", "Metric", "Card"] },
  { name: "Forms", components: ["Form", "Input", "Select", "SelectItem", "Button"], notes: [] },
];

const cases = {
  "fixture-default": { library: FIXTURE, promptOptions: {} },
  "fixture-bindings": { library: FIXTURE, promptOptions: { bindings: true } },
  "fixture-tool-calls-no-bindings": {
    library: FIXTURE,
    promptOptions: { toolCalls: true, bindings: false },
  },
  "fixture-builtin-functions": { library: FIXTURE, promptOptions: { builtinFunctions: true } },
  "fixture-tool-calls-without-builtins": {
    library: FIXTURE,
    promptOptions: { toolCalls: true, builtinFunctions: false },
  },
  "fixture-edit-inline": { library: FIXTURE, promptOptions: { editMode: true, inlineMode: true } },
  "fixture-extras": { library: FIXTURE, promptOptions: extras },
  "fixture-tools": { library: FIXTURE, promptOptions: { tools } },
  "fixture-tools-tool-calls-off": { library: FIXTURE, promptOptions: { tools, toolCalls: false } },
  "fixture-tools-bindings-off": {
    library: FIXTURE,
    promptOptions: { tools: ["search"], bindings: false },
  },
  "fixture-everything": {
    library: FIXTURE,
    promptOptions: { tools, editMode: true, inlineMode: true, ...extras },
  },
  "fixture-groups": {
    library: FIXTURE,
    libraryOverrides: { componentGroups: groups },
    promptOptions: { bindings: true },
  },
  "fixture-groups-all-grouped": {
    library: FIXTURE,
    libraryOverrides: {
      componentGroups: [
        {
          name: "Everything",
          components: [
            "Col", "Table", "SelectItem", "Select", "Input", "Form",
            "Button", "Metric", "Tag", "Text", "Card", "Stack",
          ],
        },
      ],
    },
    promptOptions: {},
  },
  "minimal-default": { library: minimal, promptOptions: {} },
  "minimal-bindings": { library: minimal, promptOptions: { bindings: true } },
  "minimal-tools": { library: minimal, promptOptions: { tools: ["search"] } },
  "custom-actions-only": { library: customActionsOnly, promptOptions: {} },
  "custom-actions-only-tool-calls": { library: customActionsOnly, promptOptions: { toolCalls: true } },
  "custom-functions-only": { library: customFunctionsOnly, promptOptions: {} },
  "custom-functions-tool-calls-without-builtins": {
    library: customFunctionsOnly,
    promptOptions: { toolCalls: true, builtinFunctions: false },
  },
  "no-root-binding-signature": { library: noRoot, promptOptions: {} },
};

for (const [name, input] of Object.entries(cases)) {
  mkdirSync(join(out, name), { recursive: true });
  writeFileSync(join(out, name, "input.json"), JSON.stringify(input, null, 2) + "\n");
}
console.log(`wrote ${Object.keys(cases).length} cases`);

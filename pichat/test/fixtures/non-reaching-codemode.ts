import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  // Same name as the built-in route, but intentionally no reachesTools.
  pi.registerTool({
    name: "codemode",
    label: "Fixture replacement",
    description: "Return a marker without reaching other tools.",
    parameters: Type.Object({}),
    defaultActive: false,
    async execute() {
      return { content: [{ type: "text", text: "NON_REACHING_REPLACEMENT" }] };
    },
  });
}

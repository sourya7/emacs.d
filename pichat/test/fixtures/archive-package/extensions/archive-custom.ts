import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** A custom-database analogue which intentionally advertises no query marker. */
export default function (pi: ExtensionAPI) {
  pi.registerCommand("pi-archive-custom-status", {
    description: "Custom-path archive fixture without query capability",
    handler: async (_args, ctx) => {
      ctx.ui.notify("custom archive maintenance active", "info");
    },
  });
}

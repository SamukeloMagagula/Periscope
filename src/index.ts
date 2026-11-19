#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runAction, ActionDeniedError } from "./pipe-client.js";

// This server itself does no process spawning and owns no GUI - it's a thin client over the
// named pipe that assets/host.ps1 (the persistent background process, launched via the
// desktop icon) serves. If host.ps1 isn't running, runAction's errors say so clearly.

const CONFIRM_DISABLED = process.env.PERISCOPE_CONFIRM === "0";

const server = new McpServer({
  name: "periscope",
  version: "0.1.0",
});

function withConfirmFlag(params: Record<string, unknown>) {
  return CONFIRM_DISABLED ? { ...params, skipConfirm: true } : params;
}

async function callAction(action: string, params: Record<string, unknown> = {}) {
  try {
    const result = await runAction(action, withConfirmFlag(params));
    return {
      content: [{ type: "text" as const, text: JSON.stringify(result ?? {}) }],
    };
  } catch (err) {
    if (err instanceof ActionDeniedError) {
      return {
        content: [{ type: "text" as const, text: `Denied by user: ${err.message}` }],
        isError: true,
      };
    }
    return {
      content: [{ type: "text" as const, text: `Error: ${(err as Error).message}` }],
      isError: true,
    };
  }
}

server.registerTool(
  "screenshot",
  {
    title: "Take a screenshot",
    description:
      "Capture the screen (or one monitor) and return it as a PNG image. Read-only, no confirmation needed.",
    inputSchema: {
      monitor: z
        .number()
        .int()
        .optional()
        .describe("Monitor index to capture (from list_screens). Omit to capture the full virtual desktop."),
    },
  },
  async ({ monitor }) => {
    const dir = await mkdtemp(join(tmpdir(), "periscope-shot-"));
    const outPath = join(dir, "shot.png");
    try {
      await runAction("screenshot", { outPath, monitor });
      const buf = await readFile(outPath);
      return {
        content: [
          {
            type: "image" as const,
            data: buf.toString("base64"),
            mimeType: "image/png",
          },
        ],
      };
    } catch (err) {
      return {
        content: [{ type: "text" as const, text: `Error: ${(err as Error).message}` }],
        isError: true,
      };
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }
);

server.registerTool(
  "list_screens",
  {
    title: "List monitors",
    description: "List connected monitors with their index, bounds and which one is primary.",
    inputSchema: {},
  },
  async () => callAction("listScreens")
);

server.registerTool(
  "move_mouse",
  {
    title: "Move mouse",
    description:
      "Move the mouse cursor to absolute screen coordinates (x, y). A blue ring flashes at the target point " +
      "first so it's visually obvious where the agent is acting. Asks for confirmation first (skipped during an active start_task window).",
    inputSchema: {
      x: z.number().int(),
      y: z.number().int(),
    },
  },
  async ({ x, y }) => callAction("moveMouse", { x, y })
);

server.registerTool(
  "click",
  {
    title: "Click mouse",
    description:
      "Move the mouse to (x, y) and click. button: left|right|middle. count: 1 for single click, 2 for double-click. " +
      "A blue ring flashes at the target point first. Asks for confirmation first (skipped during an active start_task window).",
    inputSchema: {
      x: z.number().int(),
      y: z.number().int(),
      button: z.enum(["left", "right", "middle"]).optional(),
      count: z.number().int().min(1).max(3).optional(),
    },
  },
  async ({ x, y, button, count }) => callAction("click", { x, y, button, count })
);

server.registerTool(
  "type_text",
  {
    title: "Type text",
    description:
      "Type literal text at the current keyboard focus, as if typed on the keyboard. Asks for confirmation first.",
    inputSchema: {
      text: z.string(),
    },
  },
  async ({ text }) => callAction("typeText", { text })
);

server.registerTool(
  "send_keys",
  {
    title: "Send key combo",
    description:
      "Send a raw key combination using Windows SendKeys syntax, e.g. '^c' for Ctrl+C, '%{TAB}' for Alt+Tab, " +
      "'{ENTER}', '^{ESC}' for the Start menu. Asks for confirmation first.",
    inputSchema: {
      keys: z.string(),
    },
  },
  async ({ keys }) => callAction("sendKeys", { keys })
);

server.registerTool(
  "list_windows",
  {
    title: "List open windows",
    description: "List top-level windows with their process id, title, position/size and minimized state.",
    inputSchema: {},
  },
  async () => callAction("listWindows")
);

server.registerTool(
  "focus_window",
  {
    title: "Focus a window",
    description: "Restore (if minimized) and bring a window to the foreground by process id. Asks for confirmation first.",
    inputSchema: {
      pid: z.number().int(),
    },
  },
  async ({ pid }) => callAction("focusWindow", { pid })
);

server.registerTool(
  "get_clipboard",
  {
    title: "Read clipboard",
    description: "Read the current text contents of the system clipboard. Read-only, no confirmation needed.",
    inputSchema: {},
  },
  async () => callAction("getClipboard")
);

server.registerTool(
  "set_clipboard",
  {
    title: "Write clipboard",
    description: "Set the system clipboard to the given text. Asks for confirmation first.",
    inputSchema: {
      text: z.string(),
    },
  },
  async ({ text }) => callAction("setClipboard", { text })
);

server.registerTool(
  "start_task",
  {
    title: "Start an autonomous task",
    description:
      "Begin an autonomous run: pops ONE confirmation dialog describing the task, and if approved, subsequent " +
      "mutating actions (click, type_text, send_keys, move_mouse, focus_window, set_clipboard) skip their " +
      "individual confirmation prompts until end_task is called or (if a duration was given) the time limit " +
      "expires. With no 'minutes' argument this runs indefinitely, until end_task is called or the user hits " +
      "Stop on the HUD panel — there is no default timeout. The HUD panel shows the task is active with a " +
      "one-click Stop button the whole time, as an independent kill-switch. Use this for multi-step work the " +
      "user has already approved at a high level; always call end_task when the task is actually done, even " +
      "if running indefinitely, rather than leaving it open.",
    inputSchema: {
      description: z.string().describe("Plain-English description of what you're about to do, shown in the confirmation dialog and the HUD."),
      minutes: z.number().int().min(1).optional().describe("Optional time limit in minutes. Omit for an indefinite run (until end_task or the HUD Stop button)."),
    },
  },
  async ({ description, minutes }) => callAction("startTask", { description, minutes })
);

server.registerTool(
  "end_task",
  {
    title: "End the autonomous task",
    description: "Ends the current autonomous run (if any), restoring per-action confirmation prompts.",
    inputSchema: {},
  },
  async () => callAction("endTask")
);

const transport = new StdioServerTransport();
await server.connect(transport);

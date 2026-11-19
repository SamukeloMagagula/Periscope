import { connect } from "node:net";

const PIPE_PATH = "\\\\.\\pipe\\PeriscopeActionPipe";
const CONNECT_TIMEOUT_MS = 5000;

export class ActionDeniedError extends Error {}

export async function runAction(action: string, params: Record<string, unknown> = {}): Promise<unknown> {
  const request = JSON.stringify({ action, params }) + "\n";

  return new Promise((resolve, reject) => {
    const socket = connect(PIPE_PATH);
    let buffer = "";
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(new Error("Periscope host didn't respond in time."));
    }, CONNECT_TIMEOUT_MS);

    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };

    socket.on("connect", () => {
      socket.write(request);
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      if (!buffer.includes("\n")) return;
      finish(() => {
        // destroy(), not end(): end() only half-closes the write side, leaving the read side
        // open - when the server then disconnects its end of the pipe, that lingering read
        // surfaces as a trailing EPIPE "error" event that (found via live testing) crashed the
        // whole process as an uncaught exception despite the error listener below being
        // registered. destroy() tears down both directions immediately, so there's nothing
        // left open for that trailing event to fire on.
        socket.destroy();
        const line = buffer.split("\n")[0].trim();
        let parsed: { ok: boolean; result?: unknown; error?: string; denied?: boolean };
        try {
          parsed = JSON.parse(line);
        } catch {
          reject(new Error(`Malformed response from Periscope host: ${line}`));
          return;
        }
        if (!parsed.ok) {
          if (parsed.denied) {
            reject(new ActionDeniedError(parsed.error ?? "Action denied"));
          } else {
            reject(new Error(parsed.error ?? "Unknown error from Periscope host"));
          }
          return;
        }
        resolve(parsed.result ?? null);
      });
    });

    socket.on("error", (err: NodeJS.ErrnoException) => {
      finish(() => {
        if (err.code === "ENOENT") {
          reject(new Error("Periscope isn't running - double-click the Periscope icon on your desktop first."));
        } else {
          reject(err);
        }
      });
    });

    socket.on("close", () => {
      finish(() => {
        reject(new Error("Periscope host closed the connection without responding."));
      });
    });
  });
}

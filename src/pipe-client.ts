import { connect } from "node:net";

const PIPE_PATH = "\\\\.\\pipe\\PeriscopeActionPipe";
// Two different concerns, two different timeouts. Connecting to the pipe either succeeds
// near-instantly or fails near-instantly with ENOENT (host.py isn't running) - 5s is plenty
// and gives quick, clear feedback either way. But WAITING FOR A RESPONSE after that is a
// different matter: a mutating action pops a confirm dialog a human needs to notice and
// click, which Periscope deliberately allows up to CONFIRM_TIMEOUT_SEC (120s, see
// python/avatar.py) to happen before auto-denying. A single 5s timeout covering both phases
// meant every confirm dialog that took a human more than 5 seconds to notice and approve
// produced a false "didn't respond in time" error here even though the action went through
// fine on the Python side moments later - found live, this was very likely the dominant
// real-world cause of "it just froze/errored" reports, not an edge case at all.
const CONNECT_TIMEOUT_MS = 5000;
const RESPONSE_TIMEOUT_MS = 150_000; // comfortably longer than the 120s confirm-dialog window

export class ActionDeniedError extends Error {}

export async function runAction(action: string, params: Record<string, unknown> = {}): Promise<unknown> {
  const request = JSON.stringify({ action, params }) + "\n";

  return new Promise((resolve, reject) => {
    const socket = connect(PIPE_PATH);
    let buffer = "";
    let settled = false;

    let timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.destroy();
      // A hang here (as opposed to the fast ENOENT the 'error' handler below normally gets
      // when host.py genuinely isn't running) is unusual enough not to presume a specific
      // cause.
      reject(new Error("Couldn't connect to the Periscope host in time - is it running?"));
    }, CONNECT_TIMEOUT_MS);

    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };

    socket.on("connect", () => {
      clearTimeout(timer);
      // Swap to the long response window now that we're actually connected - from here on,
      // any further delay is the action (and a possible confirm dialog) running, not a
      // connection problem.
      timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        socket.destroy();
        reject(new Error("Periscope host didn't respond in time."));
      }, RESPONSE_TIMEOUT_MS);
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

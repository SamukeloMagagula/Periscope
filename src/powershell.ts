import { spawn } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RUN_PS1 = join(__dirname, "..", "assets", "run.ps1");

export class ActionDeniedError extends Error {}

export async function runAction(action: string, params: Record<string, unknown> = {}): Promise<unknown> {
  const dir = await mkdtemp(join(tmpdir(), "periscope-"));
  const paramsFile = join(dir, "params.json");
  await writeFile(paramsFile, JSON.stringify(params), "utf8");

  try {
    const { stdout, stderr, code } = await execPowerShell([
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      RUN_PS1,
      "-Action",
      action,
      "-ParamsFile",
      paramsFile,
    ]);

    if (code !== 0) {
      const message = (stderr || stdout).trim();
      if (/User denied the action/.test(message)) {
        throw new ActionDeniedError(message);
      }
      throw new Error(message || `PowerShell exited with code ${code}`);
    }

    const trimmed = stdout.trim();
    return trimmed ? JSON.parse(trimmed) : null;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

function execPowerShell(args: string[]): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((resolve, reject) => {
    const child = spawn("powershell.exe", args, { windowsHide: true });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", reject);
    child.on("close", (code) => resolve({ stdout, stderr, code: code ?? -1 }));
  });
}

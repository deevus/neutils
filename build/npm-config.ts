import { ZON } from "zzon";

export type Target = {
  triple: string;
  os: string;
  cpu: string;
  exe_ext?: string;
};
export type Tool = { name: string; description: string };
export type NpmCfg = { scope: string; tools: Tool[]; targets: Target[] };

export async function loadNpmConfig(): Promise<{ version: string; cfg: NpmCfg }> {
  const [versionZon, cfgZon] = await Promise.all([
    Bun.file("build.zig.zon").text(),
    Bun.file("build/npm.zon").text(),
  ]);
  const version = (ZON.parse(versionZon) as { version: string }).version;
  const cfg = ZON.parse(cfgZon) as NpmCfg;
  return { version, cfg };
}

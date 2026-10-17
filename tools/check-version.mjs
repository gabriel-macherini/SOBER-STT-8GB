// Build invariants. version.txt is the single source of truth: fails when
// installer/sober-stt.iss AppVersion, the CHANGELOG header, the docs/building.md
// build example, voice-tray.ahk APPVER or the exe version resource drift from
// it. Also fails when a file the installer ships verbatim has CRLF endings,
// which would stop the installed app from matching the repository byte for byte.
import fs from "node:fs";

const ver = fs.readFileSync(new URL("../version.txt", import.meta.url), "utf8").trim();
let fail = 0;
const check = (name, cond, extra = "") => {
  console.log(`${cond ? "PASS" : "FAIL"} ${name}${extra ? " | " + extra : ""}`);
  if (!cond) fail++;
};

const iss = fs.readFileSync(new URL("../installer/sober-stt.iss", import.meta.url), "utf8");
check("iss-AppVersion", iss.includes(`#define AppVersion "${ver}"`), `version.txt=${ver}`);

const log = fs.readFileSync(new URL("../CHANGELOG.md", import.meta.url), "utf8");
check("changelog-header", log.includes(`## [${ver}]`), `## [${ver}]`);

const docs = fs.readFileSync(new URL("../docs/building.md", import.meta.url), "utf8");
check("building-example", docs.includes(`SOBER-STT-Setup-${ver}.exe`), `Setup-${ver}.exe`);

const ahk = fs.readFileSync(new URL("../voice-tray.ahk", import.meta.url), "utf8");
check("ahk-APPVER", ahk.includes(`APPVER := "${ver}"`), `APPVER=${ver}`);
check(
  "ahk-version-resource",
  ahk.includes(`;@Ahk2Exe-SetFileVersion ${ver}`) && ahk.includes(`;@Ahk2Exe-SetProductVersion ${ver}`),
  `exe properties=${ver}`,
);

// Everything the installer copies verbatim or compiles.
const shipped = ["runner.mjs", "rec-host.ps1", "config.json", "voice-tray.ahk", "locale.ahk", "lib", "prompts"];
const crlf = [];
const scan = (rel) => {
  const url = new URL(`../${rel}`, import.meta.url);
  if (fs.statSync(url).isDirectory()) {
    for (const entry of fs.readdirSync(url)) scan(`${rel}/${entry}`);
  } else if (fs.readFileSync(url).includes(13)) {
    crlf.push(rel);
  }
};
shipped.forEach(scan);
check("eol-lf", crlf.length === 0, crlf.length ? `CRLF in ${crlf.join(", ")}` : `${shipped.length} paths`);

process.exit(fail ? 1 : 0);

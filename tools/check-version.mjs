// M4: single source of truth for the version is version.txt. Fails when
// installer/sober-stt.iss AppVersion, the CHANGELOG header, the README
// build example, or voice-tray.ahk APPVER drift from it.
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

const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8");
check("readme-example", readme.includes(`SOBER-STT-Setup-${ver}.exe`), `Setup-${ver}.exe`);

const ahk = fs.readFileSync(new URL("../voice-tray.ahk", import.meta.url), "utf8");
check("ahk-APPVER", ahk.includes(`APPVER := "${ver}"`), `APPVER=${ver}`);

process.exit(fail ? 1 : 0);

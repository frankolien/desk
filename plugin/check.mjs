// Checks the package against OpenAI's plugin portal rules before it is zipped, so an edit
// can't turn into a rejected upload. Prints what is still missing for review, and exits
// non-zero on anything the portal would refuse.
import { existsSync, readFileSync, readdirSync } from "node:fs";

const root = new URL("./", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");
const errors = [];
const notes = [];
const fail = (message) => errors.push(message);

const manifest = JSON.parse(read("plugin.json"));
const openai = manifest.extensions?.["com.openai"] ?? {};
const ui = openai.interface ?? {};

if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(manifest.name ?? "") || manifest.name.length > 64) fail("name: lowercase letters, digits and single hyphens, at most 64");
if (!/^\d+\.\d+\.\d+$/.test(manifest.version ?? "")) fail("version: semantic version");

const text = (field, max) => {
  const value = ui[field];
  if (typeof value !== "string" || !value.trim()) return fail(`interface.${field} is required`);
  if (value.length > max) fail(`interface.${field} is ${value.length} characters; the limit is ${max}`);
  if (max <= 80 && /[\n\t]/.test(value)) fail(`interface.${field} must fit on one line`);
};
text("displayName", 30);
text("shortDescription", 30);
text("longDescription", 4000);
text("developerName", 80);
text("category", 80);

for (const field of ["websiteURL", "supportURL", "privacyPolicyURL", "termsOfServiceURL"]) {
  const url = ui[field];
  if (typeof url !== "string" || !url.startsWith("https://") || url.length > 1024) fail(`interface.${field} must be an HTTPS URL of at most 1,024 characters`);
}

const capabilities = ui.capabilities ?? [];
if (capabilities.length > 20) fail("interface.capabilities: at most 20");
for (const capability of capabilities) if (!capability.trim() || capability.length > 120) fail(`capability "${capability}" must be 1 to 120 characters`);

const prompts = [].concat(ui.defaultPrompt ?? []);
if (prompts.length > 3) fail("interface.defaultPrompt: at most three");
if (new Set(prompts.map((p) => p.normalize("NFKC").trim().toLowerCase())).size !== prompts.length) fail("interface.defaultPrompt entries must be unique");
for (const prompt of prompts) {
  if (prompt.length > 128) fail(`starter prompt is over 128 characters: "${prompt}"`);
  if (/@\w/.test(prompt)) fail(`starter prompts can't @mention a server: "${prompt}"`);
}

const luminance = (hex) => {
  const channel = (i) => { const c = parseInt(hex.slice(i, i + 2), 16) / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
};
const contrast = (a, b) => { const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x); return (hi + 0.05) / (lo + 0.05); };
for (const [field, against] of [["brandColor", "#FFFFFF"], ["brandColorDark", "#212121"]]) {
  const color = ui[field];
  if (color === undefined) continue;
  if (!/^#[0-9A-Fa-f]{6}$/.test(color)) fail(`interface.${field} must be #RRGGBB`);
  else if (contrast(color, against) < 2) fail(`interface.${field} ${color} has ${contrast(color, against).toFixed(2)}:1 against ${against}; 2:1 is the minimum`);
}

/// A PNG's size, straight from its IHDR chunk.
function pngSize(path) {
  const bytes = readFileSync(new URL(path, root));
  if (bytes.toString("ascii", 1, 4) !== "PNG") return null;
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), size: bytes.length };
}
for (const field of ["logo", "logoDark", "composerIcon", "composerIconDark"]) {
  const path = ui[field];
  if (!path) { if (field === "logo" || field === "composerIcon") fail(`interface.${field} is required`); continue; }
  if (!path.startsWith("./") || !existsSync(new URL(path, root))) { fail(`interface.${field}: ${path} must be a ./ path to an included file`); continue; }
  const size = pngSize(path);
  if (!size) fail(`interface.${field}: ${path} isn't a PNG`);
  else if (size.width !== size.height || size.width < 48 || size.width > 4096 || size.size > 5 * 1024 * 1024) fail(`interface.${field}: icons are square PNGs, 48 to 4096 px, at most 5 MiB`);
}

const mcp = JSON.parse(read("mcp.json"));
const servers = Object.entries(mcp.mcpServers ?? {});
if (servers.length !== 1) fail("mcp.json: exactly one MCP server, so plugin-level test cases apply");
for (const [name, server] of servers) {
  if (!name.trim()) fail("mcp.json: every server needs a name");
  if (!String(server.url ?? "").startsWith("https://")) fail(`mcp.json: ${name} needs a public HTTPS url`);
  if (server.headers && Object.keys(server.headers).length) fail(`mcp.json: ${name} can't carry headers in a public submission`);
}

// Tool names the test cases name have to exist on the server.
const serverSource = readFileSync(new URL("../web/api/_mcp.mjs", root), "utf8");
const tools = new Set([...serverSource.matchAll(/tool\("([a-z_]+)"/g)].map((match) => match[1]));
const cases = openai.review?.test_cases ?? {};
const positive = cases.positive ?? [];
const negative = cases.negative ?? [];
if (positive.length !== 5) fail(`review: ${positive.length} positive test cases; review needs exactly five`);
if (negative.length !== 3) fail(`review: ${negative.length} negative test cases; review needs exactly three`);
for (const testCase of positive) {
  if (!testCase.description || !testCase.prompt || !testCase.tools_triggered || !testCase.expected_behavior) fail(`positive case "${testCase.description}" needs description, prompt, tools_triggered and expected_behavior`);
  for (const name of String(testCase.tools_triggered ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    if (!tools.has(name)) fail(`positive case "${testCase.description}" names ${name}, which the server doesn't have`);
  }
}
for (const testCase of negative) if (!testCase.description || !testCase.prompt) fail(`negative case "${testCase.description}" needs a description and a prompt`);
for (const forbidden of ["test_credentials", "reviewer_instructions"]) if (openai.review?.[forbidden] !== undefined) fail(`review.${forbidden} can't be in the package`);
if (!openai.review?.demo_recording_url) notes.push("review.demo_recording_url is still empty: record the walkthrough and add its URL before submitting");

const skills = existsSync(new URL("skills", root)) ? readdirSync(new URL("skills", root), { withFileTypes: true }).filter((entry) => entry.isDirectory()) : [];
if (!skills.length) fail("a public submission needs at least one skill in skills/");
for (const skill of skills) {
  if (skill.name.startsWith(".")) fail(`skills/${skill.name}: hidden directories aren't allowed`);
  const path = `skills/${skill.name}/SKILL.md`;
  if (!existsSync(new URL(path, root))) { fail(`${path} is missing`); continue; }
  const body = read(path);
  const front = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(body);
  if (!front) { fail(`${path} must open with YAML front matter between --- lines`); continue; }
  const field = (key) => [...front[1].matchAll(/^(\w+):\s*(.*)$/gm)].find((match) => match[1] === key)?.[2]?.trim();
  const name = field("name"), description = field("description");
  if (!name) fail(`${path}: name is required`);
  if (!description) fail(`${path}: description is required`);
  else if (description.length > 1024) fail(`${path}: description is over 1,024 characters`);
  if (name && `${manifest.name}:${name}`.length > 64) fail(`${path}: ${manifest.name}:${name} is over 64 characters`);
  if (!front[2].trim()) fail(`${path}: the instructions are empty`);
}

for (const note of notes) console.log(`note: ${note}`);
if (errors.length) {
  for (const error of errors) console.error(`error: ${error}`);
  process.exit(1);
}
console.log(`plugin ok: ${manifest.name} ${manifest.version}, ${tools.size} tools on the server, ${skills.length} skill${skills.length === 1 ? "" : "s"}`);

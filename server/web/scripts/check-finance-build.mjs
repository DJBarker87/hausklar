import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { gzipSync } from "node:zlib";

const webRoot = resolve(import.meta.dirname, "..");
const distRoot = resolve(webRoot, "dist");
const manifest = JSON.parse(readFileSync(resolve(distRoot, ".vite/manifest.json"), "utf8"));

function entryFiles(entryKey, files = new Set()) {
  const entry = manifest[entryKey];
  if (!entry) throw new Error(`Missing build manifest entry: ${entryKey}`);
  if (entry.file) files.add(entry.file);
  for (const stylesheet of entry.css ?? []) files.add(stylesheet);
  for (const imported of entry.imports ?? []) entryFiles(imported, files);
  return files;
}

function bundle(entries, includeDocument = false) {
  const files = new Set();
  entries.forEach((entry) => entryFiles(entry, files));
  if (includeDocument) files.add("index.html");
  let rawBytes = 0;
  let gzipBytes = 0;
  for (const file of files) {
    const contents = readFileSync(resolve(distRoot, file));
    rawBytes += contents.byteLength;
    gzipBytes += gzipSync(contents).byteLength;
  }
  return { files, rawBytes, gzipBytes };
}

function kib(bytes) {
  return `${(bytes / 1024).toFixed(1)} KiB`;
}

function assertBudget(label, actual, maximum) {
  if (actual > maximum) {
    throw new Error(`${label} is ${kib(actual)}; budget is ${kib(maximum)}.`);
  }
}

const initial = bundle(["index.html"], true);
const financeBase = bundle(["index.html", "src/views/FinanceView.tsx"], true);
const simplePlan = bundle([
  "index.html",
  "src/views/FinanceView.tsx",
  "src/views/FinancePlansView.tsx",
], true);
const initialCSS = [...initial.files]
  .filter((file) => file.endsWith(".css"))
  .reduce((total, file) => total + gzipSync(readFileSync(resolve(distRoot, file))).byteLength, 0);

assertBudget("Initial shell (gzip)", initial.gzipBytes, 175 * 1024);
assertBudget("Initial CSS (gzip)", initialCSS, 40 * 1024);
assertBudget("Finance base added to the shell (gzip)", financeBase.gzipBytes - initial.gzipBytes, 60 * 1024);
assertBudget("Cold Simple Savings plan (gzip)", simplePlan.gzipBytes, 245 * 1024);
if (simplePlan.files.size > 45) {
  throw new Error(`Cold Simple Savings plan needs ${simplePlan.files.size} files; budget is 45.`);
}

console.log(
  `Finance bundle budgets passed: shell ${kib(initial.gzipBytes)}, `
  + `Finance +${kib(financeBase.gzipBytes - initial.gzipBytes)}, `
  + `Simple plan ${kib(simplePlan.gzipBytes)} across ${simplePlan.files.size} files.`,
);

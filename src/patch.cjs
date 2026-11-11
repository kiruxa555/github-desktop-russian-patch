'use strict';

const fs = require('fs');
const path = require('path');
const maps = require(path.join(__dirname, 'ru-map.cjs'));
const dangerWords = new Set(require(path.join(__dirname, 'danger-words.json')));

function parseArgs(argv) {
  const result = { dryRun: false, appDir: null, reportPath: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--dry') {
      result.dryRun = true;
    } else if (arg === '--app' && argv[i + 1]) {
      result.appDir = path.resolve(argv[++i]);
    } else if (arg === '--report' && argv[i + 1]) {
      result.reportPath = path.resolve(argv[++i]);
    } else {
      throw new Error(`Неизвестный или неполный аргумент: ${arg}`);
    }
  }
  if (!result.appDir) {
    throw new Error('Укажи папку с main.js и renderer.js через --app <путь>.');
  }
  return result;
}

function plainKey(value) {
  return value.replace(/&/g, '').replace(/\u2026/g, '').replace(/\.\.\./g, '').trim();
}

function isContextDangerous(source, english) {
  const quoted = `"${english}"`;
  const patterns = [
    `=${quoted}`,
    `${quoted}===`,
    `===${quoted}`,
    `||${quoted}`,
    `?${quoted}`,
    `case${quoted}`,
    `case ${quoted}`,
    `[${quoted}]`,
    `['${english}']`,
  ];
  return patterns.some(pattern => source.includes(pattern));
}

function shouldSkip(source, english) {
  if (english === 'Filter' || english === 'Options' || english === 'Remove…') {
    return false;
  }
  // Directed replacements reach inside minified expressions. They are useful
  // for a few hard-coded labels, but are too version-sensitive for an
  // installable patch. Keep the default patch limited to whole string values.
  if (english.includes('"')) {
    return true;
  }
  const menuLabel = english.includes('&');
  if (!menuLabel && dangerWords.has(plainKey(english))) {
    return true;
  }
  return !menuLabel && !/\s/.test(english) && isContextDangerous(source, english);
}

function occurrences(source, needle) {
  if (needle.length === 0) return 0;
  return source.split(needle).length - 1;
}

function replaceEntries(source, entries, wrapper, report, category) {
  let updated = source;
  const sorted = Object.entries(entries || {}).sort((a, b) => b[0].length - a[0].length);
  for (const [english, russian] of sorted) {
    if (category === 'string' && shouldSkip(updated, english)) {
      report.skipped.push(english);
      continue;
    }

    const raw = category === 'string' && english.includes('"');
    const needle = raw ? english : wrapper(english);
    const replacement = raw ? russian : wrapper(russian);
    const found = occurrences(updated, needle);
    if (found === 0) {
      if (updated.includes(replacement)) {
        report.alreadyPatched.push(english);
      } else {
        report.missing.push(english);
      }
      continue;
    }

    updated = updated.split(needle).join(replacement);
    report.applied.push({
      english,
      russian,
      needle,
      replacement,
      occurrences: found,
      category,
    });
  }
  return updated;
}

function replaceRawEntries(source, entries, report) {
  let updated = source;
  const sorted = Object.entries(entries || {}).sort((a, b) => b[0].length - a[0].length);
  for (const [english, russian] of sorted) {
    const found = occurrences(updated, english);
    if (found === 0) {
      if (updated.includes(russian)) {
        report.alreadyPatched.push(english);
      } else {
        report.missing.push(english);
      }
      continue;
    }

    updated = updated.split(english).join(russian);
    report.applied.push({
      english,
      russian,
      needle: english,
      replacement: russian,
      occurrences: found,
      category: 'fragment',
    });
  }
  return updated;
}

function patchFile(filePath, stringMap, templateMap, fragmentMap, dryRun) {
  const original = fs.readFileSync(filePath, 'utf8');
  const report = {
    file: filePath,
    originalBytes: Buffer.byteLength(original, 'utf8'),
    applied: [],
    alreadyPatched: [],
    missing: [],
    skipped: [],
  };

  let updated = replaceEntries(original, templateMap, value => `\`${value}\``, report, 'template');
  updated = replaceEntries(updated, stringMap, value => `"${value}"`, report, 'string');
  updated = replaceRawEntries(updated, fragmentMap, report);
  report.updatedBytes = Buffer.byteLength(updated, 'utf8');
  report.changed = updated !== original;

  if (!dryRun && report.changed) {
    const temporaryPath = `${filePath}.ru-patch-tmp`;
    fs.writeFileSync(temporaryPath, updated, 'utf8');
    fs.renameSync(temporaryPath, filePath);
  }
  return report;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const mainPath = path.join(args.appDir, 'main.js');
  const rendererPath = path.join(args.appDir, 'renderer.js');
  for (const required of [mainPath, rendererPath]) {
    if (!fs.existsSync(required)) {
      throw new Error(`Не найден файл GitHub Desktop: ${required}`);
    }
  }

  const reports = [
    patchFile(mainPath, maps.main, maps.mainTemplates, null, args.dryRun),
    patchFile(rendererPath, maps.renderer, maps.templates, maps.rendererFragments, args.dryRun),
  ];

  const summary = {
    dryRun: args.dryRun,
    generatedAt: new Date().toISOString(),
    files: reports,
    totals: {
      appliedKeys: reports.reduce((sum, item) => sum + item.applied.length, 0),
      appliedOccurrences: reports.reduce(
        (sum, item) => sum + item.applied.reduce((inner, entry) => inner + entry.occurrences, 0),
        0
      ),
      missingKeys: reports.reduce((sum, item) => sum + item.missing.length, 0),
      skippedKeys: reports.reduce((sum, item) => sum + item.skipped.length, 0),
      changedFiles: reports.filter(item => item.changed).length,
    },
  };

  const serialized = JSON.stringify(summary, null, 2);
  if (args.reportPath) {
    fs.writeFileSync(args.reportPath, serialized, 'utf8');
  }
  process.stdout.write(`${serialized}\n`);

  if (summary.totals.changedFiles === 0 && summary.totals.appliedKeys === 0) {
    process.exitCode = 2;
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`Ошибка патча: ${error.stack || error.message}\n`);
  process.exitCode = 1;
}

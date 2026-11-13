'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const [reportPath, outputPath, ...variantArgs] = process.argv.slice(2);
if (!reportPath || !outputPath || variantArgs.length < 3 || variantArgs.length % 3 !== 0) {
  throw new Error(
    'Usage: node build-manifest.cjs <report.json> <output.json> <app-directory> <original-dir> <patched-dir> [<app-directory> <original-dir> <patched-dir> ...]'
  );
}

function hash(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex').toUpperCase();
}

function operationsFor(report, fileName) {
  const fileReport = report.files.find(item => path.basename(item.file) === fileName);
  if (!fileReport) {
    throw new Error(`Missing report for ${fileName}`);
  }
  return fileReport.applied.map(item => ({
    needle: item.needle,
    replacement: item.replacement,
    occurrences: item.occurrences,
  }));
}

function versionOf(appDirectory) {
  return appDirectory.replace(/^app-/, '').split('.').map(part => Number(part));
}

const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const builds = [];
for (let index = 0; index < variantArgs.length; index += 3) {
  const [appDirectory, originalDirectory, patchedDirectory] = variantArgs.slice(index, index + 3);
  builds.push({
    appDirectory,
    originalSha256: {
      main: hash(path.join(originalDirectory, 'main.js')),
      renderer: hash(path.join(originalDirectory, 'renderer.js')),
    },
    patchedSha256: {
      main: hash(path.join(patchedDirectory, 'main.js')),
      renderer: hash(path.join(patchedDirectory, 'renderer.js')),
    },
  });
}

builds.sort((left, right) => {
  const a = versionOf(left.appDirectory);
  const b = versionOf(right.appDirectory);
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (b[index] || 0) - (a[index] || 0);
    if (difference !== 0) return difference;
  }
  return 0;
});

const manifest = {
  patchVersion: '1.4.8',
  builds,
  operations: {
    main: operationsFor(report, 'main.js'),
    renderer: operationsFor(report, 'renderer.js'),
  },
};

fs.writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
process.stdout.write(
  `Manifest ${manifest.patchVersion}: ${builds.map(build => build.appDirectory).join(', ')}; ${manifest.operations.main.length + manifest.operations.renderer.length} operations\n`
);

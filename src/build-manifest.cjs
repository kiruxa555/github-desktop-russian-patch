'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const [reportPath, originalDirectory, patchedDirectory, outputPath] = process.argv.slice(2);
if (!reportPath || !originalDirectory || !patchedDirectory || !outputPath) {
  throw new Error(
    'Usage: node build-manifest.cjs <report.json> <original-dir> <patched-dir> <output.json>'
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

const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const manifest = {
  patchVersion: '1.4.2',
  supportedAppDirectory: 'app-3.6.10',
  originalSha256: {
    main: hash(path.join(originalDirectory, 'main.js')),
    renderer: hash(path.join(originalDirectory, 'renderer.js')),
  },
  patchedSha256: {
    main: hash(path.join(patchedDirectory, 'main.js')),
    renderer: hash(path.join(patchedDirectory, 'renderer.js')),
  },
  operations: {
    main: operationsFor(report, 'main.js'),
    renderer: operationsFor(report, 'renderer.js'),
  },
};

fs.writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
process.stdout.write(
  `Manifest ${manifest.patchVersion}: ${manifest.operations.main.length + manifest.operations.renderer.length} operations\n`
);

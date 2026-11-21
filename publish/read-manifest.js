// Prints the package.json inside the npm tarball TARBALL as JSON, after checking that every reader
// finds the same one. On failure, prints the problems instead and exits 1. npm extracts a tarball by dropping each entry's first path component, so
// every entry must be a canonical package/<path>, and exactly one entry, a regular file, may land
// on package.json. Names are compared case- and Unicode-insensitively, as macOS and Windows
// filesystems compare them. Reads the archive with the tar parser bundled in npm (NPM_ROOT), the
// one npm publish extracts with.
// Environment: TARBALL, NPM_ROOT.
const fs = require('fs');
const { Parser } = require(`${process.env.NPM_ROOT}/npm/node_modules/tar`);

const fold = (s) => s.normalize('NFD').toUpperCase().toLowerCase();
const problems = [];
const manifests = [];

const parser = new Parser({ strict: true });
parser.on('entry', (entry) => {
  const rel = entry.path.startsWith('package/') ? entry.path.slice(8).replace(/\/$/, '') : null;
  if (rel === null || (rel !== '' && rel.split('/').some((s) => ['', '.', '..'].includes(s)))) {
    problems.push(`${JSON.stringify(entry.path)} is not a canonical package/<path> entry`);
  } else if (fold(rel) === 'package.json') {
    if (entry.type !== 'File') problems.push(`${JSON.stringify(entry.path)} is a ${entry.type}`);
    const chunks = [];
    entry.on('data', (c) => chunks.push(c));
    entry.on('end', () => manifests.push(Buffer.concat(chunks).toString('utf8')));
    return;
  }
  entry.resume();
});

try {
  parser.end(fs.readFileSync(process.env.TARBALL));
} catch (e) {
  problems.push(`it is not a readable tarball (${e.message})`);
}
let manifest;
if (manifests.length !== 1) {
  problems.push(`${manifests.length} entries land on package.json`);
} else {
  try {
    manifest = JSON.parse(manifests[0].replace(/^\uFEFF/, ''));
  } catch {
    problems.push('its package.json is not valid JSON');
  }
}
if (problems.length) {
  process.stdout.write(problems.join('; '));
  process.exitCode = 1;
} else {
  process.stdout.write(JSON.stringify(manifest));
}

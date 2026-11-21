// Chooses the npm dist-tag for VERSION, given the versions already published (VERSIONS, JSON).
//   prerelease          -> "next" (template behavior)
//   -trust.N prerelease -> "trust-check" (validation releases for new trusted publishers)
//   stable, highest     -> "latest"
//   stable, lower than the highest stable already published -> "lts-v<major>"
// Uses the semver copy bundled inside npm (NPM_ROOT), so nothing extra is installed.
const semver = require(`${process.env.NPM_ROOT}/npm/node_modules/semver`);

const version = process.env.VERSION;
const published = [].concat(JSON.parse(process.env.VERSIONS || '[]'));
const pre = semver.prerelease(version);

if (pre) {
  console.log(pre[0] === 'trust' ? 'trust-check' : 'next');
} else {
  const stable = published.filter((v) => !semver.prerelease(v));
  const highest = semver.maxSatisfying(stable, '*');
  console.log(!highest || semver.gt(version, highest) ? 'latest' : `lts-v${semver.major(version)}`);
}

// Chooses the npm dist-tag for VERSION, given the versions already published (VERSIONS, JSON).
//   prerelease          -> "next" (template behavior)
//   -trust.N prerelease -> "trust-check" (validation releases for new trusted publishers)
//   stable, highest     -> "latest"
//   stable, highest in its major but below the highest stable -> "lts-v<major>"
// A stable version below the highest stable already published in its major would move a tag
// backwards, so it prints the problem instead and exits 1.
// Uses the semver copy bundled inside npm (NPM_ROOT), so nothing extra is installed.
// Environment: VERSION, VERSIONS, NPM_ROOT.
const semver = require(`${process.env.NPM_ROOT}/npm/node_modules/semver`);

const version = process.env.VERSION;
const published = [].concat(JSON.parse(process.env.VERSIONS || '[]'));
const pre = semver.prerelease(version);

if (pre) {
  console.log(pre[0] === 'trust' ? 'trust-check' : 'next');
} else {
  const major = semver.major(version);
  const stable = published.filter((v) => !semver.prerelease(v));
  const highest = semver.maxSatisfying(stable, '*');
  const highestInMajor = semver.maxSatisfying(stable, `${major}.x`);
  if (!highest || semver.gt(version, highest)) {
    console.log('latest');
  } else if (!highestInMajor || semver.gt(version, highestInMajor)) {
    console.log(`lts-v${major}`);
  } else {
    process.stdout.write(
      `${version} is below ${highestInMajor}, already published in major ${major}, so it can't take latest or lts-v${major}`,
    );
    process.exitCode = 1;
  }
}

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const browserDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(browserDir, '..', '..');

const isSuiteRoot = (candidate) => {
  if (!candidate) {
    return false;
  }
  return (
    fs.existsSync(path.join(candidate, 'package.json')) &&
    fs.existsSync(path.join(candidate, 'src', 'browser'))
  );
};

export const resolveSuiteRoot = () => {
  const candidates = [
    process.env.PERLSKY_BROWSER_SUITE_ROOT,
    path.resolve(repoRoot, '..', 'atproto-smoke'),
  ];
  for (const candidate of candidates) {
    if (isSuiteRoot(candidate)) {
      return candidate;
    }
  }
  throw new Error(
    'unable to locate standalone atproto-smoke checkout; set PERLSKY_BROWSER_SUITE_ROOT or clone ../atproto-smoke',
  );
};

export const importSuiteModule = async (relativePath) => {
  const suiteRoot = resolveSuiteRoot();
  const modulePath = pathToFileURL(path.join(suiteRoot, relativePath)).href;
  return import(modulePath);
};

import { importSuiteModule } from './suite-root.mjs';

const { runDualFromArgv } = await importSuiteModule('src/browser/run-dual.mjs');
const exitCode = await runDualFromArgv(process.argv);
process.exitCode = exitCode;

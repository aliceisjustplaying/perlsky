import { importSuiteModule } from './suite-root.mjs';

const { runSingleFromArgv } = await importSuiteModule('src/browser/run-single.mjs');
const exitCode = await runSingleFromArgv(process.argv);
process.exitCode = exitCode;

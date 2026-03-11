import { runSingleFromArgv } from '../../pds-smoke-suite/src/browser/run-single.mjs';

const exitCode = await runSingleFromArgv(process.argv);
process.exitCode = exitCode;

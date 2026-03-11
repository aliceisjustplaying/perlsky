import { runDualFromArgv } from '../../pds-smoke-suite/src/browser/run-dual.mjs';

const exitCode = await runDualFromArgv(process.argv);
process.exitCode = exitCode;

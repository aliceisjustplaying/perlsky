import { runDualFromArgv } from '../../atproto-smoke/src/browser/run-dual.mjs';

const exitCode = await runDualFromArgv(process.argv);
process.exitCode = exitCode;

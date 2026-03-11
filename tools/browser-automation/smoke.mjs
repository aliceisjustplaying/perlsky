import { runSingleFromArgv } from '../../atproto-smoke/src/browser/run-single.mjs';

const exitCode = await runSingleFromArgv(process.argv);
process.exitCode = exitCode;

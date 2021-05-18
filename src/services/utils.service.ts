import { Injectable } from '@nestjs/common';
import * as childProcess from 'child_process';
import * as util from 'util';

export class ExecuteProcessOptions {
  args: string[];
  command: string;
  cwd?: string;
  handleData?: (data: any) => void;
  quiet?: boolean;
  quietStdErrData?: boolean;
  ignoreExitCode?: boolean;
  secretArgs?: string[];
}

@Injectable()
export class UtilsService {
  // eslint-disable-next-line @typescript-eslint/ban-types
  write(data?: string | Object): void {
    let dataOutput: string;

    if (!data) {
      dataOutput = '';
    } else if (data instanceof Object) {
      try {
        dataOutput = JSON.stringify(data, undefined, 2);
        if (dataOutput === '{}') {
          dataOutput = util.inspect(data, false);
        }
      } catch (e) {
        dataOutput = util.inspect(data, false);
      }
    } else {
      dataOutput = data;
    }

    process.stdout.write(dataOutput);
  }

  // eslint-disable-next-line @typescript-eslint/ban-types
  writeLine(data?: string | Object): void {
    if (data) this.write(data);
    process.stdout.write('\n');
  }

  async executeProcess(options: ExecuteProcessOptions): Promise<number> {
    return new Promise(
      (resolve: (exitCode: number) => void, reject: (error: Error) => void) => {
        /* Set Defaults for Optional Variables */
        if (options.quiet !== true) options.quiet = false; // eslint-disable-line no-param-reassign
        if (options.quietStdErrData !== true) options.quietStdErrData = false; // eslint-disable-line no-param-reassign

        /* Write out Start */
        if (options.quiet !== true)
          this.writeLine(
            `\nEXEC START: ${options.command} ${options.args}\n\n`,
          );

        /* Combine Arguments with secret arguments */
        let processArgs = options.args;
        if (options.secretArgs)
          processArgs = processArgs.concat(options.secretArgs);

        /* Start Child Process */
        const runChildProcess = childProcess.spawn(
          options.command,
          processArgs,
          { cwd: options.cwd || process.cwd() },
        );

        /* Watch For Data */
        runChildProcess.stdout.on('data', (data) => {
          if (options.handleData) {
            options.handleData(data);
          } else if (options.quiet !== true) {
            this.writeLine(data.toString());
          }
        });

        /* Watch For Error Information */
        runChildProcess.stderr.on('data', (data: any) => {
          if (!options.quietStdErrData) {
            this.writeLine(data.toString());
          }
        });

        runChildProcess.on('error', (error: Error) => {
          this.writeLine(error);
          reject(error);
        });

        /* Watch For Finish */
        runChildProcess.on('close', (exitCode) => {
          if (options.quiet !== true)
            this.writeLine(
              `\nEXEC END: ${options.command} ${options.args}\n\n`,
            );

          /* Check Exit Code */
          if (options.ignoreExitCode !== true && exitCode !== 0) {
            const exitCodeError = `Failed exitCode: ${exitCode}`;
            this.writeLine(exitCodeError);
            reject(
              new Error(
                JSON.stringify(
                  {
                    exitCode,
                  },
                  undefined,
                  2,
                ),
              ),
            );
          } else {
            resolve(exitCode);
          }
        });
      },
    );
  }

  async forEachSeries(
    list: any[],
    fn: (item: any) => Promise<void>,
  ): Promise<void> {
    for (const item of list) {
      await fn(item);
    }
  }
}

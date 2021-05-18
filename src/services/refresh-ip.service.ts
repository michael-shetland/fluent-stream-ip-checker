import { Injectable } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { UtilsService } from './utils.service';

@Injectable()
export class RefreshIpService {
  constructor(private readonly utils: UtilsService) {}

  @Cron('* 0 * * * *') /* Run at top of every hour */
  async execute(): Promise<void> {
    this.utils.writeLine('Executing ./scripts/refresh-ipsets.sh ...');
    await this.utils.executeProcess({
      command: 'bash',
      args: ['./scripts/refresh-ipsets.sh'],
      quiet: true,
      quietStdErrData: false,
      ignoreExitCode: true,
    });
    this.utils.writeLine('./scripts/refresh-ipsets.sh Completed ...');
  }
}

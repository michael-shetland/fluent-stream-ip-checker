import { Injectable } from '@nestjs/common';
import { UtilsService } from './utils';

@Injectable()
export class IpsetService {
  constructor(private readonly utils: UtilsService) {}

  async test(ipAddress: string, setName: string): Promise<boolean> {
    const testResult: number = await this.utils.executeProcess({
      command: 'ipset',
      args: ['test', setName, ipAddress],
      quiet: true,
      quietStdErrData: true,
      ignoreExitCode: true,
    });

    return testResult === 0;
  }
}

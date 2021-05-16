import {
  ApiTags,
  ApiOperation,
  ApiResponse,
  ApiOkResponse,
} from '@nestjs/swagger';
import { Controller, Post, Body, HttpCode } from '@nestjs/common';
import { IpcheckerBody, IpcheckerReturn } from '../models';
import { IpsetService, UtilsService } from '../services';

const defaultIpsetNames = [
  'feodo',
  'palevo',
  'sslbl',
  'zeus',
  'zeus_badips',
  'dshield',
  'spamhaus_drop',
  'spamhaus_edrop',
  'bogons',
  'fullbogons',
];

@ApiTags('IP Checker')
@Controller()
export class IpcheckerController {
  constructor(
    private readonly ipset: IpsetService,
    private readonly utils: UtilsService,
  ) {}

  @Post('ipchecker')
  @ApiOperation({ summary: 'Check IP Address' })
  @ApiOkResponse({ type: IpcheckerReturn })
  @HttpCode(200)
  @ApiResponse({
    status: 200,
    description: 'Check is successful',
  })
  @ApiResponse({ status: 500, description: 'Server Error' })
  async ipchecker(@Body() data: IpcheckerBody): Promise<IpcheckerReturn> {
    let ipAddressExists = false;
    await this.utils.forEachSeries(defaultIpsetNames, async (ipsetName) => {
      if (!ipAddressExists) {
        ipAddressExists = await this.ipset.test(data.ipAddress, ipsetName);
      }
    });

    return { ipAddressExists };
  }
}

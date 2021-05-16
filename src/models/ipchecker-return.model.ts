import { ApiProperty } from '@nestjs/swagger';

export class IpcheckerReturn {
  @ApiProperty()
  ipAddressExists: boolean;
}

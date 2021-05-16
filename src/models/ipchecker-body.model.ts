import { ApiProperty } from '@nestjs/swagger';

export class IpcheckerBody {
  @ApiProperty()
  ipAddress: string;
}

import { Module } from '@nestjs/common';
import { TerminusModule } from '@nestjs/terminus';
import { HealthController, IpcheckerController } from './controllers';
import { IpsetService, UtilsService } from './services';

@Module({
  imports: [TerminusModule],
  controllers: [HealthController, IpcheckerController],
  providers: [IpsetService, UtilsService],
})
export class AppModule {}

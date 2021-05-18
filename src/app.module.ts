import { Module } from '@nestjs/common';
import { TerminusModule } from '@nestjs/terminus';
import { ScheduleModule } from '@nestjs/schedule';
import { HealthController, IpcheckerController } from './controllers';
import { IpsetService, RefreshIpService, UtilsService } from './services';

@Module({
  imports: [TerminusModule, ScheduleModule.forRoot()],
  controllers: [HealthController, IpcheckerController],
  providers: [IpsetService, UtilsService, RefreshIpService],
})
export class AppModule {}

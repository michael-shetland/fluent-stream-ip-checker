import * as util from 'util';
import { json } from 'body-parser';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import * as packageConfig from '../package.json';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  /* Setup JSON Parsing */
  app.use(json({ limit: '50mb' }));

  const swaggerOptions = new DocumentBuilder()
    .setTitle(packageConfig.name)
    .setVersion(packageConfig.version)
    .setDescription(packageConfig.description)
    .build();

  const document = SwaggerModule.createDocument(app, swaggerOptions);

  SwaggerModule.setup('/', app, document, {
    swaggerOptions: {
      tagsSorter: 'alpha',
      docExpansion: 'none',
    },
  });

  await app.listen(3000, () => {
    process.stdout.write('Listening at http://localhost:3000\n');
  });
}
bootstrap().catch((err) => {
  process.stderr.write(`bootstrap error\n`);
  process.stderr.write(util.inspect(err));
});

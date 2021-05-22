FROM node:16.1.0-buster as build

# Setup Arguments
ARG version=0.0.0

COPY ./ /build

WORKDIR /build

# Compile code
RUN npm install && \
    npx json -I -f package.json -e "this.version=\"${version}\"" && \
    npm run build && \
    npm prune --production


FROM node:16.1.0-buster as publish

# Install FireHOL and cron
RUN apt-get update -y && \
    apt-get install firehol cron -y && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Application
RUN install \
      -d \
      -m 0755 \
      /app

COPY --from=build /build/dist/src /app/dist
COPY --from=build /build/node_modules/ /app/node_modules/
COPY --from=build /build/package*.json /app

# Add Update IP Sets Script
COPY --from=build /build/scripts/update-ipsets.sh /usr/lib/firehol/update-ipsets.sh
RUN chmod +x /usr/lib/firehol/update-ipsets.sh

# Add Refresh IP Sets Script
COPY --from=build /build/scripts/refresh-ipsets.sh /app/scripts/refresh-ipsets.sh
RUN chmod +x /app/scripts/refresh-ipsets.sh

# Add Entrypoint Script
ADD [".ci/build/entrypoint.sh", "/app/"]
RUN chmod +x /app/entrypoint.sh

WORKDIR /app

CMD ["/app/entrypoint.sh", "--with", "--args"]

HEALTHCHECK --interval=10s --start-period=10s --retries=5 --timeout=2s CMD wget -qO- "http://localhost:3000/health" || exit 1
ARG POSTGRES_VERSION
FROM postgres:${POSTGRES_VERSION}-alpine
ARG TARGETARCH

RUN apk add --update-cache --no-cache \
    # for pg_dump
    postgresql-client \
    # for encryption
    gnupg \
    # for s3 upload
    aws-cli \
    # for pretty progress bar
    pv \
    curl && \
    curl -L https://github.com/ivoronin/go-cron/releases/download/v0.0.5/go-cron_0.0.5_linux_${TARGETARCH}.tar.gz -O && \
    tar xvf go-cron_0.0.5_linux_${TARGETARCH}.tar.gz && \
    mv go-cron /usr/local/bin/go-cron && \
    chmod +x /usr/local/bin/go-cron && \
    rm go-cron_0.0.5_linux_${TARGETARCH}.tar.gz

ENV POSTGRES_DATABASE=''
ENV POSTGRES_HOST=''
ENV POSTGRES_PORT=5432
ENV POSTGRES_USER=''
ENV POSTGRES_PASSWORD=''
ENV PGDUMP_EXTRA_OPTS=''
ENV S3_ACCESS_KEY_ID=''
ENV S3_SECRET_ACCESS_KEY=''
ENV S3_BUCKET=''
ENV S3_REGION='us-west-1'
ENV S3_PATH='backup'
ENV S3_ENDPOINT=''
ENV S3_S3V4='no'
ENV SCHEDULE=''
ENV PASSPHRASE=''
ENV BACKUP_KEEP_DAYS=''
# Default: show progress every 5 seconds
ENV PV_INTERVAL_SEC=5

ADD src/run.sh run.sh
ADD src/env.sh env.sh
ADD src/backup.sh backup.sh
ADD src/restore.sh restore.sh

CMD ["sh", "run.sh"]

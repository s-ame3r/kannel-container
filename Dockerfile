FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends kannel kannel-extras curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/lib/kannel/test/fakesmsc /usr/local/bin/fakesmsc \
    && (getent group kannel > /dev/null || groupadd -r kannel) \
    && usermod -g kannel kannel \
    && mkdir -p /var/log/kannel /var/spool/kannel \
    && chown -R kannel:kannel /var/log/kannel /var/spool/kannel

# Application files
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY kannel.conf /etc/kannel/kannel.conf
COPY smsc.d /etc/kannel/smsc.d

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chown -R kannel:kannel /etc/kannel/kannel.conf /etc/kannel/smsc.d

# Expose ports
# 10000-10004 = fake SMSC, 12000 = admin/status, 12013 = send-sms HTTP API
EXPOSE 10000 10001 10002 10003 10004 12000 12013

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -fs "http://localhost:12000/status?password=foobar" > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
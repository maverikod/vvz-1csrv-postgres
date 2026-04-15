# Ubuntu 24.04 (noble) — совпадает с суффиксом .noble у пакетов Postgres Pro.
# Локальные .deb и архив 1С кладите в install/ (см. install/inst1c и install/instpgpro).

FROM ubuntu:noble

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates locales \
    && printf '%s\n' 'ru_RU.UTF-8 UTF-8' 'uk_UA.UTF-8 UTF-8' 'ru_UA.UTF-8 UTF-8' >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Postgres Pro STD 16 из локальных deb (без repo.postgrespro.ru)
COPY install/deb/postgrespro-std-16-*.deb /tmp/pgpro/
RUN apt-get update \
    && apt-get install -y /tmp/pgpro/postgrespro-std-16-libs_*.deb \
        /tmp/pgpro/postgrespro-std-16-client_*.deb \
        /tmp/pgpro/postgrespro-std-16-server_*.deb \
        /tmp/pgpro/postgrespro-std-16-contrib_*.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/pgpro

# 1С:Предприятие — как в install/inst1c (зависимости тянутся из Ubuntu)
COPY install/deb64_8_3_19_1351.tar.gz /tmp/deb64_8_3_19_1351.tar.gz
RUN apt-get update \
    && apt-get install -y --no-install-recommends liblcms2-utils \
    && cd /tmp \
    && gzip -cdf deb64_8_3_19_1351.tar.gz | tar -x \
    && dpkg -i \
        1c-enterprise-8.3.19.1351-common-nls_8.3.19-1351_amd64.deb \
        1c-enterprise-8.3.19.1351-common_8.3.19-1351_amd64.deb \
        1c-enterprise-8.3.19.1351-server-nls_8.3.19-1351_amd64.deb \
        1c-enterprise-8.3.19.1351-server_8.3.19-1351_amd64.deb \
        1c-enterprise-8.3.19.1351-ws-nls_8.3.19-1351_amd64.deb \
        1c-enterprise-8.3.19.1351-ws_8.3.19-1351_amd64.deb \
    || true \
    && apt-get -f install -y \
    && rm -rf /var/lib/apt/lists/* /tmp/deb64_8_3_19_1351.tar.gz /tmp/*.deb

# Шрифты Microsoft: один раз ./install/fonts/download-vendor.sh → vendor/; сборка без скачиваний (ALLOW_NETWORK=0).
# Или: docker build --build-arg ALLOW_NETWORK=1 — тянуть с сети как раньше.
# cabextract/fontconfig — для ppviewer.cab; без них офлайн-сборка без vendor/debs ломалась.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cabextract fontconfig \
    && rm -rf /var/lib/apt/lists/*
ARG ALLOW_NETWORK=0
ENV ALLOW_NETWORK=$ALLOW_NETWORK
COPY install/fonts/ /tmp/fctx/
RUN chmod +x /tmp/fctx/install-microsoft-fonts.sh \
    && cp /tmp/fctx/install-microsoft-fonts.sh /tmp/install-microsoft-fonts.sh \
    && /tmp/install-microsoft-fonts.sh \
    && rm -rf /tmp/fctx /tmp/install-microsoft-fonts.sh /tmp/PowerPointViewer.exe \
    && rm -rf /var/lib/apt/lists/*

# Токены «Аладдин Р.Д.» / смарт-карты: pcscd, libpcsclite1, libccid — см. install/aladdin/README.txt и
# https://developer.aladdin-rd.ru/pkcs11/2.4.1/description.html
# Проприетарные .deb вендора — в install/aladdin/deb/
RUN apt-get update \
    && apt-get install -y --no-install-recommends pcscd libpcsclite1 libccid usbutils \
    && rm -rf /var/lib/apt/lists/*

COPY install/aladdin/README.txt /usr/local/share/doc/vvz-aladdin/README.txt
COPY install/aladdin/deb /tmp/aladdin-deb
# /bin/sh — без bash-массивов
RUN if ls /tmp/aladdin-deb/*.deb >/dev/null 2>&1; then \
      apt-get update && \
      ( dpkg -i /tmp/aladdin-deb/*.deb || apt-get install -y -f ) && \
      rm -rf /var/lib/apt/lists/*; \
    fi; \
    rm -rf /tmp/aladdin-deb

# Sentinel HASP RTE (aksusbd) — см. docker/install-sentinel-aksusbd.sh
ARG SENTINEL_AKSUSBD_DEB_URL=https://download.feflow.com/download/FEFLOW/linux/dongle-7.80/aksusbd_7.80-1_amd64.deb
COPY install/sentinel-hasp/README.txt /usr/local/share/doc/vvz-sentinel-hasp/README.txt
COPY docker/install-sentinel-aksusbd.sh /usr/local/sbin/install-sentinel-aksusbd.sh
RUN chmod +x /usr/local/sbin/install-sentinel-aksusbd.sh \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && /usr/local/sbin/install-sentinel-aksusbd.sh --url "${SENTINEL_AKSUSBD_DEB_URL}" \
    && apt-get purge -y wget 2>/dev/null || true \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Кластер и сервисы не инициализируем в образе — данные и настройки монтируются с хоста (см. docker-compose.yml).
# Штатный init-скрипт 1С из пакета: /opt/1cv8/x86_64/<версия>/srv1cv83 → /etc/init.d/srv1cv83; конфиг — /etc/default/srv1cv83
ARG ONEC_VERSION=8.3.19.1351
ENV ONEC_VERSION=${ONEC_VERSION}
COPY docker/srv1cv83.default /etc/default/srv1cv83
COPY docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/start-stack.sh /usr/local/bin/start-stack.sh
COPY docker/vvz-configure-pg-hba.sh /usr/local/bin/vvz-configure-pg-hba.sh
COPY install/pg/conf.d/99-1c-enterprise.conf /usr/local/share/vvz-pg-1c/99-1c-enterprise.conf
COPY install/pg/conf.d/zz-1c-password-md5.conf /usr/local/share/vvz-pg-1c/zz-1c-password-md5.conf
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/start-stack.sh /usr/local/bin/vvz-configure-pg-hba.sh \
    && ln -sf "/opt/1cv8/x86_64/${ONEC_VERSION}/srv1cv83" /etc/init.d/srv1cv83 \
    && set -eux; \
    if id -u ubuntu >/dev/null 2>&1; then \
      groupmod -g 60000 ubuntu; \
      usermod -u 60000 -g ubuntu ubuntu; \
    fi; \
    groupmod -g 1000 grp1cv8; \
    usermod -u 1000 -g grp1cv8 usr1cv8; \
    getent group pcscd >/dev/null && usermod -aG pcscd usr1cv8 || true; \
    if id -u postgres >/dev/null 2>&1; then \
      groupmod -g 1001 postgres; \
      usermod -u 1001 -g postgres postgres; \
    fi

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/bin/start-stack.sh"]

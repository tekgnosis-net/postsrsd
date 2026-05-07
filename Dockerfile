FROM docker.io/alpine:3.22.2

# https://github.com/roehling/postsrsd/blob/main/CHANGELOG.rst
# https://git.alpinelinux.org/aports/log/community/postsrsd?h=3.22-stable
ARG POSTSRSD_PACKAGE_VERSION=2.0.11-r0
# default in /etc/postsrsd/postsrsd.conf:
# > secrets-file = "/etc/postsrsd/postsrsd.secret"
ARG POSTSRSD_SECRET_DIR_PATH=/etc/postsrsd/secrets
ENV POSTSRSD_SECRET_PATH=${POSTSRSD_SECRET_DIR_PATH}/list
# `unprivileged-user = ""` for running as uid ≠ 0 without CAP_{SETUID,SETGID}:
# > postsrsd: error: cannot drop privileges: setgroups: Operation not permitted
# `chroot-dir = ""` for running as uid ≠ 0 without CAP_SYS_CHROOT:
# > postsrsd: error: cannot drop privileges: chroot: Operation not permitted
RUN adduser -S postsrsd \
    && apk add --no-cache postsrsd=$POSTSRSD_PACKAGE_VERSION \
    && sed -i 's/^\(\(unprivileged-user\|chroot-dir\) = "\).*"/\1"/' \
         /etc/postsrsd/postsrsd.conf \
    && sed -i 's/^\(socketmap = inet:\)localhost\(\:10003\)$/\10.0.0.0\2/' \
         /etc/postsrsd/postsrsd.conf \
    && mkdir --mode 700 "${POSTSRSD_SECRET_DIR_PATH}" \
    && chown postsrsd "${POSTSRSD_SECRET_DIR_PATH}" \
    && sed -i 's#^\(secrets-file = "\).*#\1'"${POSTSRSD_SECRET_PATH}\"#" \
         /etc/postsrsd/postsrsd.conf
VOLUME ${POSTSRSD_SECRET_DIR_PATH}

USER postsrsd
ENV POSTSRSD_SECRET_PATH=${POSTSRSD_SECRET_PATH}
EXPOSE 10003/tcp
CMD set -x; \
    umask 0077; \
    if [ ! -s "$POSTSRSD_SECRET_PATH" ]; then \
      tr -dc '1-9a-zA-Z' < /dev/random | head -c 32 > "$POSTSRSD_SECRET_PATH"; \
    fi \
    && exec postsrsd

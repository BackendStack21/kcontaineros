# Audit image for the landlock track: kcos-audit plus the static probe `lp`
# and a few prepared paths. Built by build.sh; nothing here is shipped.
# rust:1-alpine is already on this machine and carries gcc and musl-dev;
# any alpine with `apk add gcc musl-dev` does as well.
FROM rust:1-alpine AS cc
COPY lp.c /lp.c
RUN gcc -static -O1 -o /lp /lp.c

FROM kcos-audit
USER 0
COPY --from=cc /lp /bb/lp
# /app: a program directory candidate, with links around it.  /w: world-writable.
RUN /bb/busybox sh -c 'set -e; \
  mkdir -p /app/bin /app/data /w/bin /opt/x /srv /emptytop; chmod 1777 /w /w/bin /app/data; \
  cp /bb/lp /app/bin/lp; cp /bb/lp /w/lp; cp /bb/lp /w/bin/lp; chmod 755 /w/lp /w/bin/lp; chown 65534:65534 /w/lp /w/bin/lp; \
  ln -s /app /lnk; ln -s /w/bin /app/wlink; ln -s bin /app/binlink; ln -s /app/bin /w/applink; \
  ln /app/bin/lp /w/hardlp; \
  printf "#!/bin/sh\necho script-ran\n" > /w/script; chmod 755 /w/script; \
  printf "#!/w/lp true\n" > /app/bin/viaw; chmod 755 /app/bin/viaw; \
  printf "#!/bb/lp true\n" > /w/viabb; chmod 755 /w/viabb; \
  echo data > /topfile; chmod 666 /topfile; /bb/busybox mkfifo /topfifo; chmod 666 /topfifo; \
  d=$(printf "/app/\377\376bin"); mkdir "$d"; cp /bb/lp "$d/lp"; \
  n=$(printf "%0255d" 0); mkdir "/app/$n"; cp /bb/lp "/app/$n/lp"; \
  mkdir "/app/sp ace"; cp /bb/lp "/app/sp ace/lp"'
# In every directory of the matrix: kv, a world-writable copy of the probe
# (so that file permissions never hide what Landlock decides), and kd, a
# world-writable empty directory.
RUN /bb/busybox sh -c 'set -e; for d in /bb /bin /sbin /usr /usr/bin /usr/local/bin /etc /home /root /run /var /var/tmp /tmp /app /app/bin /app/data /w /opt /srv; do \
  cp /bb/lp $d/kv; chmod 777 $d/kv; mkdir $d/kd; chmod 1777 $d/kd; done; chmod 755 /root'
ENV KCOS_EXEC=/bb

# Audit image (track: memory): kcos-audit plus one static helper in /bb.
FROM rust:1-alpine AS cc
COPY hexec.c /hexec.c
RUN gcc -static -O1 -Wall -o /hexec /hexec.c

FROM kcos-audit AS full
COPY --from=cc /hexec /bb/hexec

# The sealed image has no shell: the helper is the only other program.
FROM kcontaineros:sealed AS sealed
COPY --from=cc /hexec /bb/hexec
ENV KCOS_EXEC=/bb
USER 0

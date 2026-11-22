# Image for the escape-root track: kcos-audit plus a static helper in /aud,
# a program directory named in KCOS_EXEC. Built by build.sh.
# rust:1-alpine is used only because it carries gcc and musl-dev and was
# already on the machine (the audit host had no disk left to install them
# into alpine).
FROM rust:1-alpine AS cc
COPY esc.c setfcaps.c /src/
RUN mkdir /aud && gcc -O1 -static -Wall -o /aud/esc /src/esc.c
# the same program carrying every file capability, and a setuid-root copy
RUN gcc -o /src/setfcaps /src/setfcaps.c && cp /aud/esc /aud/esc-fcaps && /src/setfcaps /aud/esc-fcaps \
 && cp /aud/esc /aud/esc-suid && chmod 4755 /aud/esc-suid
# a dynamically linked program whose loader (PT_INTERP) is in a writable
# directory, and a script whose interpreter is
RUN echo 'int main(void){return 0;}' > /src/i.c \
 && gcc -o /aud/interp-in-tmp -Wl,--dynamic-linker=/tmp/kcos-ld /src/i.c \
 && echo '#!/tmp/kcos-interp' > /aud/shebang-in-tmp && chmod 755 /aud/shebang-in-tmp

FROM kcos-audit
COPY --from=cc /aud /aud
ENV KCOS_EXEC=/bb:/aud
USER 0

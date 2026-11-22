# Audit helper image: the prepared kcos-audit image plus /bb/sc.
FROM rust:1.100.0-alpine3.24@sha256:8d0e82abfdf9a38071e07cabc5afba4ddbe077631a80e4e742a760c38beadc33 AS build
COPY sc.rs /sc.rs
RUN rustc -O -C panic=abort /sc.rs -o /sc
FROM kcos-audit AS img
COPY --from=build /sc /bb/sc

# kcos-audit-claims-nnp: a setuid-root binary and one with file capabilities
# (cap_chown, cap_net_bind_service: permitted and effective), for the no_new_privs row.
FROM kcos-audit-claims-img AS nnp
USER 0
RUN ["/bb/busybox", "sh", "-c", "/bb/busybox cp /bb/sc /usr/local/bin/suid-sc && /bb/busybox chmod 4755 /usr/local/bin/suid-sc && /bb/busybox mkdir /usr/local/bin/capdir && /bb/busybox cp /bb/busybox /usr/local/bin/capdir/busybox && /bb/sc 5 s:/usr/local/bin/capdir/busybox s:security.capability x:0100000201040000000000000000000000000000 20 0"]

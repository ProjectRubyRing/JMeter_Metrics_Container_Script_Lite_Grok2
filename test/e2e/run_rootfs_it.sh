#!/bin/bash
# =============================================================================
# run_rootfs_it.sh : 結合試験 (Docker を使わない版。Linux / WSL)
#
# Red Hat の ubi9/openjdk-21-runtime イメージから取り出した rootfs (UBI 9.8 + Red Hat build of
# OpenJDK 21) に WildFly 35 (EAP 8.1 と同じ WildFly Core 27 系) を入れ、root 不要の
# user / mount / pid 名前空間 (unshare) と chroot で動かす。本番と同じエントリポイント (CMD=eap) で
# 起動し、検証用 WAR へ負荷をかけて perf/ の出力と運用コマンドを確かめる。
# top / ps (procps-ng) の無い runtime イメージそのままなので、③ は /proc からの算出を確かめる。
#
#   usage: ROOTFS=<rootfs> WILDFLY_TGZ=<wildfly-35.x.tar.gz> bash test/e2e/run_rootfs_it.sh [秒] [vCPU] [CPU ユニット] [結果のコピー先]
#   (rootfs の作り方は README の「7. 試験」を参照)
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
R="${ROOTFS:-$HOME/rhjdk21/rootfs}"
LOAD_SEC="${1:-90}"; VCPU="${2:-1}"; CU="${3:-512}"; COPY_TO="${4:-}"
[ -x "${R}/usr/bin/bash" ] || { echo "rootfs がありません: ${R}" >&2; exit 2; }
if [ ! -x "${R}/opt/jboss-eap/bin/standalone.sh" ]; then
    : "${WILDFLY_TGZ:?WILDFLY_TGZ (wildfly-35.x.Final.tar.gz) を指定してください}"
    mkdir -p "${R}/opt"; tar -xzf "${WILDFLY_TGZ}" -C "${R}/opt"
    rm -rf "${R}/opt/jboss-eap"; mv "${R}"/opt/wildfly-* "${R}/opt/jboss-eap"
fi
[ -d "${R}/opt/jboss-eap-standalone-pristine" ] || cp -a "${R}/opt/jboss-eap/standalone" "${R}/opt/jboss-eap-standalone-pristine"
mkdir -p "${R}/tmp/it"
cp "${ROOT}/docker/base/perf-metrics.sh" "${ROOT}/docker/base/entrypoint.sh" "${HERE}/FakeEcsMetadata.java" "${HERE}/rootfs_it_inner.sh" "${R}/tmp/it/"
sed -i 's/\r$//' "${R}/tmp/it/"*.sh
python3 "${HERE}/make_war.py" "${R}/tmp/it" >/dev/null || exit 1
unshare --user --map-root-user --mount --pid --fork bash -c '
  R="$1"; shift
  mount --rbind /dev "$R/dev" 2>/dev/null || mount -t tmpfs none "$R/dev"
  mount -t proc proc "$R/proc"
  mount --rbind /sys "$R/sys" 2>/dev/null || true
  exec chroot "$R" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp TERM=dumb LANG=C.UTF-8 /bin/bash /tmp/it/rootfs_it_inner.sh "$@"
' _ "${R}" "${LOAD_SEC}" "${VCPU}" "${CU}" | tee "${R}/tmp/it/result.txt"
rc=${PIPESTATUS[0]}
if [ -n "${COPY_TO}" ]; then
    out="$(sed -n 's/^OUT=//p' "${R}/tmp/it/result.txt" | tail -n 1)"
    rm -rf "${COPY_TO}"; mkdir -p "${COPY_TO}"
    [ -n "${out}" ] && cp -r "${R}${out}" "${COPY_TO}/perf"
    cp "${R}"/tmp/it/*.txt "${R}"/tmp/it/console.log "${COPY_TO}/" 2>/dev/null
    ls "${R}"/mnt/logs/front/logs/intra-web/mid/2*/perf_*.tar* >/dev/null 2>&1 && cp "${R}"/mnt/logs/front/logs/intra-web/mid/2*/perf_*.tar* "${COPY_TO}/"
    echo "copied to ${COPY_TO}"
fi
exit "${rc}"

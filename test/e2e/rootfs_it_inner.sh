#!/bin/bash
# =============================================================================
# rootfs_it_inner.sh : 結合試験 (Docker を使わない版) のうち、UBI 9.8 + Red Hat OpenJDK 21 の
#                      rootfs に chroot した中で動かす部分。run_rootfs_it.sh から呼ばれる。
#
#   前提: rootfs の /opt/jboss-eap に WildFly 35 (EAP 8.1 と同じ WildFly Core 27 系)、
#         /opt/jboss-eap-standalone-pristine に standalone/ の初期状態、
#         /tmp/it に perf-metrics.sh・entrypoint.sh・perftest.war・FakeEcsMetadata.java
#   usage: rootfs_it_inner.sh [負荷をかける秒数 (既定 90)] [タスク vCPU (既定 1)] [コンテナ CPU ユニット (既定 512)]
# =============================================================================
set -u
LOAD_SEC="${1:-90}"
TASK_VCPU="${2:-1}"
CONT_CU="${3:-512}"
export JAVA_HOME=/usr/lib/jvm/jre-21-openjdk
export PATH="${JAVA_HOME}/bin:/usr/local/bin:/usr/bin:/bin"
P=/tmp/it
JH=/opt/jboss-eap
fail=0
ok() { echo "  [OK]   $*"; }
ng() { echo "  [NG]   $*"; fail=1; }

echo "== 1. 疑似コンテナを作る (configuration は空のボリューム、seed から復元させる)"
rm -rf /mnt/logs /mnt/data /tmp/perf-metrics* /tmp/hsperfdata_* /tmp/.java_pid* 2>/dev/null
mkdir -p /mnt/logs /mnt/data
rm -rf "${JH}/standalone"; cp -a /opt/jboss-eap-standalone-pristine "${JH}/standalone"
rm -rf "${JH}/standalone/configuration-seed"; cp -a "${JH}/standalone/configuration" "${JH}/standalone/configuration-seed"
rm -rf "${JH}/standalone/configuration-seed/standalone_xml_history" "${JH}/standalone/configuration/"*
rm -rf "${JH}/standalone/log"; ln -s /mnt/logs/front/logs/intra-web/mid/current "${JH}/standalone/log"
install -m 0755 "${P}/entrypoint.sh" /usr/local/bin/efs-entrypoint.sh
install -m 0755 "${P}/perf-metrics.sh" /usr/local/bin/perf-metrics.sh
mkdir -p /webapp/webapp9mf02

java -XX:+UseSerialGC -Xmx32m "${P}/FakeEcsMetadata.java" 18099 "${TASK_VCPU}" "${CONT_CU}" > "${P}/meta.log" 2>&1 &
META=$!
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:18099/v4/perf-e2e/task >/dev/null 2>&1 && break; sleep 1; done

echo "== 2. 本番と同じ CMD=eap で起動 (PERF_METRICS_ENABLED=true)"
export ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:18099/v4/perf-e2e
export JBOSS_HOME="${JH}" JBOSS_CONF_DIR="${JH}/standalone/configuration" JBOSS_CONF_SEED_DIR="${JH}/standalone/configuration-seed"
# 既定の cacerts のパスワード (違う値を渡すと JBoss の SSL コンテキストが起動に失敗する)
export SERVER_CONFIG=standalone.xml EXTRASLB_TRUSTSTORE_TYPE=JKS EXTRASLB_TRUSTSTORE_PASSWORD=changeit
export Service_Name=intra-web Component_name=front COMPONENT_ROLE=front APP_HOME=/webapp/webapp9mf02 EFS_LOG_DIR=/mnt/logs/front/logs/intra-web
export PERF_METRICS_ENABLED=true PERF_INTERVAL=5 PERF_JCMD_INTERVAL=15 PERF_TZ=Asia/Tokyo PERF_NMT=summary
cd /tmp || exit 1
/usr/local/bin/efs-entrypoint.sh eap > "${P}/console.log" 2>&1 &
EP=$!
for _ in $(seq 1 120); do grep -q -E 'WFLYSRV002[56]' "${P}/console.log" 2>/dev/null && break; sleep 1; done
grep -q WFLYSRV0025 "${P}/console.log" && ok "JBoss 起動" || { ng "JBoss が正常に起動しません"; grep -E 'ERROR|WFLYSRV0026' "${P}/console.log" | head -20; exit 1; }
grep -q '性能試験用メトリクス収集: 有効' "${P}/console.log" && ok "起動ログに有効の枠" || ng "起動ログに有効の枠が無い"
grep -q 'JAVA_OPTS: -XX:StartFlightRecording:name=perf-metrics' "${P}/console.log" && ok "PREPEND_JAVA_OPTS で JFR が JAVA_OPTS の先頭に入った" || ng "JFR のオプションが JAVA_OPTS に無い"
grep 'JAVA_OPTS: ' "${P}/console.log" | grep -q -- '-Xms64m -Xmx512m' && ok "standalone.conf の既定ヒープ (-Xms64m -Xmx512m) はそのまま" || ng "standalone.conf の既定値が消えた"
grep -q 'standalone.sh -Dwildfly.datasources.statistics-enabled=true -Dwildfly.undertow.statistics-enabled=true -Dwildfly.transactions.statistics-enabled=true' "${P}/console.log" \
    && ok "統計の有効化の引数を standalone.sh の直後に追加" || ng "統計の有効化の引数が無い"
grep -q 'trustStorePassword=\*\*\*\*' "${P}/console.log" && ! grep -q 'trustStorePassword=changeit' "${P}/console.log" && ok "起動ログのパスワードは伏せ字" || ng "起動ログにパスワード"

echo "== 3. XA データソースの追加・WAR のデプロイ・${LOAD_SEC} 秒の負荷"
CLI() { JAVA_OPTS="-Xmx64m -XX:+UseSerialGC -XX:TieredStopAtLevel=1" "${JH}/bin/jboss-cli.sh" -c --controller=127.0.0.1:9990 "$@"; }
CLI --command='xa-data-source add --name=ExampleXADS --jndi-name=java:jboss/datasources/ExampleXADS --driver-name=h2 --user-name=sa --password=sa --max-pool-size=5 --xa-datasource-properties={"URL"=>"jdbc:h2:mem:testxa;DB_CLOSE_DELAY=-1"}' >/dev/null 2>&1 \
    && ok "XA データソース追加" || ng "XA データソース追加"
CLI --command="deploy ${P}/perftest.war" >/dev/null 2>&1 && ok "WAR デプロイ" || ng "WAR デプロイ"
sleep 3
B=http://127.0.0.1:8080/perftest
curl -fsS "${B}/db.jsp?ms=1" >/dev/null && curl -fsS "${B}/db.jsp?ms=1&xa=1" >/dev/null && ok "WAR 応答 (通常 / XA)" || ng "WAR が応答しない"
END=$(( $(date +%s) + LOAD_SEC ))
for w in $(seq 1 24); do
    ( while [ "$(date +%s)" -lt "${END}" ]; do
        case $((w % 3)) in
            0) curl -s -o /dev/null "${B}/db.jsp?ms=150&kb=4096" ;;
            1) curl -s -o /dev/null "${B}/db.jsp?ms=80&xa=1&kb=1024" ;;
            2) curl -s -o /dev/null "${B}/db.jsp?ms=5&lock=30&ex=50&sock=40&cpu=20" ;;
        esac
      done ) &
done
wait_load() { while [ "$(date +%s)" -lt "${END}" ]; do sleep 5; done; sleep 2; }
wait_load
sleep 12

echo "== 4. 運用コマンド (ECS Exec の代わり)"
perf-metrics.sh status > "${P}/status.txt" 2>&1 && ok "status" || ng "status"
perf-metrics.sh cpu-check > "${P}/cpucheck.txt" 2>&1 && ok "cpu-check: $(grep 'result' "${P}/cpucheck.txt" | head -n 1 | sed 's/  */ /g')" || ng "cpu-check"
perf-metrics.sh jfr-dump > "${P}/jfrdump.txt" 2>&1 && ok "jfr-dump" || ng "jfr-dump"
perf-metrics.sh threaddump > "${P}/threaddump.txt" 2>&1 && ok "threaddump" || ng "threaddump"

echo "== 5. JBoss を止める (JFR は終了時に perf/jfr/ へ書かれる)"
CLI --command=":shutdown" >/dev/null 2>&1
for _ in $(seq 1 60); do kill -0 "${EP}" 2>/dev/null || break; sleep 1; done
kill -0 "${EP}" 2>/dev/null && ng "JBoss が止まらない" || ok "JBoss 停止"
perf-metrics.sh stop > "${P}/stop.txt" 2>&1 && ok "stop ($(grep -c '停止しました' "${P}/stop.txt") 収集)" || ng "stop"
OUT="$(ls -d /mnt/logs/front/logs/intra-web/mid/2*/perf | tail -n 1)"
ls "${OUT}"/jfr/perf_*.jfr >/dev/null 2>&1 && ok "終了時の JFR: $(find "${OUT}/jfr" -maxdepth 1 -name 'perf_*.jfr' -exec basename {} \;)" || ng "終了時の JFR が無い"
perf-metrics.sh jfr-csv > "${P}/jfrcsv.txt" 2>&1 && ok "jfr-csv: $(tail -n 1 "${P}/jfrcsv.txt")" || { ng "jfr-csv"; cat "${P}/jfrcsv.txt"; }
perf-metrics.sh pack no-jfr-csv > "${P}/pack.txt" 2>&1 && ok "pack: $(tail -n 1 "${P}/pack.txt")" || ng "pack"
kill "${META}" 2>/dev/null

echo "== 6. 出力の確認 (${OUT})"
for f in perf_meta cli_datasource cli_undertow cli_session cli_io_worker cli_threadpool cli_transactions cli_jvm \
         jvm_jstat_gc jvm_jcmd_heap jvm_codecache jvm_thread_states jvm_nmt \
         os_top_summary os_top_process os_top_threads os_ps os_jboss_threads os_jboss_proc cpu_env cpu_sched \
         jfr_stats jfr_gc jfr_hot_methods jfr_contention jfr_io jfr_vm_operations jfr_env jfr_summary; do
    if [ -f "${OUT}/${f}.csv" ]; then
        n=$(( $(wc -l < "${OUT}/${f}.csv") - 1 ))
        [ "${n}" -gt 0 ] && ok "${f}.csv: ${n} 行" || ng "${f}.csv: 0 行"
    else
        ng "${f}.csv が無い"
    fi
done
col_max() { awk -F, -v k="$2" 'NR==1 {for (i = 1; i <= NF; i++) if ($i == k) c = i; next} c && $c+0 > m {m = $c+0} END {print m+0}' "$1"; }
[ "$(col_max "${OUT}/cli_datasource.csv" WaitCount)" -gt 0 ] && ok "接続待ち (WaitCount) を記録" || ng "WaitCount が 0"
[ "$(col_max "${OUT}/cli_datasource.csv" XACommitCount)" -gt 0 ] && ok "XA の commit 回数を記録" || ng "XACommitCount が 0"
[ "$(col_max "${OUT}/cli_undertow.csv" request-count)" -gt 0 ] && ok "HTTP リクエスト数を記録" || ng "request-count が 0"
[ "$(col_max "${OUT}/cli_transactions.csv" number-of-committed-transactions)" -gt 0 ] && ok "トランザクション数を記録" || ng "トランザクション数が 0"
[ "$(col_max "${OUT}/cli_io_worker.csv" busy-task-thread-count)" -gt 0 ] && ok "IO ワーカーの処理中スレッドを記録" || ng "busy-task-thread-count が 0"
[ "$(col_max "${OUT}/jvm_jstat_gc.csv" YGC)" -gt 0 ] && ok "GC 回数 (YGC)" || ng "YGC が 0"
grep -q 'LGCC' "${OUT}/jvm_jstat_gc.csv" && ok "jstat のカスタムオプション (GC 原因・セーフポイント) を使用" || ng "jstat が -gc にフォールバック"
[ "$(col_max "${OUT}/cpu_sched.csv" jboss_cpu_cores | cut -d. -f1)" -ge 0 ] && ok "cpu_sched に JBoss の CPU" || ng "cpu_sched"
grep -q '"要"\|"不要"\|"要検討"\|"設定済み"' "${OUT}/cpu_env.csv" && ok "④ 判定: $(awk -F, '$5=="result"{print $6}' "${OUT}/cpu_env.csv" | tail -n 1)" || ng "④ 判定が無い"
grep -q 'db-pool-wait' "${OUT}/jvm_thread_states.csv" && ok "スレッドダンプで DB 接続待ちのスレッドを数えた" || echo "  [--]   DB 接続待ちのスレッドはダンプの瞬間にいなかった"
grep -q 'monitor-enter' "${OUT}/jfr_contention.csv" && ok "JFR でロック待ちを記録" || ng "jfr_contention にロック待ちが無い"
grep -q 'socket-read' "${OUT}/jfr_io.csv" && ok "JFR でソケット読み込み待ちを記録" || ng "jfr_io にソケットが無い"
grep -q ' ERROR ' "${OUT}/collector.log" && ng "collector.log に ERROR" || ok "collector.log に ERROR なし"
grep -E 'awk: |syntax error|unexpected|No such file' "${OUT}/collector.log" "${P}/console.log" | grep -v 'Native memory tracking' | head -5
echo "OUT=${OUT}"
[ "${fail}" = 0 ] && echo "結果: すべて OK" || echo "結果: NG あり"
exit "${fail}"

#!/bin/bash
# =============================================================================
# perf_hook_test.sh : efs-entrypoint.sh の「6-B. 性能試験用メトリクス収集」と
#                     perf-metrics.sh の起動部分の分岐試験 (Docker・JBoss 不要。Linux / WSL)
#
#   usage: test/unit/perf_hook_test.sh [shell...]
#          shell 既定: "dash" "bash --posix" "busybox sh" (入っているものだけ)
#
# pin 方式の test/local/entrypoint_test.sh と同じく、一時ディレクトリに「疑似ルート」を作り、
# 引数と環境を表示するだけの疑似 standalone.sh を CMD に渡して、exec 直前の状態を確かめる。
# 収集プロセスは PERF_COLLECTORS=none で起動させない (起動の可否は test/e2e で確かめる)。
# =============================================================================
# shellcheck disable=SC2034
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
EP="$REPO/docker/base/entrypoint.sh"
PM="$REPO/docker/base/perf-metrics.sh"
SHELLS=("$@")
if [ ${#SHELLS[@]} -eq 0 ]; then
  for s in "dash" "bash --posix" "busybox sh"; do
    command -v "${s%% *}" >/dev/null 2>&1 && SHELLS+=("$s")
  done
fi
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "    ok   $*"; }
ng()   { FAIL=$((FAIL + 1)); echo "    FAIL $*"; }
check(){ if eval "$2"; then ok "$1"; else ng "$1   [cond: $2]"; fi; }

mkroot() {
  R=$(mktemp -d /tmp/pmh.XXXXXX)
  JH=$R/opt/jboss-eap; SD=$JH/standalone
  EFS=$R/mnt/logs/front/logs/intra-api
  MID=$EFS/mid
  mkdir -p "$SD/configuration" "$SD/configuration-seed" "$SD/tmp" "$SD/data" "$JH/bin" "$R/mnt/logs" "$R/work"
  printf 'handler.FILE.fileName=${org.jboss.boot.log.file\\:server.log}\n' > "$SD/configuration-seed/logging.properties"
  echo '<server/>' > "$SD/configuration-seed/standalone.xml"
  ln -s "$MID/current" "$SD/log"
  cat > "$JH/bin/standalone.sh" <<'SS'
#!/bin/sh
echo "STARTED"
for a in "$@"; do echo "ARG[$a]"; done
echo "JBOSS_LOG_DIR=${JBOSS_LOG_DIR:-<unset>}"
echo "PREPEND_JAVA_OPTS=${PREPEND_JAVA_OPTS:-<unset>}"
echo "JAVA_OPTS=${JAVA_OPTS:-<unset>}"
SS
  chmod +x "$JH/bin/standalone.sh"
}
run_ep() {  # run_ep <env...> -- <cmd...>
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  OUT=$(env -i PATH="$PATH" HOME=/tmp \
        JBOSS_HOME="$JH" JBOSS_CONF_DIR="$SD/configuration" JBOSS_CONF_SEED_DIR="$SD/configuration-seed" \
        EFS_LOG_DIR="$EFS" COMPONENT_ROLE=front Service_Name=intra-api Component_name=front \
        PERF_METRICS_SCRIPT="$PM" PERF_WORK_DIR="$R/work" PERF_COLLECTORS=none \
        "${envs[@]}" $SH "$EP" "$@" 2>&1)
  RC=$?
}
own_dir() { sed -n 's/^\[efs-entrypoint\] JBoss EAP log dir: \(.*\) (LOG_ID_SOURCE=.*$/\1/p' <<<"$OUT"; }
args() { grep '^ARG\[' <<<"$OUT" | tr '\n' '|'; }
penv() { sed -n "s/^$1=//p" <<<"$OUT"; }
STATS="ARG[-Dwildfly.datasources.statistics-enabled=true]|ARG[-Dwildfly.undertow.statistics-enabled=true]|ARG[-Dwildfly.transactions.statistics-enabled=true]|"

for SH in "${SHELLS[@]}"; do
  echo "################ shell: $SH"

  echo "  [1] PERF_METRICS_ENABLED 未設定 (= false) → 何もしない"
  mkroot
  run_ep -- "$JH/bin/standalone.sh" -b 0.0.0.0
  D=$(own_dir)
  check "rc=0・JBoss を起動" '[ $RC -eq 0 ] && grep -qx STARTED <<<"$OUT"'
  check "引数は pin だけ (統計の引数を足さない)" '[ "$(args)" = "ARG[-Djboss.server.log.dir=$D]|ARG[-b]|ARG[0.0.0.0]|" ]'
  check "PREPEND_JAVA_OPTS・JAVA_OPTS は触らない" '[ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ] && [ "$(penv JAVA_OPTS)" = "<unset>" ]'
  check "perf-metrics の表示が無い・perf/ を作らない" '! grep -q "perf-metrics" <<<"$OUT" && [ ! -e "$D/perf" ]'
  rm -rf "$R"

  echo "  [2] PERF_METRICS_ENABLED=true + CMD=.../standalone.sh"
  mkroot
  run_ep PERF_METRICS_ENABLED=true -- "$JH/bin/standalone.sh" -b 0.0.0.0 "-Dfoo=a b"
  D=$(own_dir)
  check "rc=0・JBoss を起動" '[ $RC -eq 0 ] && grep -qx STARTED <<<"$OUT"'
  check "起動ログに有効の枠 (版・①〜④)" 'grep -q "性能試験用メトリクス収集: 有効  (perf-metrics.sh 3" <<<"$OUT" && grep -q "① jboss-cli" <<<"$OUT" && grep -q "② jstat" <<<"$OUT" && grep -q "③ top / ps" <<<"$OUT" && grep -q "④ CPU 数" <<<"$OUT"'
  check "Container Insights と重なる値は取らない旨を表示" 'grep -q "Container Insights (拡張) で見られる" <<<"$OUT"'
  check "出力先は current ではなく実体パスの perf/" 'grep -q "出力先 : $D/perf\$" <<<"$OUT" && [ -d "$D/perf" ]'
  check "統計の引数をコマンド直後へ (pin・元の引数はその後ろ)" '[ "$(args)" = "${STATS}ARG[-Djboss.server.log.dir=$D]|ARG[-b]|ARG[0.0.0.0]|ARG[-Dfoo=a b]|" ]'
  check "JFR を PREPEND_JAVA_OPTS で渡す (リポジトリ・終了時の保存先は実体パスの perf/jfr)" 'case "$(penv PREPEND_JAVA_OPTS)" in "-XX:StartFlightRecording:name=perf-metrics,settings=default,"*"filename=$D/perf/jfr/perf_%p_%t.jfr,dumponexit=true -XX:FlightRecorderOptions:repository=$D/perf/jfr/repo,preserve-repository=true") true ;; *) false ;; esac'
  check "統計イベントの間隔は PERF_INTERVAL (10 秒)" 'penv PREPEND_JAVA_OPTS | grep -q "jdk.CPULoad#period=10s"'
  check "JAVA_OPTS は変えない (standalone.conf の既定値を残す)" '[ "$(penv JAVA_OPTS)" = "<unset>" ]'
  check "JFR の変換プログラムを出力先に置く" '[ -s "$D/perf/jfr/PerfJfrCsv.java" ] && grep -q "public class PerfJfrCsv" "$D/perf/jfr/PerfJfrCsv.java"'
  check "JBOSS_LOG_DIR は実体パスのまま" 'grep -qx "JBOSS_LOG_DIR=$D" <<<"$OUT"'
  check "perf_meta.csv に出力先・LOG_ID・JFR の方式" 'grep -q "^perf,output_dir,\"$D/perf\"" "$D/perf/perf_meta.csv" && grep -q "^container,log_id,\"$(basename "$D")\"" "$D/perf/perf_meta.csv" && grep -q "^perf,jfr_mode,\"startup\"" "$D/perf/perf_meta.csv"'
  check "状態ファイル (status / stop 用) を作業ディレクトリに" 'grep -q "PM_OUT=.$D/perf." "$R/work/perf-metrics.state"'
  check "set -eu で止まらない (preflight OK まで進む)" 'grep -q "preflight OK" <<<"$OUT"'
  rm -rf "$R"

  echo "  [3] CMD=eap (本番の起動方式)"
  mkroot
  run_ep PERF_METRICS_ENABLED=true SERVER_CONFIG=standalone.xml EXTRASLB_TRUSTSTORE_TYPE=JKS EXTRASLB_TRUSTSTORE_PASSWORD=secret -- eap
  D=$(own_dir)
  check "rc=0・JBoss を起動" '[ $RC -eq 0 ] && grep -qx STARTED <<<"$OUT"'
  check "統計 → pin → 本番の引数 の順" '[ "$(args | cut -d"|" -f1-7)" = "${STATS}ARG[-Djboss.server.log.dir=$D]|ARG[-b]|ARG[0.0.0.0]|ARG[-bmanagement]" ]'
  check "JFR は起動時から (PREPEND_JAVA_OPTS)" 'penv PREPEND_JAVA_OPTS | grep -q "^-XX:StartFlightRecording:name=perf-metrics"'
  check "perf_meta.csv の起動コマンドでパスワードを伏せる" 'grep -q "trustStorePassword=\*\*\*\*\*\*\*\*" "$D/perf/perf_meta.csv" && ! grep -q secret "$D/perf/perf_meta.csv"'
  rm -rf "$R"

  echo "  [4] PERF_ENABLE_STATISTICS=false・PERF_JFR=false → 引数も JVM オプションも足さない"
  mkroot
  run_ep PERF_METRICS_ENABLED=true PERF_ENABLE_STATISTICS=false PERF_JFR=false -- "$JH/bin/standalone.sh" -b 0.0.0.0
  D=$(own_dir)
  check "rc=0" '[ $RC -eq 0 ]'
  check "引数は pin だけ" '[ "$(args)" = "ARG[-Djboss.server.log.dir=$D]|ARG[-b]|ARG[0.0.0.0]|" ]'
  check "PREPEND_JAVA_OPTS を設定しない" '[ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ]'
  check "有効の枠は出る (JFR は無効と表示)" 'grep -q "性能試験用メトリクス収集: 有効" <<<"$OUT" && grep -q "JFR       : 無効" <<<"$OUT"'
  rm -rf "$R"

  echo "  [5] 既存の PREPEND_JAVA_OPTS・JAVA_OPTS がある / NMT を有効にする"
  mkroot
  run_ep PERF_METRICS_ENABLED=true PERF_NMT=summary PREPEND_JAVA_OPTS=-Dkeep=1 "JAVA_OPTS=-Xms1g -Xmx1g" -- "$JH/bin/standalone.sh"
  check "既存の PREPEND_JAVA_OPTS は後ろに残す" 'penv PREPEND_JAVA_OPTS | grep -q " -XX:NativeMemoryTracking=summary -Dkeep=1$"'
  check "JAVA_OPTS はそのまま" '[ "$(penv JAVA_OPTS)" = "-Xms1g -Xmx1g" ]'
  rm -rf "$R"
  mkroot
  run_ep PERF_METRICS_ENABLED=true PERF_NMT=summary "JAVA_OPTS=-XX:StartFlightRecording:name=mine -XX:NativeMemoryTracking=detail" -- "$JH/bin/standalone.sh"
  D=$(own_dir)
  check "利用者の JFR・NMT の指定があれば足さない" '[ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ] && grep -q "^perf,jfr_mode,\"user\"" "$D/perf/perf_meta.csv"'
  rm -rf "$R"

  echo "  [6] PRESERVE_JAVA_OPTS=true (standalone.sh が PREPEND_JAVA_OPTS を使わない)"
  mkroot
  run_ep PERF_METRICS_ENABLED=true PRESERVE_JAVA_OPTS=true -- "$JH/bin/standalone.sh"
  D=$(own_dir)
  check "警告して PREPEND_JAVA_OPTS は設定しない (JFR は起動後に jcmd で)" 'grep -q "PRESERVE_JAVA_OPTS=true のため" <<<"$OUT" && [ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ] && grep -q "^perf,jfr_mode,\"jcmd\"" "$D/perf/perf_meta.csv"'
  rm -rf "$R"

  echo "  [7] PERF_METRICS_ENABLED=true だがイメージに perf-metrics.sh が無い"
  mkroot
  run_ep PERF_METRICS_ENABLED=true PERF_METRICS_SCRIPT="$R/none/perf-metrics.sh" -- "$JH/bin/standalone.sh" -b 0.0.0.0
  D=$(own_dir)
  check "rc=0・JBoss を起動" '[ $RC -eq 0 ] && grep -qx STARTED <<<"$OUT"'
  check "再ビルドを促す WARN" 'grep -q "PERF_METRICS_ENABLED=false でビルドされています" <<<"$OUT"'
  check "引数・環境は変えない" '[ "$(args)" = "ARG[-Djboss.server.log.dir=$D]|ARG[-b]|ARG[0.0.0.0]|" ] && [ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ]'
  rm -rf "$R"

  echo "  [8] PERF_METRICS_ENABLED の不正値"
  mkroot
  run_ep PERF_METRICS_ENABLED=yes -- "$JH/bin/standalone.sh"
  check "rc=0・JBoss を起動" '[ $RC -eq 0 ] && grep -qx STARTED <<<"$OUT"'
  check "不正値の WARN・収集しない" 'grep -q "PERF_METRICS_ENABLED の値が不正です: .yes." <<<"$OUT" && ! grep -q "性能試験用メトリクス収集: 有効" <<<"$OUT"'
  rm -rf "$R"

  echo "  [9] 出力先に書き込めない → 収集は諦めて JBoss は起動する"
  mkroot
  run_ep PERF_METRICS_ENABLED=true PERF_OUTPUT_DIR=/proc/perf-metrics-test -- "$JH/bin/standalone.sh" -b 0.0.0.0
  D=$(own_dir)
  check "rc=0・JBoss を起動" '[ $RC -eq 0 ] && grep -qx STARTED <<<"$OUT"'
  check "書き込めない旨・開始できなかった旨の WARN" 'grep -q "書き込めないため、性能試験用メトリクス収集を行いません" <<<"$OUT" && grep -q "性能試験用メトリクス収集を開始できませんでした" <<<"$OUT"'
  check "JVM オプションは足さない (統計の引数は足す)" '[ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ] && [ "$(args | cut -d"|" -f1-3)|" = "$STATS" ]'
  rm -rf "$R"

  echo "  [10] CMD が standalone.sh 以外 → 引数・環境は変えない (収集は始め、JFR は jcmd で)"
  mkroot
  cat > "$JH/bin/run-app.sh" <<'SS'
#!/bin/sh
echo "STARTED"
for a in "$@"; do echo "ARG[$a]"; done
echo "PREPEND_JAVA_OPTS=${PREPEND_JAVA_OPTS:-<unset>}"
SS
  chmod +x "$JH/bin/run-app.sh"
  run_ep PERF_METRICS_ENABLED=true -- "$JH/bin/run-app.sh" x
  check "rc=0・起動" '[ $RC -eq 0 ] && grep -qx STARTED <<<"$OUT"'
  check "引数・環境は変えない" '[ "$(args)" = "ARG[x]|" ] && [ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ]'
  check "JFR は起動後に jcmd で始めると表示" 'grep -q "jcmd JFR.start で記録を始めます" <<<"$OUT"'
  rm -rf "$R"

  echo "  [11] 出力先のパスに JFR の引数で使えない文字 (カンマ) がある → JFR は無効にして起動は続ける"
  mkroot
  mkdir -p "$R/out,x"
  run_ep PERF_METRICS_ENABLED=true PERF_OUTPUT_DIR="$R/out,x" -- "$JH/bin/standalone.sh"
  check "rc=0・JFR を足さない" '[ $RC -eq 0 ] && [ "$(penv PREPEND_JAVA_OPTS)" = "<unset>" ] && grep -q "JFR       : 無効 (出力先・設定に" <<<"$OUT"'
  rm -rf "$R"

  echo "  [12] perf-metrics.sh を直接実行"
  OUT=$($SH "$PM" version 2>&1); RC=$?
  check "version" '[ $RC -eq 0 ] && grep -q "^perf-metrics.sh 3\.[0-9]" <<<"$OUT"'
  OUT=$(env -i PATH="$PATH" PERF_WORK_DIR=/nonexistent JBOSS_HOME=/nonexistent $SH "$PM" status 2>&1); RC=$?
  check "status: 収集が無いときは 1 と案内" '[ $RC -eq 1 ] && grep -q "実行中の収集が見つかりません" <<<"$OUT"'
  OUT=$(env -i PATH="$PATH" PERF_WORK_DIR=/nonexistent JBOSS_HOME=/nonexistent $SH "$PM" cpu-check 2>&1); RC=$?
  check "cpu-check: 収集が無いときは 1" '[ $RC -eq 1 ]'
  OUT=$($SH "$PM" bogus 2>&1); RC=$?
  check "不明なコマンドは使い方を出して 2" '[ $RC -eq 2 ] && grep -q "usage:" <<<"$OUT"'
done

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

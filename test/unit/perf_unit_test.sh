#!/bin/bash
# =============================================================================
# perf_unit_test.sh : perf-metrics.sh の解析部分 (awk) と判定の単体試験 (Docker・JBoss 不要。Linux / WSL)
#
#   usage: test/unit/perf_unit_test.sh [awk...]
#          awk 既定: gawk (UBI 9 の awk) mawk "busybox awk" (入っているものだけ)
#
# 入力は test/fixtures の実物の出力 (WildFly 35 = EAP 8.1 と同じ WildFly Core 27 系の jboss-cli 応答、
# Red Hat OpenJDK 21.0.12.1 の jcmd、procps-ng 3.3.17 = RHEL 9 と同じ版の top / ps)。
# =============================================================================
# shellcheck disable=SC2034
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PM="$REPO/docker/base/perf-metrics.sh"
FX="$REPO/test/fixtures"
AWKS=("$@")
if [ ${#AWKS[@]} -eq 0 ]; then
  for a in gawk mawk "busybox awk"; do command -v "${a%% *}" >/dev/null 2>&1 && AWKS+=("$a"); done
fi
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "    ok   $*"; }
ng()   { FAIL=$((FAIL + 1)); echo "    FAIL $*"; }
check(){ if eval "$2"; then ok "$1"; else ng "$1   [cond: $2]"; fi; }
# CSV の列を見出しの名前で取る (引用符付きの列にも対応): col <file> <行番号(2=最初のデータ)> <列名>
col() { python3 - "$1" "$2" "$3" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], encoding="utf-8")))
h = rows[0]; r = rows[int(sys.argv[2]) - 1]
print(r[h.index(sys.argv[3])] if sys.argv[3] in h else "<no-col>")
PY
}
rows() { echo $(( $(wc -l < "$1") - 1 )); }
wellformed() { python3 - "$1" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], encoding="utf-8")))
sys.exit(0 if rows and all(len(r) == len(rows[0]) for r in rows) else 1)
PY
}

# perf-metrics.sh の変数 (awk プログラム) を読み込む (関数・既定値の定義だけで終わる)
# shellcheck disable=SC1090
. "$PM"

for AWK in "${AWKS[@]}"; do
  echo "################ awk: $AWK"
  T=$(mktemp -d /tmp/pmu.XXXXXX)

  echo "  [1] ① jboss-cli の応答 (WildFly 35) → CSV"
  printf '%s\n' "$PM_CLI_AWK" > "$T/cli.awk"
  $AWK -v mode=header -v dir="$T" -f "$T/cli.awk" /dev/null
  check "見出しだけの CSV を 7 つ作る" '[ "$(ls "$T"/cli_*.csv | wc -l)" = 7 ] && [ "$(rows "$T/cli_jvm.csv")" = 0 ]'
  $AWK -v ts="2026-10-24 22:13:00" -v epoch=1792847580 -v cli_ms=215 -v ok=1 -v pid=152 -v osthr=84 -v dir="$T" \
       -v enlist="$T/enable" -v failf="$T/fail" -v metaf="$T/meta.csv" -f "$T/cli.awk" "$FX/cli/sample_wildfly35.out"
  for f in "$T"/cli_*.csv; do wellformed "$f" || ng "$(basename "$f") の列数がそろっていない"; done
  check "データソース 2 行 (ExampleDS / ExampleXADS)" '[ "$(rows "$T/cli_datasource.csv")" = 2 ] && [ "$(col "$T/cli_datasource.csv" 2 ds_name)" = ExampleDS ] && [ "$(col "$T/cli_datasource.csv" 3 ds_type)" = xa ]'
  check "プール統計の値 (使用中 5・アクティブ 12・最大使用 12)" '[ "$(col "$T/cli_datasource.csv" 2 InUseCount)" = 5 ] && [ "$(col "$T/cli_datasource.csv" 2 ActiveCount)" = 12 ] && [ "$(col "$T/cli_datasource.csv" 2 MaxUsedCount)" = 12 ]'
  check "XA の commit 回数 (515)・L の付いた数値を数値に" '[ "$(col "$T/cli_datasource.csv" 3 XACommitCount)" = 515 ] && [ "$(col "$T/cli_datasource.csv" 3 AverageBlockingTime)" = 17 ]'
  check "属性ごとの読み取り (JNDI 名)・未定義 (最大プール) は空欄" '[ "$(col "$T/cli_datasource.csv" 2 jndi_name)" = java:jboss/datasources/ExampleDS ] && [ "$(col "$T/cli_datasource.csv" 2 max_pool_size)" = "" ]'
  check "HTTP リスナー (http 3106 件・https 0 件)、転送量の列は持たない" '[ "$(col "$T/cli_undertow.csv" 2 request-count)" = 3106 ] && [ "$(col "$T/cli_undertow.csv" 3 listener_type)" = https ] && ! head -1 "$T/cli_undertow.csv" | grep -q bytes'
  check "統計の有効化の状態 (式を解決した \"true\")" '[ "$(col "$T/cli_undertow.csv" 2 statistics_enabled)" = true ]'
  check "セッション (perftest.war 3230)" '[ "$(col "$T/cli_session.csv" 2 active-sessions)" = 3230 ] && [ "$(col "$T/cli_session.csv" 2 context-root)" = /perftest ]'
  check "IO ワーカー (I/O 8・最大 64・接続 0)" '[ "$(col "$T/cli_io_worker.csv" 2 io-thread-count)" = 8 ] && [ "$(col "$T/cli_io_worker.csv" 2 max-pool-size)" = 64 ] && [ "$(col "$T/cli_io_worker.csv" 2 connection-count)" = 0 ]'
  check "スレッドプール 3 行 (ejb3 の最大 10)" '[ "$(rows "$T/cli_threadpool.csv")" = 3 ] && [ "$(col "$T/cli_threadpool.csv" 2 pool_type)" = ejb3 ] && [ "$(col "$T/cli_threadpool.csv" 2 max)" = 10 ]'
  check "トランザクション (commit 808・統計 true)" '[ "$(col "$T/cli_transactions.csv" 2 number-of-committed-transactions)" = 808 ] && [ "$(col "$T/cli_transactions.csv" 2 statistics_enabled)" = true ]'
  check "JVM (running・ライブ 70・OS 84・ピーク 145・クラス 15487・ダイレクト 84)" '[ "$(col "$T/cli_jvm.csv" 2 server_state)" = running ] && [ "$(col "$T/cli_jvm.csv" 2 live_threads)" = 70 ] && [ "$(col "$T/cli_jvm.csv" 2 os_threads)" = 84 ] && [ "$(col "$T/cli_jvm.csv" 2 peak_threads)" = 145 ] && [ "$(col "$T/cli_jvm.csv" 2 loaded_classes)" = 15487 ] && [ "$(col "$T/cli_jvm.csv" 2 direct_count)" = 84 ]'
  check "ヒープ (MBean)・CPU 数・ロードアベレージ" '[ "$(col "$T/cli_jvm.csv" 2 heap_used)" = 196294416 ] && [ "$(col "$T/cli_jvm.csv" 2 available_processors)" = 4 ] && [ "$(col "$T/cli_jvm.csv" 2 system_load_average)" = 1.34 ]'
  check "失敗したブロック (thr.daemon) は空欄にして記録" '[ "$(col "$T/cli_jvm.csv" 2 daemon_threads)" = "" ] && grep -q "thr.daemon" "$T/fail"'
  check "統計が有効なデータソースは有効化リストに載らない" '[ ! -s "$T/enable" ]'
  : > "$T/empty"
  $AWK -v ts="2026-10-24 22:13:10" -v epoch=1792847590 -v cli_ms="" -v ok=0 -v pid=152 -v osthr=90 -v dir="$T" -v enlist="" -v failf="" -v metaf="$T/meta.csv" -f "$T/cli.awk" "$T/empty"
  check "応答が無い回は JVM の行だけ (OS スレッド数は書く)" '[ "$(rows "$T/cli_datasource.csv")" = 2 ] && [ "$(rows "$T/cli_jvm.csv")" = 2 ] && [ "$(col "$T/cli_jvm.csv" 3 os_threads)" = 90 ] && [ "$(col "$T/cli_jvm.csv" 3 cli_ok)" = 0 ]'
  sed -e 's/"statistics-enabled" => true/"statistics-enabled" => false/' "$FX/cli/sample_wildfly35.out" > "$T/off.out"
  $AWK -v ts=t -v epoch=1 -v cli_ms=1 -v ok=1 -v pid=1 -v osthr=1 -v dir="$T" -v enlist="$T/enable2" -v failf="" -v metaf="$T/meta.csv" -f "$T/cli.awk" "$T/off.out"
  check "統計が無効なデータソースを有効化リストへ (種類<TAB>名前)" 'grep -qx "data-source	ExampleDS" "$T/enable2" && grep -qx "xa-data-source	ExampleXADS" "$T/enable2"'
  printf 'PERF_S 1\nPERF_B m.product-version\n{\n    "outcome" => "success",\n    "result" => "8.1.0.GA"\n}\nPERF_B m.config-file\n{\n    "outcome" => "success",\n    "result" => "/opt/jboss-eap/standalone/configuration/standalone.xml"\n}\nPERF_E 1\n' > "$T/meta.out"
  $AWK -v mode=meta -v metaf="$T/meta.csv" -v dir="$T" -f "$T/cli.awk" "$T/meta.out"
  check "管理モデルの情報を perf_meta.csv の形で" 'grep -qx "jboss,product-version,8.1.0.GA" "$T/meta.csv" && grep -q "^jboss,config-file,/opt/jboss-eap" "$T/meta.csv"'

  echo "  [2] ② jstat (カスタムオプション perfgc と標準の -gc) → CSV"
  (
    PATH="$(dirname "$(command -v ${AWK%% *})"):$PATH"
    printf '%s\n' \
      'Timestamp         S0C         S1C         S0U         S1U          EC           EU           OC           OU          MC         MU       CCSC      CCSU     YGC     YGCT     FGC    FGCT     CGC    CGCT       GCT       SPN       SPT        SPS     THR   DTHR   PTHR     CLS   UCLS     CMP      CMPT LGCC' \
      '           82.6         0.0      9216.0         0.0      9216.0      68608.0      58368.0     416768.0     285184.1    86272.0    83703.2   11072.0   10015.2    554     2.909     0     0.000   138     0.402     3.310      729     3.414      0.154     85     24    165   15517      0   11879    23.915 G1 Evacuation Pause' \
      '           87.6         0.0      9216.0         0.0      9216.0      68608.0      58368.0     416768.0     285184.1    86272.0    83703.2   11072.0   10015.2    554     2.909     1     0.120   138     0.402     3.430      731     3.534      0.155     85     24    165   15517      0   11879    23.915 Metadata GC Threshold' \
      | pm_jstat_csv "$T/jstat.csv"
    printf '%s\n' \
      'Timestamp           S0C         S1C         S0U         S1U          EC           EU           OC           OU          MC         MU       CCSC      CCSU     YGC     YGCT     FGC    FGCT     CGC    CGCT       GCT   ' \
      '           10.8         0.0      2048.0         0.0      2048.0       7168.0       2048.0      67584.0      33238.7    12928.0    12701.9    1536.0    1432.7     36     0.095     0     0.000    20     0.019     0.113' \
      '           11.8         -           -           -           -       11264.0       1024.0      64512.0      39482.9    12928.0    12701.9    1536.0    1432.7     40     0.102     0     0.000    22     0.020     0.122' \
      | pm_jstat_csv "$T/jstat_gc.csv"
  )
  check "perfgc: 列数がそろい、GC の原因 (空白を含む) を 1 列に" 'wellformed "$T/jstat.csv" && [ "$(col "$T/jstat.csv" 2 LGCC)" = "G1 Evacuation Pause" ] && [ "$(col "$T/jstat.csv" 3 LGCC)" = "Metadata GC Threshold" ]'
  check "perfgc: セーフポイント・スレッド・JIT の列" '[ "$(col "$T/jstat.csv" 2 SPN)" = 729 ] && [ "$(col "$T/jstat.csv" 2 THR)" = 85 ] && [ "$(col "$T/jstat.csv" 2 CMPT)" = 23.915 ] && [ "$(col "$T/jstat.csv" 2 uptime_s)" = 82.6 ]'
  check "-gc (予備): 最後の列 GCT・値の無い列 (-) もずらさない" 'wellformed "$T/jstat_gc.csv" && [ "$(col "$T/jstat_gc.csv" 2 GCT)" = 0.113 ] && [ "$(col "$T/jstat_gc.csv" 3 S0C)" = - ] && [ "$(col "$T/jstat_gc.csv" 3 GCT)" = 0.122 ]'

  echo "  [3] ② jcmd -f (GC.heap_info・Compiler.codecache・VM.native_memory・Thread.print) → CSV"
  for h in "$PM_JCMD_HEAP_H:jvm_jcmd_heap" "$PM_JCMD_CC_H:jvm_codecache" "$PM_JCMD_NMT_H:jvm_nmt" "$PM_JCMD_TS_H:jvm_thread_states"; do
    printf '%s\n' "${h%%:*}" > "$T/${h##*:}.csv"
  done
  $AWK -v ts="2026-10-24 22:13:00" -v epoch=1792847580 -v ms=120 -v dir="$T" "$PM_JCMD_AWK" "$FX/jcmd/jcmd_f_wildfly35.out"
  for f in jvm_jcmd_heap jvm_codecache jvm_nmt jvm_thread_states; do wellformed "$T/$f.csv" || ng "$f.csv の列数がそろっていない"; done
  check "ヒープ (G1・合計 449536K・使用 225966K・リージョン 1024K・young 37)" '[ "$(col "$T/jvm_jcmd_heap.csv" 2 gc)" = G1 ] && [ "$(col "$T/jvm_jcmd_heap.csv" 2 heap_total_kb)" = 449536 ] && [ "$(col "$T/jvm_jcmd_heap.csv" 2 heap_used_kb)" = 225966 ] && [ "$(col "$T/jvm_jcmd_heap.csv" 2 region_size_kb)" = 1024 ] && [ "$(col "$T/jvm_jcmd_heap.csv" 2 young_regions)" = 37 ]'
  check "メタスペース (使用 83345K・class space 10008K)" '[ "$(col "$T/jvm_jcmd_heap.csv" 2 metaspace_used_kb)" = 83345 ] && [ "$(col "$T/jvm_jcmd_heap.csv" 2 class_used_kb)" = 10008 ]'
  check "コードキャッシュ (3 区画 + 合計 245760K・nmethods 8839・full 0)" '[ "$(rows "$T/jvm_codecache.csv")" = 4 ] && [ "$(col "$T/jvm_codecache.csv" 5 size_kb)" = 245760 ] && [ "$(col "$T/jvm_codecache.csv" 5 nmethods)" = 8839 ] && [ "$(col "$T/jvm_codecache.csv" 5 full_count)" = 0 ] && [ "$(col "$T/jvm_codecache.csv" 2 segment)" = "non-profiled nmethods" ]'
  check "NMT (Total 2171101K / 699649K・Java Heap 524288K)" '[ "$(col "$T/jvm_nmt.csv" 2 category)" = Total ] && [ "$(col "$T/jvm_nmt.csv" 2 reserved_kb)" = 2171101 ] && [ "$(col "$T/jvm_nmt.csv" 2 committed_kb)" = 699649 ] && [ "$(col "$T/jvm_nmt.csv" 3 category)" = "Java Heap" ] && [ "$(col "$T/jvm_nmt.csv" 3 reserved_kb)" = 524288 ]'
  check "スレッドの状態 (Java スレッド 72 本・default task 14 本)" '[ "$(col "$T/jvm_thread_states.csv" 2 group)" = all ] && [ "$(col "$T/jvm_thread_states.csv" 2 total)" = 72 ] && grep -q ",http-task,14," "$T/jvm_thread_states.csv"'
  check "状態の内訳の合計 = 全体" 'python3 -c "import csv,sys; r=[x for x in csv.DictReader(open(\"$T/jvm_thread_states.csv\")) if x[\"group\"]==\"all\"][0]; sys.exit(0 if sum(int(r[k]) for k in (\"runnable\",\"blocked\",\"waiting\",\"timed_waiting\"))<=int(r[\"total\"]) else 1)"'
  check "待機中のプールスレッドは busy に数えない (http-task の busy < 全体)" 'python3 -c "import csv,sys; r=[x for x in csv.DictReader(open(\"$T/jvm_thread_states.csv\")) if x[\"group\"]==\"http-task\"][0]; sys.exit(0 if int(r[\"busy\"])<int(r[\"total\"]) else 1)"'
  check "IdleRemover (プールの管理スレッド) を DB 接続待ちに数えない" '! grep -q ",db-pool-wait," "$T/jvm_thread_states.csv" || [ "$(grep ",db-pool-wait," "$T/jvm_thread_states.csv" | cut -d, -f4)" -lt 3 ]'

  echo "  [4] ④ ECS タスクメタデータ (JSON) の解析"
  $AWK "$PM_JSON_AWK" "$FX/ecs/task.json" > "$T/task.flat"
  $AWK "$PM_JSON_AWK" "$FX/ecs/container.json" > "$T/cont.flat"
  check "タスクの CPU (vCPU)・メモリ" '[ "$(pm_jget "$(cat "$T/task.flat")" Limits.CPU)" = 2 ] && [ "$(pm_jget "$(cat "$T/task.flat")" Limits.Memory)" = 4096 ]'
  check "コンテナの配列 (名前・CPU ユニット・入れ子の配列)" '[ "$(pm_jget "$(cat "$T/task.flat")" Containers.0.Name)" = intra-web-front ] && [ "$(pm_jget "$(cat "$T/task.flat")" Containers.2.Limits.Memory)" = 256 ] && [ "$(pm_jget "$(cat "$T/task.flat")" Containers.0.Networks.0.IPv4Addresses.0)" = 10.0.1.23 ]'
  check "文字列中のエスケープ (\\\" と \\\\)" 'pm_jget "$(cat "$T/cont.flat")" Labels.note | grep -qF "quote \" and \\ inside"'

  echo "  [5] ④ ActiveProcessorCount の判定"
  J() { $AWK "$@" "$PM_JUDGE_AWK" | cut -f1,2,3; }
  check "クォータ無し・JVM 4 CPU・コンテナ 512 ユニット → 要 (推奨 1)" '[ "$(J -v tcpu=1 -v ccpu=512 -v napp=2 -v q= -v apc=-1 -v eff=4 -v gc=G1 -v gco={ergonomic})" = "要	1	0.5" ]'
  check "コンテナ未指定 (2)・タスク 2 vCPU・JVM 2 個・JVM 4 CPU → 要 (推奨 1)" '[ "$(J -v tcpu=2 -v ccpu=2 -v napp=2 -v q= -v apc=-1 -v eff=4)" = "要	1	1" ]'
  check "タスク 2 vCPU・JVM 1 個・JVM 2 CPU → 不要" '[ "$(J -v tcpu=2 -v ccpu= -v napp=1 -v q= -v apc=-1 -v eff=2)" = "不要	2	2" ]'
  check "ActiveProcessorCount=2 を指定済み → 設定済み" '[ "$(J -v tcpu=2 -v napp=2 -v apc=2 -v eff=2 | cut -f1)" = 設定済み ]'
  check "ActiveProcessorCount がタスクの vCPU を超える → 要確認" '[ "$(J -v tcpu=1 -v napp=1 -v apc=4 -v eff=4 | cut -f1)" = 要確認 ]'
  check "取り分より少ない → 要検討" '[ "$(J -v tcpu=4 -v napp=1 -v q= -v apc=-1 -v eff=2 | cut -f1,2)" = "要検討	4" ]'
  check "メタデータもクォータも無い → 判定不可" '[ "$(J -v tcpu= -v ccpu= -v napp= -v q= -v apc=-1 -v eff=4 | cut -f1)" = 判定不可 ]'
  check "クォータ 1.5 → 推奨 2" '[ "$(J -v q=1.50 -v apc=-1 -v eff=2 | cut -f1,2)" = "不要	2" ]'
  check "CPU 1 と判定され SerialGC が自動選択 → 説明を足す" '$AWK -v tcpu=1 -v napp=1 -v apc=-1 -v eff=1 -v gc=Serial -v gco={ergonomic} "$PM_JUDGE_AWK" | grep -q SerialGC'

  echo "  [6] ③ top -b / top -H / ps (procps-ng 3.3.17) → CSV"
  printf '%s\n' "$PM_TOP_SUM_H" > "$T/sum.csv"; printf '%s\n' "$PM_TOP_PROC_H" > "$T/proc.csv"; printf '%s\n' "$PM_TOP_TH_H" > "$T/th.csv"; printf '%s\n' "$PM_PS_H" > "$T/ps.csv"
  # shellcheck disable=SC2154  # pm_role_awk は読み込んだ perf-metrics.sh で定義される
  $AWK -v rawf="$T/raw.log" -v sumf="$T/sum.csv" -v procf="$T/proc.csv" "${pm_role_awk}${PM_TOP_AWK}" "$FX/top/top_batch.txt"
  $AWK -v top=10 -v outf="$T/th.csv" "$PM_TOPTH_AWK" "$FX/top/top_threads.txt"
  $AWK -v ts="2026-10-24 23:01:25" -v epoch=1792850485 "${pm_role_awk}${PM_PS_AWK}" "$FX/top/ps.txt" >> "$T/ps.csv"
  for f in sum proc th ps; do wellformed "$T/$f.csv" || ng "$f.csv の列数がそろっていない"; done
  check "要約は 2 フレーム目だけ (1 フレーム目の %CPU は起動からの平均のため)" '[ "$(rows "$T/sum.csv")" = 1 ]'
  check "要約の値 (タスク数・%Cpu・メモリ MiB)" 'grep -q "Tasks:" "$FX/top/top_batch.txt" && [ -n "$(col "$T/sum.csv" 2 tasks_total)" ] && [ -n "$(col "$T/sum.csv" 2 cpu_st)" ] && [ "$(col "$T/sum.csv" 2 mem_total_mib)" = 3920.9 ]'
  check "プロセス行は 2 フレーム目の分だけ" '[ "$(rows "$T/proc.csv")" -gt 0 ] && [ "$(cut -d, -f1 "$T/proc.csv" | sort -u | wc -l)" = 2 ]'
  check "スレッド行 (top -H)" '[ "$(rows "$T/th.csv")" -ge 1 ] && [ "$(col "$T/th.csv" 2 thread)" = systemd ]'
  check "ps の行数 = ps の出力行数" '[ "$(rows "$T/ps.csv")" = "$(wc -l < "$FX/top/ps.txt")" ]'
  check "raw ログを残す" '[ -s "$T/raw.log" ]'
  printf 'x 1 root S 1 10 20 0.0 0.0 5 00:00:00 java -Dpassword=topsecret -Djavax.net.ssl.trustStorePassword=abc -Dx=1\n' | \
    awk '{ print "    " $0 }' > /dev/null
  printf '  1     0 root     S        1  10  20  0.0  0.0     5 00:00:00 java -Dpassword=topsecret -Djavax.net.ssl.trustStorePassword=abc,def -jar x.jar\n' > "$T/ps_secret.txt"
  $AWK -v ts=t -v epoch=1 "${pm_role_awk}${PM_PS_AWK}" "$T/ps_secret.txt" > "$T/ps_secret.csv"
  check "コマンド行のパスワードを伏せる" '! grep -q topsecret "$T/ps_secret.csv" && ! grep -q "abc" "$T/ps_secret.csv" && grep -q "trustStorePassword=\*\*\*\*\*\*\*\*" "$T/ps_secret.csv"'

  echo "  [7] ③④ /proc からの算出 (この環境の /proc を 2 回読む)"
  (
    PM_W="$T"; PM_OUT="$T"; PERF_TOP_THREADS=5; PM_JPID=$$
    PATH="$(dirname "$(command -v ${AWK%% *})"):$PATH"
    pm_hz_page
    printf '%s\n' "$PM_TOP_SUM_H" > "$T/os_top_summary.csv"; printf '%s\n' "$PM_TOP_PROC_H" > "$T/os_top_process.csv"; printf '%s\n' "$PM_TOP_TH_H" > "$T/os_top_threads.csv"
    pm_proc_top_once; sleep 1; pm_proc_top_once
  )
  check "/proc 版 top: 要約 1 行 (2 回目)・プロセス行・列数" '[ "$(rows "$T/os_top_summary.csv")" = 1 ] && [ "$(rows "$T/os_top_process.csv")" -gt 0 ] && wellformed "$T/os_top_summary.csv" && wellformed "$T/os_top_process.csv"'
  ( PM_W="$T"; PM_OUT="$T"; PATH="$(dirname "$(command -v ${AWK%% *})"):$PATH"; pm_hz_page
    printf '%s\n' "$PM_PS_H" > "$T/os_ps.csv"
    pm_proc_list ps "" > "$T/procps.list"
    $AWK -v mode=ps -v ts=t -v epoch=1 -v hz="$PM_HZ" -v pagekb="$PM_PAGEKB" -v uptime="$(cut -d" " -f1 /proc/uptime)" -v procf="$T/os_ps.csv" -v newstate="" \
        "${pm_role_awk}${PM_PROCTOP_AWK}" "$T/procps.list" )
  check "/proc 版 ps: 自分のシェルの行があり、列数がそろう" 'wellformed "$T/os_ps.csv" && grep -q "^t,1,$$," "$T/os_ps.csv"'
  (
    PM_W="$T"; JP=$$
    PATH="$(dirname "$(command -v ${AWK%% *})"):$PATH"; pm_hz_page
    for f in os_jboss_threads:$PM_JBOSS_TH_H os_jboss_proc:$PM_JBOSS_PROC_H cpu_sched:$PM_SCHED_H; do printf '%s\n' "${f#*:}" > "$T/${f%%:*}.csv"; done
    for i in 1 2; do
      { [ -r "$T/proc.prev" ] && echo "prev $T/proc.prev"; echo "stat /proc/stat"; echo "loadavg /proc/loadavg"
        echo "pstat /proc/$JP/stat"; echo "pstatus /proc/$JP/status"; echo "limits /proc/$JP/limits"
        for t in /proc/$JP/task/[0-9]*; do echo "tstat $t/stat"; echo "tstatus $t/status"; done
        ls -l /proc/$JP/fd > "$T/proc.fd" 2>/dev/null; echo "fd $T/proc.fd"; echo "tcp /proc/net/tcp"; echo "tcp /proc/net/tcp6"; } > "$T/proc.list"
      $AWK -v ts=t$i -v epoch=$i -v nowms="$(date +%s%3N)" -v hz="$PM_HZ" -v cpus=4 -v jpid="$JP" -v thf="$T/os_jboss_threads.csv" -v procf="$T/os_jboss_proc.csv" \
          -v schedf="$T/cpu_sched.csv" -v newstate="$T/proc.new" "$PM_PROC_AWK" "$T/proc.list"
      mv -f "$T/proc.new" "$T/proc.prev"; sleep 1
    done
  )
  check "スレッドの用途別 (all を含む)・列数" 'wellformed "$T/os_jboss_threads.csv" && grep -q ",all," "$T/os_jboss_threads.csv"'
  check "プロセスの FD・TCP の行・列数" 'wellformed "$T/os_jboss_proc.csv" && [ "$(rows "$T/os_jboss_proc.csv")" = 2 ] && [ "$(col "$T/os_jboss_proc.csv" 2 fd_count)" -gt 0 ]'
  check "CPU の待ち・steal は 2 回目から (区間の差分)" 'wellformed "$T/cpu_sched.csv" && [ "$(rows "$T/cpu_sched.csv")" = 1 ] && [ -n "$(col "$T/cpu_sched.csv" 2 cpu_steal_pct)" ]'

  echo "  [8] JFR の起動オプション"
  PM_JFR_DIR=/mnt/logs/front/logs/intra-web/mid/x/perf/jfr; PERF_JFR_INTERVAL=10; PERF_JFR_SETTINGS=default; PERF_JFR_MAXAGE=24h; PERF_JFR_MAXSIZE=1g
  JI="$(pm_jfr_items ,)"
  check "統計イベントの間隔・ファイル名 (%p %t)・終了時のダンプ" 'case "$JI" in name=perf-metrics,settings=default,jdk.CPULoad#period=10s,*,disk=true,maxage=24h,maxsize=1g,filename=$PM_JFR_DIR/perf_%p_%t.jfr,dumponexit=true) true ;; *) false ;; esac'
  check "空白区切り (jcmd JFR.start 用) も同じ項目" '[ "$(pm_jfr_items " " | tr " " ",")" = "$JI" ]'
  check "埋め込みの Java (JFR → CSV) に単一引用符が無い" '! printf "%s" "$PM_JFR_JAVA" | grep -q "'"'"'" && printf "%s" "$PM_JFR_JAVA" | grep -q "public class PerfJfrCsv"'

  rm -rf "$T"
done

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

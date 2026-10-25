#!/bin/sh
# =============================================================================
# perf-metrics.sh (Lite)
#
# 性能試験 (JMeter など) の間、ECS タスク (Fargate) のコンテナで動く JBoss EAP 8.1 /
# Red Hat build of OpenJDK 21 (UBI 9.8) から、CloudWatch Container Insights (拡張
# オブザーバビリティ) では見えない値だけを、指定した間隔 (既定 10 秒) で取得し、
# readonlyRootFilesystem=true でも書き込める EFS 上の
#     /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current/perf/
#     例) /mnt/logs/front/logs/intra-web/mid/current/perf/
# へ CSV で書き出す。取得するのは次の 3 つだけ。
#
#   ① DB 接続プール (jboss-cli)
#        データソース / XA データソースごとの
#          統計 : 使用中・アクティブ・アイドル・取得可能・最大使用数、空き待ち・取得失敗・
#                 取得 / 待ち / 使用 / 作成 / プール滞在時間 (平均・最大・合計)、物理接続の
#                 作成・破棄、XA の start / end / prepare / commit / rollback / recover / forget、
#                 PreparedStatement キャッシュ (statistics=pool / statistics=jdbc)
#          情報 : 最小・初期・最大プール、取得タイムアウト、アイドル破棄、検証・フラッシュ・
#                 再試行の設定、ドライバー・接続 URL (パスワードは伏せる) など
#   ② ヒープ・GC (jstat / jcmd / JFR)
#        jstat : ヒープ各領域・メタスペースの容量 / 使用量、GC の回数 / 時間、直近の GC の原因、
#                セーフポイント (常駐 1 プロセス。カスタムの表示オプション perfgc)
#        jcmd  : ヒープ・G1 のリージョン・メタスペース・クラス空間の詳細 (GC.heap_info)、
#                JVM の版・起動引数・フラグ (VM.version / VM.command_line / VM.flags)
#        JFR   : Red Hat build of OpenJDK 21 の Flight Recorder で、ヒープ・GC・設定のイベント
#                だけを JBoss の起動時から記録し (PERF_JFR_SETTINGS=heap)、収集中に CSV にする
#                (ヒープ・領域別の使用量・割り当て速度・その間の GC は PERF_JFR_INTERVAL 秒ごと、
#                 GC は 1 回ずつ: 停止時間・原因・前後のヒープ・メタスペース・GC の CPU 時間)
#   ③ -XX:ActiveProcessorCount の要否の判断材料
#        このコンテナの CPU の取り分 (ECS タスクメタデータ v4)・cgroup の CPU の上限 / シェア・
#        OS と JVM が認識した CPU 数・それで決まった GC / JIT / Undertow のスレッド数
#        (jcmd・jboss-cli・新しい JVM のプローブ) と判定 (cpu_env.csv)。試験中の JBoss の
#        スレッドの用途別 (GC・JIT・アプリ) の CPU・実行待ち・steal・PSI・スロットリング・
#        非自発的なコンテキストスイッチ (/proc、cgroup) を間隔ごとに (cpu_sched.csv・cpu_threads.csv)
#
#   Container Insights (拡張) で見られるタスク / コンテナの CPU 使用率・メモリ使用量・
#   ネットワーク / ストレージの転送量・再起動回数は取得しない (JFR でも記録しない)。
#
# 性能試験用の実装はこの 1 ファイルにまとめている。
#   ビルド時: front / back の Dockerfile が、ビルド引数 PERF_METRICS_ENABLED=true の
#             ときだけこのファイルを残し `perf-metrics.sh install` で必要なコマンドを確かめる。
#             false (既定) ならファイルを削除する (本番と同じ中身になる)。
#   起動時  : efs-entrypoint.sh が PERF_METRICS_ENABLED=true のときだけこのファイルを
#             読み込み (.) perf_metrics_start を呼ぶ。収集は別プロセスで行い、
#             JBoss の起動を待たせない。収集側で何が起きても JBoss の起動は止めない。
#             JBoss に足す JVM オプション (JFR) は PREPEND_JAVA_OPTS で渡し、
#             JAVA_OPTS (= standalone.conf の既定ヒープ等) は変えない。
#
# 【出力先】 (readonlyRootFilesystem=true でも書き込める場所)
#   /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current/perf/
#   current はエントリポイントが起動のたびに「このタスクの mid/<LOG_ID>」へ張り替える EFS 上の
#   リンクなので、起動したタスクの perf/ は mid/current/perf/ で見られる。ただし current は
#   同じ EFS を使う全タスクが共有して張り替えるため、書き込みの経路には使わない (server.log を
#   実体パスへ固定 (pin) しているのと同じ理由。後から起動した別タスクのディレクトリに書かないため)。
#   起動時に current が指していた実体パス (エントリポイントが決めた JBOSS_LOG_DIR = mid/<LOG_ID>)
#   の perf/ へ直接書く。JBOSS_LOG_DIR が無いときは、起動時点の mid/current を実体パスへ解決する。
#   FIFO・PID ファイルなどの作業ファイルはタスクローカルの書き込み可能領域
#   (/tmp → standalone/tmp → 出力先/.work の順に、書けるところ) に置く。
#
# 【出力ファイル】 (UTF-8・LF・1 行目が見出しの CSV。timestamp はコンテナの TZ、epoch は UNIX 秒)
#   perf_meta.csv / collector.log          収集条件・環境 (category,key,value) / 収集プロセスのログ
#   ① cli_datasource.csv                   DB 接続プールの統計 (データソースごと・間隔ごと)
#      cli_datasource_info.csv              DB 接続プールの情報 (最初と、変わったときだけ)
#   ② jvm_jstat_gc.csv                     ヒープ各領域・GC (jstat、間隔ごと)
#      jvm_jcmd_heap.csv  jvm_info.txt      ヒープの詳細 (jcmd GC.heap_info、間隔ごと) / JVM の版・フラグ
#      jfr_heap.csv  jfr_gc.csv             ヒープ・割り当て・GC (JFR、間隔ごと) / GC 1 回ずつ (JFR)
#      jfr_env.csv  jfr_summary.csv         GC・ヒープ・CPU の設定 (JFR) / 記録とイベントの件数
#      jfr/perf_<pid>_<日時>.jfr            JFR の記録 (JBoss 終了時。記録中は jfr/repo/ にチャンク)
#   ③ cpu_env.csv                          ActiveProcessorCount の判断材料と判定 (JVM ごとに 1 回)
#      cpu_sched.csv  cpu_threads.csv       CPU の使われ方・待ち (間隔ごと) / JBoss のスレッドの用途別
#
# 【使い方】
#   ビルド    : docker build --build-arg PERF_METRICS_ENABLED=true ... docker/front
#   起動      : 何もしなくてよい (エントリポイントが起動時に読み込む)
#   状態確認  : perf-metrics.sh status            (ECS Exec でコンテナに入って実行)
#   ③ の判定  : perf-metrics.sh cpu-check
#   停止      : perf-metrics.sh stop              (収集を止める。JFR は JBoss 側で記録を続ける)
#   JFR       : perf-metrics.sh jfr-dump | jfr-csv
#   スレッド  : perf-metrics.sh threaddump        (その場で 1 回取得)
#   まとめる  : perf-metrics.sh pack              (perf/ を tar 1 ファイルにする)
#   レポート  : perf/ を Windows に持ってきて New-PerfMetricsReport.ps1 で Excel にする
#
# 【設定】 (環境変数。ビルド時の ENV・タスク定義の environment のどちらでも指定できる)
#   PERF_METRICS_ENABLED     true | false     収集するか (ビルド引数から ENV に焼き込む)
#   PERF_INTERVAL            10               各収集の既定の間隔 (秒)
#   PERF_CLI_INTERVAL        PERF_INTERVAL    ① jboss-cli の間隔 (秒)
#   PERF_JSTAT_INTERVAL      PERF_INTERVAL    ② jstat の間隔 (秒)
#   PERF_JCMD_INTERVAL       60               ② jcmd の間隔 (秒。1 回ごとに JVM を起動するため長め)
#   PERF_JFR_INTERVAL        PERF_INTERVAL    ② JFR の定期イベント (ヒープ・割り当て) の間隔 (秒)
#   PERF_CPU_INTERVAL        PERF_INTERVAL    ③ CPU の使われ方 (/proc・cgroup) の間隔 (秒)
#   PERF_COLLECTORS          "cli jstat jcmd jfr cpu"   動かす収集 (空白区切り。none で全停止)
#   PERF_OUTPUT_DIR / PERF_WORK_DIR   (自動)  出力先 / 作業ディレクトリを明示するとき
#   PERF_TZ                  (コンテナの TZ)  タイムスタンプのタイムゾーン (例 Asia/Tokyo)
#   PERF_ENABLE_STATISTICS   true             standalone.sh に -Dwildfly.datasources.statistics-enabled=true を足す
#   PERF_CLI_ENABLE_DS_STATS true             それでも統計が無効なデータソースを実行時に有効化
#   PERF_CLI_CONTROLLER      (自動)           例 remote+http://127.0.0.1:9990
#   PERF_CLI_USER / PERF_CLI_PASSWORD         ローカル認証が使えないときの管理ユーザー
#   PERF_CLI_TIMEOUT         30               1 回の取得のタイムアウト (秒)
#   PERF_CLI_HEAP            64m              jboss-cli の最大ヒープ
#   PERF_JFR                 true             JFR を記録する (true | false)
#   PERF_JFR_SETTINGS        heap             heap (ヒープ・GC・設定のイベントだけ) | default | profile | .jfc のパス
#   PERF_JFR_MAXAGE / PERF_JFR_MAXSIZE  24h / 1g   JFR を残す最大の時間 / 大きさ
#   PERF_JFR_HEAP            64m              JFR を CSV にする JVM の最大ヒープ
#   PERF_JVM_CONTAINERS      (自動)           ③ タスク内で JVM が動くコンテナの数 (自動判定を上書き)
#   PERF_WAIT_TIMEOUT        900              JBoss の JVM / 管理インタフェースを待つ秒数
#
# 【注意】
#   - 収集用に jboss-cli (常駐 1 つ・最大ヒープ 64MB)、jstat (常駐 1 つ・32MB)、JFR の CSV 化
#     (常駐 1 つ・64MB) の JVM が増え、jcmd は PERF_JCMD_INTERVAL ごとに短時間 JVM を起動する。
#     RSS で合計 250MB 前後を見込み、タスクのメモリに余裕を持たせること。JFR (heap) は 1% 未満。
#   - jstat / jcmd は /tmp (hsperfdata・アタッチ用ソケット) が書き込めないと JVM に
#     接続できない。readonlyRootFilesystem=true では /tmp にボリュームを当てること
#     (フロント / バックで別のボリュームにする。共有すると PID が重なり別の JVM を読む)。
#   - 本ファイルは /bin/sh (POSIX) で動く。エントリポイント (set -eu) から読み込まれる
#     ため、トップレベルでは関数と既定値の定義しか行わない。
# =============================================================================

PERF_METRICS_VERSION="3.1.0-lite"

# --- 既定値 (エントリポイントから読み込まれても安全な代入だけ) ------------------
: "${PERF_METRICS_ENABLED:=false}"
: "${PERF_INTERVAL:=10}"
: "${PERF_CLI_INTERVAL:=${PERF_INTERVAL}}"
: "${PERF_JSTAT_INTERVAL:=${PERF_INTERVAL}}"
: "${PERF_JCMD_INTERVAL:=60}"
: "${PERF_JFR_INTERVAL:=${PERF_INTERVAL}}"
: "${PERF_CPU_INTERVAL:=${PERF_PROC_INTERVAL:-${PERF_INTERVAL}}}"
: "${PERF_COLLECTORS:=cli jstat jcmd jfr cpu}"
: "${PERF_OUTPUT_DIR:=}"
: "${PERF_WORK_DIR:=}"
: "${PERF_TZ:=}"
: "${PERF_ENABLE_STATISTICS:=true}"
: "${PERF_CLI_ENABLE_DS_STATS:=true}"
: "${PERF_CLI_CONTROLLER:=}"
: "${PERF_CLI_USER:=}"
: "${PERF_CLI_PASSWORD:=}"
: "${PERF_CLI_TIMEOUT:=30}"
: "${PERF_CLI_CONNECT_TIMEOUT:=60}"
: "${PERF_CLI_HEAP:=64m}"
: "${PERF_JFR:=true}"
: "${PERF_JFR_SETTINGS:=heap}"
: "${PERF_JFR_MAXAGE:=24h}"
: "${PERF_JFR_MAXSIZE:=1g}"
: "${PERF_JFR_HEAP:=64m}"
: "${PERF_JVM_CONTAINERS:=}"
: "${PERF_WAIT_TIMEOUT:=900}"
: "${PERF_TOOL_JAVA_OPTS:=-Xms8m -Xmx32m -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -XX:-UsePerfData -Xss512k}"

# エントリポイントが standalone.sh の直後へ足す引数 (DB 接続プールの統計の有効化)。
# 標準の構成は statistics-enabled="${wildfly.datasources.statistics-enabled:${wildfly.statistics-enabled:false}}"
# の式を使っているため、このシステムプロパティで起動時から統計が有効になる
# (式を使っていないデータソースは ① が実行時に有効化する)。取得しない Undertow・
# トランザクション・EJB などの統計は有効にしない (余計な負荷をかけない)。
PERF_SERVER_OPTS=""
if [ "${PERF_ENABLE_STATISTICS}" = "true" ]; then
    PERF_SERVER_OPTS="-Dwildfly.datasources.statistics-enabled=true"
fi
# JBoss の JVM に足すオプション (JFR)。perf_metrics_start が出力先を決めてから設定し、
# エントリポイントが PREPEND_JAVA_OPTS (standalone.sh が JAVA_OPTS の前に足す) へ渡す。
PERF_PREPEND_JAVA_OPTS=""

PM_SELF="${PERF_METRICS_SCRIPT:-/usr/local/bin/perf-metrics.sh}"

# パスワードらしき値を伏せる (起動コマンド・JVM 引数の出力用 sed 式)
PM_MASK_SED='s/\([A-Za-z0-9_.-]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][A-Za-z0-9_.-]*[=:]\)[^ ,]*/\1********/g'
# タブ (「キー<TAB>値」の受け渡しに使う。ソースにタブ文字を直接書かないため)
PM_TAB="$(printf '\t')"
# cpu_env.csv の見出し (③。cpu と cli の 2 つの収集が書く)
PM_CPU_ENV_H="timestamp,epoch,pid,category,key,value,note"

# =============================================================================
# 共通ヘルパー
# =============================================================================
pm_say() {
    printf '[perf-metrics] %s\n' "$*"
}

# ログ: collector.log へ。WARN / ERROR / RESULT は標準エラー (CloudWatch Logs) にも出す。
pm_log() {
    _pm_ll="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [perf-metrics] [${PM_NAME:-main}] $1 $2"
    if [ -n "${PM_LOG_FILE:-}" ]; then
        printf '%s\n' "${_pm_ll}" >> "${PM_LOG_FILE}" 2>/dev/null
    fi
    case "$1" in
        WARN|ERROR|RESULT) printf '%s\n' "${_pm_ll}" >&2 ;;
    esac
    return 0
}

# 同じ警告を何度も出さない (キーごとに 1 回)
pm_warn_once() {  # key message
    case " ${PM_WARNED:-} " in
        *" $1 "*) return 0 ;;
    esac
    PM_WARNED="${PM_WARNED:-} $1"
    pm_log WARN "$2"
}

pm_is_uint() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# 正の整数でなければ既定値に戻す
pm_uint_or() {  # value default
    if pm_is_uint "$1" && [ "$1" -gt 0 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# ディレクトリへ実際に書き込めるか (EROFS / EACCES の両方を実書き込みで判定)
pm_is_writable() {
    [ -d "$1" ] || return 1
    _pm_probe="$1/.perf-metrics-writetest.$$"
    if ( : > "${_pm_probe}" ) 2>/dev/null; then
        rm -f "${_pm_probe}" 2>/dev/null
        return 0
    fi
    return 1
}

# 現在時刻: PM_TS (YYYY-MM-DD HH:MM:SS) と PM_EPOCH (UNIX 秒)
pm_now() {
    _pm_n="$(date '+%Y-%m-%d %H:%M:%S|%s')"
    PM_TS="${_pm_n%|*}"
    PM_EPOCH="${_pm_n#*|}"
}

pm_ms() {
    _pm_v="$(date +%s%N 2>/dev/null)"
    case "${_pm_v}" in
        *N*|"") echo $(( $(date +%s) * 1000 )) ;;
        *) echo $(( _pm_v / 1000000 )) ;;
    esac
}

# 次の「間隔の倍数の時刻」まで待つ (各収集の時刻をそろえる)
pm_sleep_tick() {  # interval
    _pm_s="$(date +%s)"
    sleep $(( $1 - _pm_s % $1 ))
}

# CSV ファイルが無い (または空) なら見出し行を書く
pm_csv_init() {  # file header
    if [ ! -s "$1" ]; then
        printf '%s\n' "$2" >> "$1"
    fi
}

# 複数の収集が書くファイル (cpu_env.csv) へ、ロックを取ってまとめて追記する。
# EFS (NFS) は追記の原子性を保証しないため、行が混ざらないようにする。空なら見出しも書く。
pm_append_locked() {  # target source [header]
    _pm_lk="${PM_W}/.lock.${1##*/}"
    _pm_n=0
    until mkdir "${_pm_lk}" 2>/dev/null; do
        _pm_n=$((_pm_n + 1))
        # 書き込み中に止まったプロセスのロックは 10 秒で外す
        if [ "${_pm_n}" -ge 50 ]; then rmdir "${_pm_lk}" 2>/dev/null; _pm_n=0; fi
        sleep 0.2 2>/dev/null || sleep 1
    done
    if [ -n "${3:-}" ] && [ ! -s "$1" ]; then printf '%s\n' "$3" >> "$1" 2>/dev/null; fi
    cat "$2" >> "$1" 2>/dev/null
    rmdir "${_pm_lk}" 2>/dev/null
    return 0
}

pm_meta() {  # category key value
    if [ -n "${PM_OUT:-}" ]; then
        printf '%s,%s,%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ' | sed -e 's/"/""/g' -e 's/^/"/' -e 's/$/"/')" \
            >> "${PM_OUT}/perf_meta.csv" 2>/dev/null
    fi
    return 0
}

# タイムスタンプのタイムゾーン。tzdata が無いイメージでも Asia/Tokyo は JST-9 で代替する。
pm_setup_tz() {
    case "${PERF_TZ}" in
        "") ;;
        UTC|utc) TZ=UTC0; export TZ ;;
        JST|jst|Asia/Tokyo)
            if [ -e /usr/share/zoneinfo/Asia/Tokyo ]; then TZ=Asia/Tokyo; else TZ=JST-9; fi
            export TZ ;;
        *) TZ="${PERF_TZ}"; export TZ ;;
    esac
}

# JBoss EAP サーバー JVM の PID (java で、jboss-modules.jar と org.jboss.as.standalone を含む)
pm_find_jboss_pid() {
    for _pm_d in /proc/[0-9]*; do
        [ -r "${_pm_d}/cmdline" ] || continue
        _pm_c="$(tr '\0' ' ' 2>/dev/null < "${_pm_d}/cmdline")" || continue
        case "${_pm_c}" in
            *org.jboss.as.cli*) continue ;;
            *jboss-modules.jar*org.jboss.as.standalone*) ;;
            *) continue ;;
        esac
        _pm_a0="${_pm_c%% *}"
        case "${_pm_a0##*/}" in
            java|java.*) printf '%s\n' "${_pm_d#/proc/}"; return 0 ;;
        esac
    done
    return 1
}

# JBoss の JVM が現れるまで待つ (PERF_WAIT_TIMEOUT 秒)。PM_JPID に入れる。
pm_wait_jboss() {
    _pm_dl=$(( $(date +%s) + PERF_WAIT_TIMEOUT ))
    until PM_JPID="$(pm_find_jboss_pid)"; do
        if [ "$(date +%s)" -ge "${_pm_dl}" ]; then
            pm_log WARN "JBoss EAP の JVM が ${PERF_WAIT_TIMEOUT} 秒たっても見つかりません。この収集 (${PM_NAME}) を終了します"
            return 1
        fi
        sleep 2
    done
}

pm_jboss_alive() {
    [ -n "${PM_JPID:-}" ] && [ -r "/proc/${PM_JPID}/cmdline" ] && \
        tr '\0' ' ' 2>/dev/null < "/proc/${PM_JPID}/cmdline" | grep -q 'org.jboss.as.standalone'
}

# JBoss の JVM が使っている java の実体 (収集用の JVM も同じ JDK を使う)
pm_java_of_jboss() {
    _pm_j=""
    if [ -n "${PM_JPID:-}" ]; then
        _pm_j="$(readlink "/proc/${PM_JPID}/exe" 2>/dev/null)"
    fi
    if [ -z "${_pm_j}" ] || [ ! -x "${_pm_j}" ]; then
        if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
            _pm_j="${JAVA_HOME}/bin/java"
        else
            _pm_j="$(command -v java 2>/dev/null)"
        fi
    fi
    [ -n "${_pm_j}" ] || return 1
    printf '%s\n' "${_pm_j}"
}

# standalone.sh と同じ順 (JAVA → JAVA_HOME/bin/java → PATH の java) で JBoss を起動する java を決め、
# その JDK の release ファイルから主版数 (21 など) を読む (JVM は起動しない)。分からなければ 1 を返す。
pm_java_major() {
    _pm_jx="${JAVA:-}"
    [ -z "${_pm_jx}" ] && [ -n "${JAVA_HOME:-}" ] && _pm_jx="${JAVA_HOME}/bin/java"
    [ -z "${_pm_jx}" ] && _pm_jx="java"
    case "${_pm_jx}" in */*) ;; *) _pm_jx="$(command -v "${_pm_jx}" 2>/dev/null)" ;; esac
    [ -n "${_pm_jx}" ] || return 1
    _pm_jr="$(readlink -f "${_pm_jx}" 2>/dev/null || printf '%s' "${_pm_jx}")"
    _pm_jr="${_pm_jr%/bin/java}"
    _pm_jv="$(sed -n 's/^JAVA_VERSION="\([0-9][0-9]*\).*/\1/p' "${_pm_jr}/release" 2>/dev/null | head -n 1)"
    [ "${_pm_jv}" = 1 ] && _pm_jv="$(sed -n 's/^JAVA_VERSION="1\.\([0-9][0-9]*\).*/\1/p' "${_pm_jr}/release" 2>/dev/null | head -n 1)"
    pm_is_uint "${_pm_jv}" || return 1
    printf '%s' "${_pm_jv}"
}

# jstat / jcmd の起動方法を決める。PM_TOOL_BIN (実行ファイル) か PM_TOOL_MAIN (java -m の主クラス)。
#   1) JBoss と同じ JDK の bin  2) PATH  3) java -m jdk.jcmd/<主クラス>
#   (Red Hat の OpenJDK 21 runtime イメージは jcmd はあるが jstat は無い。jdk.jcmd
#    モジュールは入っているので java -m で jstat を起動できる)
pm_resolve_tool() {  # jstat | jcmd
    PM_TOOL_BIN=""; PM_TOOL_MAIN=""; PM_TOOL_NAME="$1"
    PM_TOOL_JAVA="$(pm_java_of_jboss)" || PM_TOOL_JAVA=""
    if [ -n "${PM_TOOL_JAVA}" ]; then
        _pm_jb="$(readlink -f "${PM_TOOL_JAVA}" 2>/dev/null || printf '%s' "${PM_TOOL_JAVA}")"
        if [ -x "${_pm_jb%/java}/$1" ]; then PM_TOOL_BIN="${_pm_jb%/java}/$1"; return 0; fi
    fi
    if command -v "$1" >/dev/null 2>&1; then PM_TOOL_BIN="$(command -v "$1")"; return 0; fi
    if [ -n "${PM_TOOL_JAVA}" ] && \
       env -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS -u JDK_JAVA_OPTIONS "${PM_TOOL_JAVA}" -XX:-UsePerfData --list-modules 2>/dev/null \
       | grep -q '^jdk\.jcmd@'; then
        case "$1" in
            jstat) PM_TOOL_MAIN="sun.tools.jstat.Jstat" ;;
            jcmd)  PM_TOOL_MAIN="sun.tools.jcmd.JCmd" ;;
        esac
        [ -n "${PM_TOOL_MAIN}" ] && return 0
    fi
    return 1
}

pm_tool_desc() {
    if [ -n "${PM_TOOL_BIN}" ]; then printf '%s' "${PM_TOOL_BIN}"; else printf '%s -m jdk.jcmd/%s' "${PM_TOOL_JAVA}" "${PM_TOOL_MAIN}"; fi
}

# 解決したツールを、アプリ用の JVM オプション (javaagent 等) を外して起動する。
# PM_TOOL_SYSPROPS に -D... を入れると、ツールの JVM のシステムプロパティとして渡す。
pm_tool_exec() {  # args...
    (
        unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS JAVA_OPTS
        LC_ALL=C; export LC_ALL
        # -Dperf.metrics.collector は目印 (手動実行の jstat / jcmd と区別するため)
        _pm_mark="-Dperf.metrics.collector=${PM_TOOL_NAME:-tool}"
        if [ -n "${PM_TOOL_BIN}" ]; then
            _pm_jo="-J${_pm_mark}"
            for _pm_o in ${PERF_TOOL_JAVA_OPTS} ${PM_TOOL_SYSPROPS:-}; do _pm_jo="${_pm_jo} -J${_pm_o}"; done
            # shellcheck disable=SC2086
            exec "${PM_TOOL_BIN}" ${_pm_jo} "$@"
        fi
        # shellcheck disable=SC2086
        exec "${PM_TOOL_JAVA}" "${_pm_mark}" ${PERF_TOOL_JAVA_OPTS} ${PM_TOOL_SYSPROPS:-} -m "jdk.jcmd/${PM_TOOL_MAIN}" "$@"
    )
}

# hsperfdata (jstat が読む性能カウンタ) が /tmp にあるか
pm_hsperf_exists() {  # pid
    for _pm_h in /tmp/hsperfdata_*/"$1"; do
        [ -e "${_pm_h}" ] && return 0
    done
    return 1
}

# 指定 PID とその子孫を止める
pm_kill_tree() {  # pid
    _pm_list=" $1 "
    _pm_pass=0
    while [ "${_pm_pass}" -lt 3 ]; do
        for _pm_d in /proc/[0-9]*; do
            _pm_st="$(cat "${_pm_d}/stat" 2>/dev/null)" || continue
            _pm_st="${_pm_st##*) }"
            # shellcheck disable=SC2086
            set -- ${_pm_st}
            case "${_pm_list}" in
                *" $2 "*)
                    case "${_pm_list}" in *" ${_pm_d#/proc/} "*) ;; *) _pm_list="${_pm_list}${_pm_d#/proc/} " ;; esac
                    ;;
            esac
        done
        _pm_pass=$((_pm_pass + 1))
    done
    # shellcheck disable=SC2086
    kill -TERM ${_pm_list} 2>/dev/null
    sleep 1
    # shellcheck disable=SC2086
    kill -KILL ${_pm_list} 2>/dev/null
    return 0
}

# 作業ディレクトリの候補 (タスクローカルで書ける所)。同じタスクのフロント / バックが
# /tmp を共有していてもぶつからないよう、コンポーネント名を名前に入れる。
pm_work_candidates() {
    _pm_wsfx="$(printf '%s' "${Component_name:-}" | tr -c 'A-Za-z0-9._-' '_')"
    [ -n "${PERF_WORK_DIR}" ] && printf '%s\n' "${PERF_WORK_DIR}"
    printf '%s\n' "/tmp/perf-metrics${_pm_wsfx:+-${_pm_wsfx}}"
    printf '%s\n' "${JBOSS_HOME:-/opt/jboss-eap}/standalone/tmp/perf-metrics"
    [ -n "${PM_OUT:-}" ] && printf '%s\n' "${PM_OUT}/.work"
    return 0
}

# 状態ファイル (status / stop / pack が使う) を探して読み込む
pm_load_state() {
    for _pm_w in $(pm_work_candidates); do
        if [ -r "${_pm_w}/perf-metrics.state" ]; then
            # shellcheck disable=SC1090
            . "${_pm_w}/perf-metrics.state"
            return 0
        fi
    done
    return 1
}

pm_has_collector() {
    case " ${PERF_COLLECTORS} " in *" $1 "*) return 0 ;; esac
    return 1
}

# 収集プロセスが動いているか (PID ファイル)
pm_collector_running() {  # name
    [ -n "${PM_W:-}" ] && [ -r "${PM_W}/$1.pid" ] && kill -0 "$(cat "${PM_W}/$1.pid" 2>/dev/null)" 2>/dev/null
}

# =============================================================================
# 起動 (efs-entrypoint.sh から呼ばれる)
# =============================================================================
# 出力先を決める。成功したら PM_OUT (書き込みに使う実体パス) と、それが起動時点の
# mid/current/perf と同じなら PM_OUT_CURRENT (mid/current 経由のパス) に入れる。
pm_resolve_output_dir() {
    PM_OUT=""
    PM_OUT_NOTE=""
    PM_OUT_CURRENT=""
    if [ -n "${PERF_OUTPUT_DIR}" ]; then
        PM_OUT="${PERF_OUTPUT_DIR}"
        PM_OUT_NOTE="PERF_OUTPUT_DIR で指定"
    elif [ -n "${JBOSS_LOG_DIR:-}" ] && [ -d "${JBOSS_LOG_DIR}" ]; then
        # エントリポイントが決めた、このタスク専用の実体ディレクトリ (mid/<LOG_ID>)
        PM_OUT="${JBOSS_LOG_DIR}/perf"
        PM_OUT_NOTE="JBoss のログと同じタスク専用ディレクトリ"
    elif [ -n "${EFS_LOG_DIR:-}" ] && [ -d "${EFS_LOG_DIR}/mid/current" ]; then
        # 起動時点の current を実体パスへ解決する (以後 current が張り替わっても影響しない)
        _pm_cur="$(cd "${EFS_LOG_DIR}/mid/current" 2>/dev/null && pwd -P)"
        [ -n "${_pm_cur}" ] && PM_OUT="${_pm_cur}/perf"
        PM_OUT_NOTE="起動時点の mid/current を実体パスへ解決"
    elif [ -d "${JBOSS_HOME:-/opt/jboss-eap}/standalone/log" ]; then
        _pm_cur="$(cd "${JBOSS_HOME:-/opt/jboss-eap}/standalone/log" 2>/dev/null && pwd -P)"
        [ -n "${_pm_cur}" ] && PM_OUT="${_pm_cur}/perf"
        PM_OUT_NOTE="standalone/log の解決先"
    fi
    [ -n "${PM_OUT}" ] || return 1
    mkdir -p "${PM_OUT}" 2>/dev/null
    pm_is_writable "${PM_OUT}" || return 1
    # 書き込み先が mid/current/perf (このタスク) から見えるか
    if [ -n "${EFS_LOG_DIR:-}" ]; then
        _pm_cur="$(cd "${EFS_LOG_DIR}/mid/current" 2>/dev/null && pwd -P)"
        _pm_own="$(cd "${PM_OUT}/.." 2>/dev/null && pwd -P)"
        if [ -n "${_pm_cur}" ] && [ "${_pm_cur}" = "${_pm_own}" ]; then
            PM_OUT_CURRENT="${EFS_LOG_DIR}/mid/current/perf"
        fi
    fi
    return 0
}

pm_resolve_work_dir() {
    PM_W=""
    for _pm_w in $(pm_work_candidates); do
        mkdir -p "${_pm_w}" 2>/dev/null || continue
        if pm_is_writable "${_pm_w}"; then PM_W="${_pm_w}"; return 0; fi
    done
    return 1
}

# ECS タスクメタデータ (v4) を取る。PM_ECS_TASK / PM_ECS_CONT に「パス<TAB>値」の行で入れる。
pm_ecs_fetch() {
    PM_ECS_TASK=""; PM_ECS_CONT=""
    [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    _pm_j="$(curl -fsS --max-time 3 "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null)" || return 1
    PM_ECS_TASK="$(printf '%s\n' "${_pm_j}" | awk "${PM_JSON_AWK}" 2>/dev/null)"
    _pm_j="$(curl -fsS --max-time 3 "${ECS_CONTAINER_METADATA_URI_V4}" 2>/dev/null)" || _pm_j=""
    PM_ECS_CONT="$(printf '%s\n' "${_pm_j}" | awk "${PM_JSON_AWK}" 2>/dev/null)"
    [ -n "${PM_ECS_TASK}" ]
}

pm_jget() {  # flattened-json path -> value
    printf '%s\n' "$1" | awk -F '\t' -v k="$2" '$1 == k { print $2; exit }'
}

# ECS タスクメタデータの主な項目を perf_meta.csv へ
pm_meta_ecs() {
    pm_ecs_fetch || return 0
    for _pm_k in Cluster ServiceName TaskARN Family Revision AvailabilityZone LaunchType Limits.CPU Limits.Memory; do
        _pm_v="$(pm_jget "${PM_ECS_TASK}" "${_pm_k}")"
        [ -n "${_pm_v}" ] && pm_meta ecs "${_pm_k}" "${_pm_v}"
    done
    for _pm_k in Name Limits.CPU Limits.Memory Image; do
        _pm_v="$(pm_jget "${PM_ECS_CONT}" "${_pm_k}")"
        [ -n "${_pm_v}" ] && pm_meta ecs "container.${_pm_k}" "${_pm_v}"
    done
    return 0
}

pm_banner_line() {
    pm_say "$1"
    [ -n "${PM_LOG_FILE:-}" ] && printf '%s [perf-metrics] [start] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${PM_LOG_FILE}" 2>/dev/null
    return 0
}

# JFR の設定 (JBoss の起動時に渡す -XX:StartFlightRecording / 起動後に渡す jcmd JFR.start の
# どちらでも使える「キー=値」の並び)。PM_JFR_SET で記録するイベントを選ぶ。
#   heap (既定) : settings=none に「+イベント#設定」を足して、② のヒープ・GC と、② ③ で使う
#                 GC・ヒープ・CPU の設定のイベントだけを記録する (JDK 17 以降の書き方。この JDK に
#                 無いイベント名は JFR が無視する)。定期イベントは PERF_JFR_INTERVAL 秒間隔。
#                 Container Insights と重なるイベント (CPU 使用率・RSS・ネットワーク・
#                 コンテナの CPU / メモリ / I/O の使用量) は記録しない
#   default / profile / .jfc : その設定に、定期イベントの間隔と、Container Insights と重なる
#                 イベントの無効化を足す (ヒープ・GC 以外のイベントも記録される)
# 統計を取る定期イベント (heap と default などで共通)
PM_JFR_PERIODIC="jdk.GCHeapMemoryUsage jdk.GCHeapMemoryPoolUsage jdk.ThreadAllocationStatistics"
# GC 1 回ごとのイベント (しきい値 0 = すべて)
PM_JFR_GC_TIMED="jdk.GarbageCollection jdk.YoungGarbageCollection jdk.OldGarbageCollection jdk.G1GarbageCollection jdk.GCPhasePause jdk.SystemGC"
PM_JFR_GC_EVENTS="jdk.GCHeapSummary jdk.G1HeapSummary jdk.MetaspaceSummary jdk.GCCPUTime jdk.EvacuationFailed jdk.PromotionFailed jdk.MetaspaceGCThreshold jdk.MetaspaceOOM jdk.MetaspaceAllocationFailure"
# 設定 (チャンクの最初に 1 回)
PM_JFR_CONFIG="jdk.GCConfiguration jdk.GCHeapConfiguration jdk.YoungGenerationConfiguration jdk.GCSurvivorConfiguration jdk.GCTLABConfiguration jdk.JVMInformation jdk.CPUInformation jdk.ContainerConfiguration jdk.CompilerConfiguration jdk.OSInformation jdk.VirtualizationInformation"
# Container Insights (拡張) と重なるため default / profile でも記録しないイベント
PM_JFR_CI_DUP="jdk.CPULoad jdk.ResidentSetSize jdk.NetworkUtilization jdk.ContainerCPUUsage jdk.ContainerMemoryUsage jdk.ContainerIOUsage jdk.PhysicalMemory"

pm_jfr_items() {  # separator
    _pm_s="$1"; _pm_p="${PERF_JFR_INTERVAL}s"; _pm_ev=""
    if [ "${PM_JFR_SET:-heap}" = heap ]; then
        _pm_set=none
        for _pm_e in ${PM_JFR_PERIODIC}; do
            _pm_ev="${_pm_ev}${_pm_s}+${_pm_e}#enabled=true${_pm_s}+${_pm_e}#period=${_pm_p}"
        done
        for _pm_e in ${PM_JFR_GC_TIMED}; do
            _pm_ev="${_pm_ev}${_pm_s}+${_pm_e}#enabled=true${_pm_s}+${_pm_e}#threshold=0ms"
        done
        for _pm_e in ${PM_JFR_GC_EVENTS}; do
            _pm_ev="${_pm_ev}${_pm_s}+${_pm_e}#enabled=true"
        done
        for _pm_e in ${PM_JFR_CONFIG}; do
            _pm_ev="${_pm_ev}${_pm_s}+${_pm_e}#enabled=true${_pm_s}+${_pm_e}#period=beginChunk"
        done
    else
        _pm_set="${PM_JFR_SET}"
        for _pm_e in ${PM_JFR_PERIODIC}; do
            _pm_ev="${_pm_ev}${_pm_s}${_pm_e}#period=${_pm_p}"
        done
        for _pm_e in ${PM_JFR_CI_DUP}; do
            _pm_ev="${_pm_ev}${_pm_s}${_pm_e}#enabled=false"
        done
    fi
    printf 'name=perf-metrics%ssettings=%s%s%sdisk=true%smaxage=%s%smaxsize=%s%sfilename=%s/perf_%%p_%%t.jfr%sdumponexit=true' \
        "${_pm_s}" "${_pm_set}" "${_pm_ev}" "${_pm_s}" "${_pm_s}" "${PERF_JFR_MAXAGE}" "${_pm_s}" "${PERF_JFR_MAXSIZE}" "${_pm_s}" "${PM_JFR_DIR}" "${_pm_s}"
}

pm_jvm_opts_have() {  # pattern -> 0 when JAVA_OPTS / JAVA_TOOL_OPTIONS / JDK_JAVA_OPTIONS already contain it
    case " ${JAVA_OPTS:-} ${JAVA_TOOL_OPTIONS:-} ${JDK_JAVA_OPTIONS:-} ${PREPEND_JAVA_OPTS:-} " in *"$1"*) return 0 ;; esac
    return 1
}

perf_metrics_start() {
    # エントリポイントの set -e / -u をこの関数の中だけ外す (収集側の都合で起動を止めない)
    _pm_saved_flags="$-"
    set +eu
    PM_NAME=start
    pm_start_body "$@"
    _pm_rc=$?
    case "${_pm_saved_flags}" in *e*) set -e ;; esac
    case "${_pm_saved_flags}" in *u*) set -u ;; esac
    return "${_pm_rc}"
}

pm_start_body() {
    pm_setup_tz
    PERF_INTERVAL="$(pm_uint_or "${PERF_INTERVAL}" 10)"
    PERF_CLI_INTERVAL="$(pm_uint_or "${PERF_CLI_INTERVAL}" "${PERF_INTERVAL}")"
    PERF_JSTAT_INTERVAL="$(pm_uint_or "${PERF_JSTAT_INTERVAL}" "${PERF_INTERVAL}")"
    PERF_JCMD_INTERVAL="$(pm_uint_or "${PERF_JCMD_INTERVAL}" 60)"
    PERF_JFR_INTERVAL="$(pm_uint_or "${PERF_JFR_INTERVAL}" "${PERF_INTERVAL}")"
    PERF_CPU_INTERVAL="$(pm_uint_or "${PERF_CPU_INTERVAL}" "${PERF_INTERVAL}")"
    PERF_CLI_TIMEOUT="$(pm_uint_or "${PERF_CLI_TIMEOUT}" 30)"
    PERF_CLI_CONNECT_TIMEOUT="$(pm_uint_or "${PERF_CLI_CONNECT_TIMEOUT}" 60)"
    PERF_WAIT_TIMEOUT="$(pm_uint_or "${PERF_WAIT_TIMEOUT}" 900)"

    if ! pm_resolve_output_dir; then
        pm_say "WARN: 出力先 '${PM_OUT:-(決められません)}' に書き込めないため、性能試験用メトリクス収集を行いません (JBoss は起動します)" >&2
        pm_say "WARN: JBOSS_LOG_DIR='${JBOSS_LOG_DIR:-}' EFS_LOG_DIR='${EFS_LOG_DIR:-}' PERF_OUTPUT_DIR='${PERF_OUTPUT_DIR}'" >&2
        return 1
    fi
    if ! pm_resolve_work_dir; then
        pm_say "WARN: 作業ディレクトリ (/tmp・standalone/tmp・出力先/.work) に書き込めないため、収集を行いません" >&2
        return 1
    fi
    rm -f "${PM_W}"/cli.in "${PM_W}"/cli.out "${PM_W}"/*.pid "${PM_W}"/*.prev "${PM_W}/perf-metrics.state" 2>/dev/null
    rm -rf "${PM_W}"/.lock.* 2>/dev/null
    PM_LOG_FILE="${PM_OUT}/collector.log"
    PM_SELF="${PERF_METRICS_SCRIPT:-${PM_SELF}}"

    # 収集の名前 (古い名前の proc は cpu、top / ps は Lite では取得しない)
    _pm_cols=""
    for _pm_c in ${PERF_COLLECTORS}; do
        case "${_pm_c}" in
            cli|jstat|jcmd|jfr|cpu) ;;
            proc) _pm_c=cpu ;;
            none) continue ;;
            top|ps) pm_say "WARN: PERF_COLLECTORS の ${_pm_c} は Lite 版では取得しません (無視します)" >&2; continue ;;
            *) pm_say "WARN: PERF_COLLECTORS の不明な値を無視します: ${_pm_c}" >&2; continue ;;
        esac
        case " ${_pm_cols} " in *" ${_pm_c} "*) ;; *) _pm_cols="${_pm_cols}${_pm_cols:+ }${_pm_c}" ;; esac
    done
    PERF_COLLECTORS="${_pm_cols:-none}"

    # ---- JBoss に足す JVM オプション (JFR) ----
    # CMD が standalone.sh (CMD=eap を含む) のときは PREPEND_JAVA_OPTS で起動時から記録する。
    # それ以外の CMD では JVM の起動後に jcmd JFR.start で始める。
    PM_JFR_DIR="${PM_OUT}/jfr"
    PM_JFR_MODE=off
    PM_JFR_SET=heap
    PM_JFR_NOTE="無効 (PERF_JFR=${PERF_JFR})"
    _pm_is_ss=0
    case "${1:-}" in */standalone.sh|standalone.sh) _pm_is_ss=1 ;; esac
    PERF_PREPEND_JAVA_OPTS=""
    if [ "${PERF_JFR}" = "true" ]; then
        case "${PERF_JFR_SETTINGS}" in
            heap|"") PM_JFR_SET=heap ;;
            default|profile) PM_JFR_SET="${PERF_JFR_SETTINGS}" ;;
            *)
                # 無い .jfc を渡すと JVM が起動しないため、読めるときだけ使う
                if [ -r "${PERF_JFR_SETTINGS}" ]; then
                    PM_JFR_SET="${PERF_JFR_SETTINGS}"
                else
                    pm_say "WARN: PERF_JFR_SETTINGS=${PERF_JFR_SETTINGS} が読めないため heap (ヒープ・GC のイベントだけ) で記録します" >&2
                fi ;;
        esac
        _pm_jmaj="$(pm_java_major)" || _pm_jmaj=""
        mkdir -p "${PM_JFR_DIR}/repo" "${PM_JFR_DIR}/dump" 2>/dev/null
        case "${PM_JFR_DIR}${PM_JFR_SET}${PERF_JFR_MAXAGE}${PERF_JFR_MAXSIZE}" in
            *[!A-Za-z0-9/._-]*)
                PM_JFR_MODE=off
                PM_JFR_NOTE="無効 (出力先・設定に JFR の引数で使えない文字 (空白・カンマ等) があります)" ;;
            *)
                if [ -n "${_pm_jmaj}" ] && [ "${_pm_jmaj}" -lt 17 ]; then
                    PM_JFR_MODE=off
                    PM_JFR_NOTE="無効 (Java ${_pm_jmaj}。イベントの設定を起動引数で指定するには JDK 17 以降が必要)"
                elif pm_jvm_opts_have StartFlightRecording; then
                    PM_JFR_MODE=user
                    PM_JFR_NOTE="JAVA_OPTS 等に -XX:StartFlightRecording が既にあるため追加しません (CSV は jfr-csv で変換)"
                elif [ "${_pm_is_ss}" = 1 ]; then
                    PM_JFR_MODE=startup
                    PERF_PREPEND_JAVA_OPTS="-XX:StartFlightRecording:$(pm_jfr_items ,) -XX:FlightRecorderOptions:repository=${PM_JFR_DIR}/repo,preserve-repository=true"
                    PM_JFR_NOTE="JBoss の起動時から記録 (settings=${PM_JFR_SET}、定期イベント ${PERF_JFR_INTERVAL} 秒間隔、最大 ${PERF_JFR_MAXAGE} / ${PERF_JFR_MAXSIZE})"
                else
                    PM_JFR_MODE=jcmd
                    PM_JFR_NOTE="JVM の起動後に jcmd JFR.start で記録を始めます (settings=${PM_JFR_SET}、定期イベント ${PERF_JFR_INTERVAL} 秒間隔)"
                fi ;;
        esac
    fi
    if [ -n "${PERF_PREPEND_JAVA_OPTS}" ] && [ "${PRESERVE_JAVA_OPTS:-}" = "true" ]; then
        pm_say "WARN: PRESERVE_JAVA_OPTS=true のため standalone.sh は PREPEND_JAVA_OPTS を使いません。JFR は JVM の起動後に jcmd で始めます" >&2
        [ "${PM_JFR_MODE}" = startup ] && PM_JFR_MODE=jcmd
        PERF_PREPEND_JAVA_OPTS=""
    fi

    # 収集プロセスへ渡す値
    export PM_OUT PM_W PM_LOG_FILE PM_SELF PM_JFR_DIR PM_JFR_MODE PM_JFR_SET TZ \
        PERF_INTERVAL PERF_CLI_INTERVAL PERF_JSTAT_INTERVAL PERF_JCMD_INTERVAL PERF_JFR_INTERVAL PERF_CPU_INTERVAL \
        PERF_COLLECTORS PERF_TZ PERF_CLI_ENABLE_DS_STATS PERF_CLI_CONTROLLER PERF_CLI_USER PERF_CLI_PASSWORD \
        PERF_CLI_TIMEOUT PERF_CLI_CONNECT_TIMEOUT PERF_CLI_HEAP PERF_JFR PERF_JFR_SETTINGS PERF_JFR_MAXAGE \
        PERF_JFR_MAXSIZE PERF_JFR_HEAP PERF_JVM_CONTAINERS PERF_WAIT_TIMEOUT PERF_TOOL_JAVA_OPTS PERF_ENABLE_STATISTICS

    # 収集条件 (レポートの「収集情報」に出る)
    pm_now
    pm_meta perf version "${PERF_METRICS_VERSION}"
    pm_meta perf start_time "${PM_TS}"
    pm_meta perf start_epoch "${PM_EPOCH}"
    pm_meta perf utc_offset "$(date +%z)"
    pm_meta perf output_dir "${PM_OUT}"
    pm_meta perf output_dir_current "${PM_OUT_CURRENT}"
    pm_meta perf work_dir "${PM_W}"
    pm_meta perf collectors "${PERF_COLLECTORS}"
    pm_meta perf cli_interval "${PERF_CLI_INTERVAL}"
    pm_meta perf jstat_interval "${PERF_JSTAT_INTERVAL}"
    pm_meta perf jcmd_interval "${PERF_JCMD_INTERVAL}"
    pm_meta perf jfr_interval "${PERF_JFR_INTERVAL}"
    pm_meta perf cpu_interval "${PERF_CPU_INTERVAL}"
    pm_meta perf jfr_mode "${PM_JFR_MODE}"
    pm_meta perf jfr_settings "${PM_JFR_SET}"
    pm_meta perf jfr_note "${PM_JFR_NOTE}"
    pm_meta perf statistics_opts "${PERF_SERVER_OPTS}"
    pm_meta perf prepend_java_opts "${PERF_PREPEND_JAVA_OPTS}"
    pm_meta container hostname "$(cat /proc/sys/kernel/hostname 2>/dev/null)"
    pm_meta container service_name "${Service_Name:-}"
    pm_meta container component_name "${Component_name:-}"
    pm_meta container component_role "${COMPONENT_ROLE:-}"
    pm_meta container log_id "$(basename "$(dirname "${PM_OUT}")")"
    pm_meta container jboss_home "${JBOSS_HOME:-}"
    pm_meta container cpus_online "$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
    pm_meta container mem_total_kb "$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)"
    pm_meta container os "$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release 2>/dev/null)"
    pm_meta container command "$(printf '%s ' "$@" | sed "${PM_MASK_SED}")"
    pm_meta_ecs

    {
        echo "PM_OUT='${PM_OUT}'"
        echo "PM_W='${PM_W}'"
        echo "PM_LOG_FILE='${PM_LOG_FILE}'"
        echo "PM_JFR_DIR='${PM_JFR_DIR}'"
        echo "PM_JFR_MODE='${PM_JFR_MODE}'"
        echo "PM_START_TS='${PM_TS}'"
    } > "${PM_W}/perf-metrics.state" 2>/dev/null

    # JFR の CSV 変換プログラムを出力先にも置く (PC に持ち帰った .jfr を JDK 17 以降で変換できる)
    if [ "${PERF_JFR}" = "true" ] && [ -d "${PM_JFR_DIR}" ]; then
        printf '%s\n' "${PM_JFR_JAVA}" > "${PM_JFR_DIR}/PerfJfrCsv.java" 2>/dev/null
    fi

    # 有効であることを起動ログで分かるようにする
    _pm_off() { pm_has_collector "$1" || printf ' (無効)'; }
    _pm_jfrcsv="jfr_heap.csv・jfr_gc.csv"
    case "${PM_JFR_MODE}" in
        startup|jcmd) pm_has_collector jfr || _pm_jfrcsv="試験の後に perf-metrics.sh jfr-csv で CSV 化" ;;
        *) _pm_jfrcsv="" ;;
    esac
    pm_banner_line "======================================================================"
    pm_banner_line " 性能試験用メトリクス収集 (Lite): 有効  (perf-metrics.sh ${PERF_METRICS_VERSION} / PERF_METRICS_ENABLED=true)"
    if [ -n "${PM_OUT_CURRENT}" ]; then
        pm_banner_line " 出力先 : ${PM_OUT_CURRENT}/"
        pm_banner_line "          (実体 ${PM_OUT}。readonlyRootFilesystem=true でも書ける EFS 上。書き込みは実体パスへ直接行う)"
    else
        pm_banner_line " 出力先 : ${PM_OUT}/"
        pm_banner_line "          (${PM_OUT_NOTE})"
    fi
    pm_banner_line " ① DB 接続プール   jboss-cli : ${PERF_CLI_INTERVAL} 秒間隔$(_pm_off cli)  統計 (cli_datasource.csv)・情報 (cli_datasource_info.csv)"
    pm_banner_line " ② ヒープ・GC      jstat     : ${PERF_JSTAT_INTERVAL} 秒間隔$(_pm_off jstat)  ヒープ各領域・GC・原因・セーフポイント (jvm_jstat_gc.csv)"
    pm_banner_line "                   jcmd      : ${PERF_JCMD_INTERVAL} 秒間隔$(_pm_off jcmd)  GC.heap_info (jvm_jcmd_heap.csv)・VM.flags (jvm_info.txt)"
    pm_banner_line "                   JFR       : ${PM_JFR_NOTE}${_pm_jfrcsv:+  (${_pm_jfrcsv})}"
    pm_banner_line " ③ CPU 数          cpu       : JVM 起動後に ActiveProcessorCount の要否を判定 (cpu_env.csv)。CPU の使われ方: ${PERF_CPU_INTERVAL} 秒間隔$(_pm_off cpu) (cpu_sched.csv・cpu_threads.csv)"
    [ -n "${PERF_SERVER_OPTS}" ] && pm_banner_line " 統計の有効化: ${PERF_SERVER_OPTS} を standalone.sh へ追加"
    [ -n "${PERF_PREPEND_JAVA_OPTS}" ] && pm_banner_line " JVM オプション: PREPEND_JAVA_OPTS へ追加 (JAVA_OPTS は変更しません): ${PERF_PREPEND_JAVA_OPTS}"
    pm_banner_line " 作業ディレクトリ: ${PM_W}   状態確認: perf-metrics.sh status (ECS Exec で実行)"
    pm_banner_line " ※ Container Insights (拡張) で見られる CPU・メモリ・ネットワーク・ストレージの使用量は取得しません"
    pm_banner_line " ※ 性能試験用のイメージです。本番は PERF_METRICS_ENABLED=false でビルドしてください"
    pm_banner_line "======================================================================"

    # 前提の確認 (足りないものは警告し、その収集だけ止まる)
    if { pm_has_collector jstat || pm_has_collector jcmd || pm_has_collector cpu; } && ! pm_is_writable /tmp; then
        pm_say "WARN: /tmp に書き込めないため jstat / jcmd は JVM に接続できません (hsperfdata・アタッチ用ソケットを /tmp に作るため)。" >&2
        pm_say "WARN: タスク定義で /tmp に書き込み可能ボリュームを当ててください (① と ③ の /proc の値・JFR は取得できます)" >&2
    fi
    if pm_has_collector cli && [ ! -f "${JBOSS_HOME:-/opt/jboss-eap}/bin/jboss-cli.sh" ]; then
        pm_say "WARN: ${JBOSS_HOME:-/opt/jboss-eap}/bin/jboss-cli.sh がありません。① の取得は行いません" >&2
    fi

    # 収集プロセスを起動 (JBoss の起動とは並行して動き、JVM の出現を待ってから取得する)
    for _pm_c in ${PERF_COLLECTORS}; do
        [ "${_pm_c}" = none ] && continue
        /bin/sh "${PM_SELF}" run "${_pm_c}" < /dev/null > /dev/null &
        echo "$!" > "${PM_W}/${_pm_c}.pid" 2>/dev/null
        pm_log INFO "収集プロセスを起動しました: ${_pm_c} (pid=$!)"
    done
    return 0
}

# =============================================================================
# ① DB 接続プール (jboss-cli)
# =============================================================================
# 取得するのは管理モデルの読み取りだけ。jboss-cli は常駐セッション (FIFO) で 1 つだけ
# 起動し、間隔ごとに JVM を起動し直すことはしない (起動のたびに CPU を 1 秒以上使うため)。
# 各操作は try / catch で囲み、無い属性・リソースがあっても他は取得する。
# データソースの属性は 1 つずつ読む (read-resource はパスワードまで返すため使わない)。

# 統計の行に毎回入れる設定 (使用率の計算などに使う)
PM_DS_KEY_ATTRS="jndi-name min-pool-size initial-pool-size max-pool-size blocking-timeout-wait-millis"
# プールの情報 (cli_datasource_info.csv)。パスワード・ユーザー名・認証の設定・接続プロパティ
# (値にパスワードを含み得る) は読まない
PM_DS_INFO_ATTRS="enabled statistics-enabled jndi-name driver-name min-pool-size initial-pool-size max-pool-size pool-prefill pool-use-strict-min pool-fair flush-strategy blocking-timeout-wait-millis idle-timeout-minutes allocation-retry allocation-retry-wait-millis background-validation background-validation-millis validate-on-match check-valid-connection-sql valid-connection-checker-class-name stale-connection-checker-class-name exception-sorter-class-name use-fast-fail use-try-lock query-timeout set-tx-query-timeout transaction-isolation prepared-statements-cache-size share-prepared-statements track-statements use-ccm mcp capacity-incrementer-class capacity-decrementer-class"
PM_DS_INFO_DS="connection-url jta"
PM_DS_INFO_XA="xa-datasource-class xa-resource-timeout interleaving no-tx-separate-pool same-rm-override wrap-xa-resource pad-xid"
# プールの情報を読み直す間隔 (取得の回数。データソースが増減したときもすぐ読み直す)
PM_DS_INFO_EVERY=30

pm_cli_q() {  # id operation
    printf 'echo PERF_B %s\ntry\n%s\ncatch\necho PERF_F %s\nend-try\n' "$1" "$2" "$1"
}

pm_cli_quote() {
    case "$1" in
        *[!A-Za-z0-9_.-]*) printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" ;;
        *) printf '%s' "$1" ;;
    esac
}

pm_cli_sample_block() {
    for _pm_t in ds xa; do
        if [ "${_pm_t}" = ds ]; then _pm_r=data-source; else _pm_r=xa-data-source; fi
        pm_cli_q "dsp.${_pm_t}" "/subsystem=datasources/${_pm_r}=*/statistics=pool:read-resource(include-runtime=true)"
        pm_cli_q "dsj.${_pm_t}" "/subsystem=datasources/${_pm_r}=*/statistics=jdbc:read-resource(include-runtime=true)"
        for _pm_a in ${PM_DS_KEY_ATTRS}; do
            pm_cli_q "dsa.${_pm_t}.${_pm_a}" "/subsystem=datasources/${_pm_r}=*:read-attribute(name=${_pm_a},resolve-expressions=true)"
        done
    done
}

pm_cli_info_block() {
    for _pm_t in ds xa; do
        if [ "${_pm_t}" = ds ]; then _pm_r=data-source; _pm_x="${PM_DS_INFO_DS}"; else _pm_r=xa-data-source; _pm_x="${PM_DS_INFO_XA}"; fi
        for _pm_a in ${PM_DS_INFO_ATTRS} ${_pm_x}; do
            pm_cli_q "dsi.${_pm_t}.${_pm_a}" "/subsystem=datasources/${_pm_r}=*:read-attribute(name=${_pm_a},resolve-expressions=true)"
        done
    done
}

# JVM ごとに 1 回: サーバーの情報 (perf_meta.csv) と、③ の判断材料にする「JBoss が CPU 数から
# 決めたスレッド数」(IO ワーカー = Undertow の I/O・HTTP 処理スレッド、EE・EJB のスレッドプール)
pm_cli_session_block() {
    _pm_pm="/core-service=platform-mbean"
    pm_cli_q m.product-name ":read-attribute(name=product-name)"
    pm_cli_q m.product-version ":read-attribute(name=product-version)"
    pm_cli_q m.release-version ":read-attribute(name=release-version)"
    pm_cli_q m.server-name ":read-attribute(name=name)"
    pm_cli_q m.launch-type ":read-attribute(name=launch-type)"
    pm_cli_q m.running-mode ":read-attribute(name=running-mode)"
    pm_cli_q m.config-file "/core-service=server-environment:read-attribute(name=config-file)"
    pm_cli_q m.node-name "/core-service=server-environment:read-attribute(name=node-name)"
    pm_cli_q m.vm-name "${_pm_pm}/type=runtime:read-attribute(name=vm-name)"
    pm_cli_q m.vm-vendor "${_pm_pm}/type=runtime:read-attribute(name=vm-vendor)"
    pm_cli_q m.vm-version "${_pm_pm}/type=runtime:read-attribute(name=vm-version)"
    pm_cli_q m.jvm-start-time "${_pm_pm}/type=runtime:read-attribute(name=start-time)"
    pm_cli_q m.available-processors "${_pm_pm}/type=operating-system:read-attribute(name=available-processors)"
    pm_cli_q jbw "/subsystem=io/worker=*:read-resource(include-runtime=true,resolve-expressions=true)"
    pm_cli_q jbe "/subsystem=ee/managed-executor-service=*:read-resource(include-runtime=true,resolve-expressions=true)"
    pm_cli_q jbs "/subsystem=ee/managed-scheduled-executor-service=*:read-resource(include-runtime=true,resolve-expressions=true)"
    pm_cli_q jbj "/subsystem=ejb3/thread-pool=*:read-resource(include-runtime=true,resolve-expressions=true)"
    pm_cli_q jbp "${_pm_pm}/type=operating-system:read-attribute(name=available-processors)"
}

# 解析用 awk: DMR 形式の応答を字句解析し、ワイルドカードの各要素ごとに CSV 行へ。
# 応答は「PERF_B <id>」で区切られ、ワイルドカードの結果は address → result の順に並ぶ。
# 未定義 (undefined) の値は空欄になる (ワイルドカードの read-attribute では要素ごと省かれる)。
#   mode=header  : 見出しだけの CSV を作る
#   (既定)       : cli_datasource.csv に 1 行ずつ。プールの情報 (dsi.*) を読んだ回は、
#                  前回 (infoprev) から変わった項目だけを cli_datasource_info.csv に書き、全体を infonew へ
#   mode=session : サーバーの情報を perf_meta.csv へ、③ の JBoss 側のスレッド数を jbf (cpu_env.csv の形) へ
PM_CLI_AWK='
function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function csvq(s) { if (s ~ /[",\r\n]/) { gsub(/"/, "\"\"", s); return "\"" s "\"" } return s }
function dq(s) { gsub(/"/, "\"\"", s); gsub(/[\r\n]/, " ", s); return s }
function norm(v) {
  v = trim(v)
  if (v == "undefined") return ""
  sub(/^expression /, "", v); sub(/^big (decimal|integer) /, "", v)
  if (v ~ /^-?[0-9]+L$/) v = substr(v, 1, length(v) - 1)
  return v
}
# JDBC の URL の中のパスワードを伏せる (password=… / pwd=… と、Oracle の thin:ユーザー/パスワード@)
function mask(s,    o, k, t, u) {
  o = ""
  while (match(s, /([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Ww][Dd])=[^;&,)]*/)) {
    k = substr(s, RSTART, RLENGTH); sub(/=.*$/, "", k)
    o = o substr(s, 1, RSTART - 1) k "=********"
    s = substr(s, RSTART + RLENGTH)
  }
  s = o s
  if (match(s, "thin:[^/@:]+/[^@]+@")) {
    t = substr(s, RSTART, RLENGTH); u = t; sub("/.*$", "", u)
    s = substr(s, 1, RSTART - 1) u "/********@" substr(s, RSTART + RLENGTH)
  }
  return s
}
function hdr(p, h,    l, has) { has = 0; if ((getline l < p) > 0) has = 1; close(p); if (!has) { print h >> p; close(p) } }
BEGIN {
  POOLC = "ActiveCount,AvailableCount,InUseCount,IdleCount,MaxUsedCount,WaitCount,MaxWaitCount,BlockingFailureCount,TimedOut,CreatedCount,DestroyedCount,AverageGetTime,MaxGetTime,TotalGetTime,AverageBlockingTime,MaxWaitTime,TotalBlockingTime,AverageUsageTime,MaxUsageTime,TotalUsageTime,AverageCreationTime,MaxCreationTime,TotalCreationTime,AveragePoolTime,MaxPoolTime,TotalPoolTime"
  XAC = "XAStartCount,XAStartAverageTime,XAStartMaxTime,XAStartTotalTime,XAEndCount,XAEndAverageTime,XAEndMaxTime,XAEndTotalTime,XAPrepareCount,XAPrepareAverageTime,XAPrepareMaxTime,XAPrepareTotalTime,XACommitCount,XACommitAverageTime,XACommitMaxTime,XACommitTotalTime,XARollbackCount,XARollbackAverageTime,XARollbackMaxTime,XARollbackTotalTime,XARecoverCount,XARecoverAverageTime,XARecoverMaxTime,XARecoverTotalTime,XAForgetCount,XAForgetAverageTime,XAForgetMaxTime,XAForgetTotalTime"
  JDBCC = "PreparedStatementCacheAccessCount,PreparedStatementCacheHitCount,PreparedStatementCacheMissCount,PreparedStatementCacheAddCount,PreparedStatementCacheDeleteCount,PreparedStatementCacheCurrentSize"
  if (mode == "header") {
    hdr(dir "/cli_datasource.csv", "timestamp,epoch,ds_type,ds_name,jndi_name,statistics_enabled,min_pool_size,initial_pool_size,max_pool_size,blocking_timeout_ms," POOLC "," XAC "," JDBCC ",cli_ms")
    hdr(dir "/cli_datasource_info.csv", "timestamp,epoch,ds_type,ds_name,attribute,value")
    exit
  }
  D = 0; BLK = ""; NE = 0; NJ = 0; NP = 0
  if (infoprev != "") {
    while ((getline l < infoprev) > 0) {
      n = split(l, a, "\t")
      if (n >= 3) { k = a[1] "\t" a[2] "\t" a[3]; if (!(k in PV)) PK[++NP] = k; PV[k] = (n >= 4) ? a[4] : "" }
    }
    close(infoprev)
  }
}
# ---- 字句解析 ----
function lex(line,    i, n, c, s, j, q) {
  NT = 0; n = length(line); i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (c == " " || c == "\t" || c == "\r") { i++; continue }
    if (c == "\"") {
      s = ""; j = i + 1
      while (j <= n) {
        q = index(substr(line, j), "\"")
        if (q == 0) { s = s substr(line, j); j = n + 1; break }
        s = s substr(line, j, q - 1); j = j + q - 1
        if (substr(s, length(s), 1) == "\\" && substr(s, length(s) - 1, 1) != "\\") { s = substr(s, 1, length(s) - 1) "\""; j++; continue }
        break
      }
      gsub(/\\\\/, "\\", s)
      NT++; TT[NT] = "S"; TV[NT] = s; i = j + 1; continue
    }
    if (c == "=" && substr(line, i + 1, 1) == ">") { NT++; TT[NT] = "A"; TV[NT] = ""; i += 2; continue }
    if (index("{}[](),", c) > 0) { NT++; TT[NT] = c; TV[NT] = c; i++; continue }
    j = i
    while (j <= n && index(" \t\r{}[](),\"", substr(line, j, 1)) == 0) j++
    NT++; TT[NT] = "W"; TV[NT] = substr(line, i, j - i); i = j
  }
}
# ---- 構文の追跡 (スタック) ----
function path(d,    p, k) { p = ""; for (k = 2; k <= d; k++) { if (p != "") p = p "/"; p = p FK[k] } return p }
function addent(ent) { if (!(ent in SEEN)) { SEEN[ent] = 1; ORD[++NE] = ent } }
function emit(    k, ty, nm, ent, s, t2, a, kind) {
  if (BLK ~ /^ds[pj]\.(ds|xa)$/) {
    t2 = substr(BLK, 5); ty = (t2 == "xa") ? "xa-data-source" : "data-source"
    nm = A[ty]; if (nm == "") return
    ent = t2 SUBSEP nm; addent(ent); kind = substr(BLK, 3, 1)
    for (k in R) V[ent, kind, k] = R[k]
    return
  }
  if (BLK ~ /^ds[ai]\.(ds|xa)\./) {
    s = substr(BLK, 5); t2 = substr(s, 1, 2); a = substr(s, 4)
    ty = (t2 == "xa") ? "xa-data-source" : "data-source"
    nm = A[ty]; if (nm == "") return
    ent = t2 SUBSEP nm; addent(ent)
    if ("_value" in R) V[ent, "a", a] = R["_value"]
    return
  }
  if (BLK ~ /^jb[wesj]$/) {
    if (BLK == "jbw") { ty = "io-worker"; nm = A["worker"] }
    else if (BLK == "jbe") { ty = "ee-executor"; nm = A["managed-executor-service"] }
    else if (BLK == "jbs") { ty = "ee-scheduled"; nm = A["managed-scheduled-executor-service"] }
    else { ty = "ejb3-thread-pool"; nm = A["thread-pool"] }
    if (nm == "") return
    ent = ty SUBSEP nm; if (!(ent in JSEEN)) { JSEEN[ent] = 1; JORD[++NJ] = ent }
    for (k in R) JV[ent, k] = R[k]
    return
  }
  if (BLK ~ /^m\./) { if ("_value" in R && metaf != "") print "jboss," substr(BLK, 3) "," csvq(R["_value"]) >> metaf; return }
  for (k in R) J[BLK, k] = R[k]
}
function push(t, key) {
  D++; FT[D] = t; FK[D] = key; ST[D] = 0; VB = ""
  if (t == "{" && D == 3 && FK[2] == "result" && FT[2] == "[" && key == "#") { WILD = 1; split("", R); split("", A); EOUT = "" }
  if (D == 1) { WILD = 0; ROUT = ""; split("", R); split("", A) }
}
function pop(    t) {
  t = FT[D]
  if (t == "{" && D == 3 && FK[2] == "result" && FT[2] == "[" && FK[3] == "#") { if (EOUT == "success" || EOUT == "") emit() }
  if (D == 1 && !WILD && ROUT == "success") emit()
  D--
  if (D > 0 && (FT[D] == "{" || FT[D] == "(")) ST[D] = 3
}
function scalar(key, v,    full, p) {
  v = norm(v)
  if (FT[D] == "(") { p = path(D - 1); if (p ~ /\/address$/ || p == "address") A[key] = v; return }
  p = path(D); full = (p == "" ? key : p "/" key)
  if (full == "outcome") { ROUT = v; return }
  if (full == "result") { R["_value"] = v; return }
  if (full == "result/#/outcome") { EOUT = v; return }
  if (full == "result/#/result") { R["_value"] = v; return }
  if (substr(full, 1, 16) == "result/#/result/") { full = substr(full, 17); gsub(/\//, ".", full); R[full] = v; return }
  if (substr(full, 1, 7) == "result/" && substr(full, 1, 9) != "result/#/") { full = substr(full, 8); gsub(/\//, ".", full); R[full] = v; return }
}
function tok(t, v,    f) {
  if (D == 0) { if (t == "{") push("{", ""); return }
  f = FT[D]
  if (f == "{" || f == "(") {
    if (ST[D] == 0) {
      if (t == "S" || t == "W") { CK[D] = v; ST[D] = 1; return }
      if (t == "}" || t == ")") pop()
      return
    }
    if (ST[D] == 1) { if (t == "A") { ST[D] = 2; VB = ""; VN = 0 } return }
    if (ST[D] == 2) {
      if (t == "{" || t == "[" || t == "(") { if (VN == 0) { ST[D] = 3; push(t, CK[D]) } return }
      if (t == "S" || t == "W") { VB = (VN == 0 ? v : VB " " v); VN++; return }
      if (t == ",") { scalar(CK[D], VB); ST[D] = 0; return }
      if (t == "}" || t == ")") { scalar(CK[D], VB); pop(); return }
      return
    }
    if (ST[D] == 3) {
      if (t == ",") { ST[D] = 0; return }
      if (t == "}" || t == ")") pop()
      return
    }
    return
  }
  if (f == "[") {
    if (t == "]") { pop(); return }
    if (t == "{" || t == "[" || t == "(") { push(t, "#"); return }
    return
  }
}
# ---- 1 レコード (応答 1 つ、またはワイルドカードの要素 1 つ) を表へ ----
function g(ent, kind, k) { return ((ent, kind, k) in V) ? V[ent, kind, k] : "" }
function jg(ent, k) { return ((ent, k) in JV) ? JV[ent, k] : "" }
function cols(ent, kind, list,    n, a, i, s) {
  n = split(list, a, ","); s = ""
  for (i = 1; i <= n; i++) s = s "," csvq(g(ent, kind, a[i]))
  return s
}
function jb(key, val, note) { print pre3 key ",\"" dq(val) "\",\"" dq(note) "\"" >> jbf }
/^PERF_B / { BLK = $2; D = 0; SEENB[$2] = 1; next }
/^PERF_F / { FAIL[$2] = 1; NFAIL++; FAILS = FAILS " " $2; next }
/^PERF_[SE] / { BLK = ""; D = 0; next }
BLK == "" { next }
{
  lex($0)
  for (ti = 1; ti <= NT; ti++) tok(TT[ti], TV[ti])
}
END {
  if (mode == "header") exit
  pre = csvq(ts) "," epoch
  nds = 0
  if (ok == 1) {
    # ① 統計 (プール統計の無い要素 = 統計のリソースが無いデータソースは書かない)
    for (i = 1; i <= NE; i++) {
      ent = ORD[i]; split(ent, e, SUBSEP)
      if (!((ent, "p", "InUseCount") in V)) continue
      nds++
      st = g(ent, "p", "statistics-enabled")
      print pre "," e[1] "," csvq(e[2]) "," csvq(g(ent, "a", "jndi-name")) "," st "," g(ent, "a", "min-pool-size") "," g(ent, "a", "initial-pool-size") \
        "," g(ent, "a", "max-pool-size") "," g(ent, "a", "blocking-timeout-wait-millis") cols(ent, "p", POOLC) cols(ent, "p", XAC) cols(ent, "j", JDBCC) "," cli_ms >> (dir "/cli_datasource.csv")
      if (enlist != "") {
        ty = (e[1] == "xa") ? "xa-data-source" : "data-source"
        if (st == "false") print ty "\t" e[2] "\tpool" > enlist
        if (g(ent, "j", "statistics-enabled") == "false") print ty "\t" e[2] "\tjdbc" > enlist
      }
    }
    # ① 情報 (読んだ回だけ。前回から変わった項目だけを書く。空欄 = 未設定 (既定値))
    ninfo = 0
    for (i = 1; i <= NE; i++) {
      ent = ORD[i]; split(ent, e, SUBSEP)
      na = split((e[1] == "xa") ? infoxa : infods, at, " ")
      for (j = 1; j <= na; j++) {
        a = at[j]; b = "dsi." e[1] "." a
        if (a == "" || !(b in SEENB) || (b in FAIL)) continue
        v = g(ent, "a", a); if (a == "connection-url") v = mask(v)
        k = e[1] "\t" e[2] "\t" a
        ninfo++
        if ((k in PV) && PV[k] == v) continue
        print pre "," e[1] "," csvq(e[2]) "," a "," csvq(v) >> (dir "/cli_datasource_info.csv")
        if (!(k in PV)) PK[++NP] = k
        PV[k] = v
      }
    }
    if (ninfo > 0 && infonew != "") { for (i = 1; i <= NP; i++) print PK[i] "\t" PV[PK[i]] > infonew; close(infonew) }
  }
  # ③ JBoss が CPU 数から決めたスレッド数 (mode=session)
  if (jbf != "") {
    pre3 = pre "," pid ",jboss,"
    for (i = 1; i <= NJ; i++) {
      ent = JORD[i]; split(ent, e, SUBSEP); p = e[1] "." e[2] "."
      if (e[1] == "io-worker") {
        jb(p "io-threads", jg(ent, "io-threads"), "Undertow の I/O スレッド数の設定 (未指定なら CPU 数 × 2)")
        jb(p "task-max-threads", jg(ent, "task-max-threads"), "HTTP リクエストを処理するスレッド (default task-N) の上限の設定 (未指定なら CPU 数 × 16)")
        jb(p "task-core-threads", jg(ent, "task-core-threads"), "タスクスレッドのコア数の設定")
        jb(p "io-thread-count", jg(ent, "io-thread-count"), "実際の I/O スレッド数")
        jb(p "max-pool-size", jg(ent, "max-pool-size"), "実際のタスクスレッドの上限")
        jb(p "core-pool-size", jg(ent, "core-pool-size"), "実際のタスクスレッドのコア数")
      } else if (e[1] == "ejb3-thread-pool") {
        jb(p "max-threads", jg(ent, "max-threads"), "EJB のスレッドプールの上限 (CPU 数に依存しない固定値)")
      } else {
        jb(p "core-threads", jg(ent, "core-threads"), "EE の管理エグゼキューターのコア数 (空欄 = 未指定: CPU 数から自動で決まる)")
        if (e[1] == "ee-executor") jb(p "max-threads", jg(ent, "max-threads"), "上限 (空欄 = 未指定: コア数と同じ)")
      }
    }
    if (("jbp", "_value") in J) jb("available-processors", J["jbp", "_value"], "JBoss の JVM の Runtime.availableProcessors() (JVM が認識した CPU 数)")
  }
  if (failf != "") print NFAIL + 0 "\t" FAILS "\t" nds > failf
}
'

# jboss-cli.sh を、サーバーと同じ java・小さなヒープで起動する (サブシェルから exec)
pm_cli_exec() {  # cli-file
    unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS
    JAVA_OPTS="${PM_CLI_JAVA_OPTS}"
    export JAVA_OPTS JBOSS_HOME
    [ -n "${PM_CLI_JAVA:-}" ] && { JAVA="${PM_CLI_JAVA}"; export JAVA; }
    set -- --connect "--controller=${PM_CLI_CTRL}" "--timeout=15000" "--command-timeout=${PERF_CLI_TIMEOUT}" "--file=$1"
    [ -n "${PERF_CLI_USER}" ] && set -- "$@" "--user=${PERF_CLI_USER}"
    [ -n "${PERF_CLI_PASSWORD}" ] && set -- "$@" "--password=${PERF_CLI_PASSWORD}"
    exec "${PM_CLI}" "$@"
}

# サーバーの起動引数から JBOSS_HOME・管理インタフェースのアドレス / ポートを読む
pm_cli_resolve() {
    JBOSS_HOME="${JBOSS_HOME:-}"
    _pm_addr=""; _pm_port=""; _pm_off=0; _pm_prev=""
    if [ -r "/proc/${PM_JPID}/cmdline" ]; then
        _pm_oifs="${IFS}"; IFS='
'
        for _pm_a in $(tr '\0' '\n' 2>/dev/null < "/proc/${PM_JPID}/cmdline"); do
            case "${_pm_a}" in
                -Djboss.home.dir=*) [ -z "${JBOSS_HOME}" ] && JBOSS_HOME="${_pm_a#*=}" ;;
                -Djboss.bind.address.management=*|-bmanagement=*) _pm_addr="${_pm_a#*=}" ;;
                -Djboss.management.http.port=*) _pm_port="${_pm_a#*=}" ;;
                -Djboss.socket.binding.port-offset=*) _pm_off="${_pm_a#*=}" ;;
            esac
            [ "${_pm_prev}" = "-bmanagement" ] && _pm_addr="${_pm_a}"
            _pm_prev="${_pm_a}"
        done
        IFS="${_pm_oifs}"
    fi
    JBOSS_HOME="${JBOSS_HOME:-/opt/jboss-eap}"
    PM_CLI="${JBOSS_HOME}/bin/jboss-cli.sh"
    [ -f "${PM_CLI}" ] || return 1
    _pm_port="$(pm_uint_or "${_pm_port}" 9990)"
    pm_is_uint "${_pm_off}" || _pm_off=0
    case "${_pm_addr}" in ""|0.0.0.0|::|"[::]"|localhost) _pm_addr=127.0.0.1 ;; esac
    PM_CLI_CTRL="${PERF_CLI_CONTROLLER:-remote+http://${_pm_addr}:$(( _pm_port + _pm_off ))}"
    PM_CLI_JAVA="$(pm_java_of_jboss)" || PM_CLI_JAVA=""
    # 先頭の -Dperf.metrics.collector は目印 (手動実行の jboss-cli と区別するため)
    PM_CLI_JAVA_OPTS="-Dperf.metrics.collector=jboss-cli -Xms16m -Xmx${PERF_CLI_HEAP} -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -XX:-UsePerfData -Xss512k -XX:ReservedCodeCacheSize=32m -Djava.awt.headless=true"
    return 0
}

pm_cli_alive() { [ -n "${PM_CLI_PID:-}" ] && kill -0 "${PM_CLI_PID}" 2>/dev/null; }

pm_cli_stop() {
    if [ "${PM_CLI_FD:-0}" = 1 ]; then
        printf 'quit\n' >&7 2>/dev/null
        exec 7>&-
        PM_CLI_FD=0
    fi
    if pm_cli_alive; then
        sleep 1
        pm_cli_alive && pm_kill_tree "${PM_CLI_PID}"
    fi
    [ -n "${PM_CLI_PID:-}" ] && wait "${PM_CLI_PID}" 2>/dev/null
    PM_CLI_PID=""
    rm -f "${PM_W}/cli.in" 2>/dev/null
    return 0
}

# 目印の行が出るまで待つ。0=出た 1=CLI が終了した 2=タイムアウト
pm_cli_wait() {  # marker timeout
    _pm_dl=$(( $(date +%s) + $2 ))
    while :; do
        grep -qx "$1" "${PM_W}/cli.out" 2>/dev/null && return 0
        pm_cli_alive || return 1
        [ "$(date +%s)" -ge "${_pm_dl}" ] && return 2
        sleep 0.2 2>/dev/null || sleep 1
    done
}

pm_cli_start() {
    pm_cli_stop
    : > "${PM_W}/cli.out" || return 1
    mkfifo -m 600 "${PM_W}/cli.in" 2>/dev/null || return 1
    ( pm_cli_exec "${PM_W}/cli.in" ) >> "${PM_W}/cli.out" 2>> "${PM_W}/cli.err" < /dev/null &
    PM_CLI_PID=$!
    # FIFO を読み書き両用で開いておく (CLI が EOF を受けて終わらないように)
    exec 7<> "${PM_W}/cli.in" || { pm_cli_stop; return 1; }
    PM_CLI_FD=1
    printf 'echo PERF_READY\n' >&7
    if ! pm_cli_wait PERF_READY "${PERF_CLI_CONNECT_TIMEOUT}"; then
        pm_cli_stop
        return 1
    fi
    pm_log INFO "jboss-cli の常駐セッションを開始しました (pid=${PM_CLI_PID}, ${PM_CLI_CTRL})"
    return 0
}

# 1 回分の問い合わせ。応答が最後まで揃えば 0。
pm_cli_exchange() {  # seq block-file
    : > "${PM_W}/cli.out"
    pm_cli_alive || return 1
    { printf 'echo PERF_S %s\n' "$1"; cat "$2"; printf 'echo PERF_E %s\n' "$1"; } >&7 2>/dev/null || return 1
    pm_cli_wait "PERF_E $1" "${PERF_CLI_TIMEOUT}"
    case $? in
        0) return 0 ;;
        2) pm_log WARN "jboss-cli が ${PERF_CLI_TIMEOUT} 秒以内に応答しません。セッションを作り直します" ;;
    esac
    pm_cli_stop
    return 1
}

# 統計が無効なデータソースを実行時に有効化する (statistics=pool / jdbc の実行時属性)
pm_cli_enable_stats() {  # seq
    : > "${PM_W}/enable.cli"
    while IFS="${PM_TAB}" read -r _pm_ty _pm_dn _pm_kind; do
        [ -n "${_pm_dn}" ] || continue
        pm_cli_q en "/subsystem=datasources/${_pm_ty}=$(pm_cli_quote "${_pm_dn}")/statistics=${_pm_kind:-pool}:write-attribute(name=statistics-enabled,value=true)" \
            >> "${PM_W}/enable.cli"
        pm_log INFO "データソース ${_pm_dn} の統計 (${_pm_kind:-pool}) を実行時に有効化します (設定ファイルは変えません)"
    done < "${PM_W}/cli.enable"
    if pm_cli_exchange "$1" "${PM_W}/enable.cli"; then
        [ -n "${PM_EN_META:-}" ] || pm_meta cli ds_stats_enabled_at_runtime "$(date '+%Y-%m-%d %H:%M:%S')"
        PM_EN_META=1
    else
        pm_log WARN "データソースの統計を有効化できませんでした"
    fi
}

pm_cli_parse() {  # cli_ms
    _pm_en=""
    [ "${PERF_CLI_ENABLE_DS_STATS}" = "true" ] && _pm_en="${PM_W}/cli.enable"
    rm -f "${PM_W}/dsinfo.new"
    awk -v ts="${PM_TS}" -v epoch="${PM_EPOCH}" -v cli_ms="$1" -v ok=1 -v dir="${PM_OUT}" -v enlist="${_pm_en}" \
        -v failf="${PM_W}/cli.fail" -v infods="${PM_DS_INFO_ATTRS} ${PM_DS_INFO_DS}" -v infoxa="${PM_DS_INFO_ATTRS} ${PM_DS_INFO_XA}" \
        -v infoprev="${PM_W}/dsinfo.prev" -v infonew="${PM_W}/dsinfo.new" \
        -f "${PM_W}/cli.awk" "${PM_W}/cli.out" 2>> "${PM_W}/cli.err"
    [ -f "${PM_W}/dsinfo.new" ] && mv -f "${PM_W}/dsinfo.new" "${PM_W}/dsinfo.prev"
    return 0
}

# JVM ごとに 1 回: サーバーの情報と ③ の JBoss 側のスレッド数
pm_cli_session() {  # seq
    pm_cli_exchange "$1" "${PM_W}/session.cli" || return 1
    grep -q '^PERF_F m\.product-name$' "${PM_W}/cli.out" && return 1
    pm_now
    : > "${PM_W}/cpu_env.cli"
    awk -v mode=session -v ts="${PM_TS}" -v epoch="${PM_EPOCH}" -v pid="${PM_JPID}" -v metaf="${PM_OUT}/perf_meta.csv" \
        -v jbf="${PM_W}/cpu_env.cli" -f "${PM_W}/cli.awk" "${PM_W}/cli.out" 2>> "${PM_W}/cli.err"
    [ -s "${PM_W}/cpu_env.cli" ] && pm_append_locked "${PM_OUT}/cpu_env.csv" "${PM_W}/cpu_env.cli" "${PM_CPU_ENV_H}"
    return 0
}

pm_run_cli() {
    PM_NAME=cli
    PM_CLI_FD=0; PM_CLI_PID=""
    trap 'pm_cli_stop; exit 0' TERM INT
    pm_wait_jboss || exit 0
    if ! pm_cli_resolve; then
        pm_log WARN "jboss-cli.sh が見つかりません (JBOSS_HOME=${JBOSS_HOME:-})。① の取得を終了します"
        exit 0
    fi
    printf '%s\n' "${PM_CLI_AWK}" > "${PM_W}/cli.awk"
    awk -v mode=header -v dir="${PM_OUT}" -f "${PM_W}/cli.awk" /dev/null
    pm_cli_sample_block > "${PM_W}/sample.cli"
    { pm_cli_sample_block; pm_cli_info_block; } > "${PM_W}/sample_info.cli"
    pm_cli_session_block > "${PM_W}/session.cli"
    rm -f "${PM_W}/dsinfo.prev"
    pm_meta cli controller "${PM_CLI_CTRL}"
    pm_log INFO "① jboss-cli: ${PERF_CLI_INTERVAL} 秒間隔 (DB 接続プールの統計。情報は最初と ${PM_DS_INFO_EVERY} 回ごと・データソースの増減時。${PM_CLI_CTRL})"
    _pm_seq=0; _pm_fail=0; _pm_en_last=0; _pm_retry=5; _pm_sess_pid=""; _pm_info_left=0; _pm_nds=""
    _pm_conn_dl=$(( $(date +%s) + PERF_WAIT_TIMEOUT ))
    while :; do
        if ! pm_cli_alive && ! pm_cli_start; then
            if [ "$(date +%s)" -ge "${_pm_conn_dl}" ]; then
                pm_warn_once noconn "管理インタフェース (${PM_CLI_CTRL}) に ${PERF_WAIT_TIMEOUT} 秒たっても接続できません。60 秒ごとに再試行します。詳細: ${PM_W}/cli.err"
                _pm_retry=60
            fi
            sleep "${_pm_retry}"
            continue
        fi
        pm_jboss_alive || PM_JPID="$(pm_find_jboss_pid)" || PM_JPID=""
        if [ -n "${PM_JPID}" ] && [ "${_pm_sess_pid}" != "${PM_JPID}" ]; then
            _pm_seq=$((_pm_seq + 1))
            if pm_cli_session "${_pm_seq}"; then
                _pm_sess_pid="${PM_JPID}"
                _pm_info_left=0
            fi
        fi
        pm_now
        _pm_seq=$((_pm_seq + 1))
        rm -f "${PM_W}/cli.enable"
        if [ "${_pm_info_left}" -le 0 ]; then _pm_blk="${PM_W}/sample_info.cli"; else _pm_blk="${PM_W}/sample.cli"; fi
        _pm_t0="$(pm_ms)"
        # jboss-cli はサーバーの再起動後に自分で再接続する。その間の操作は catch 側 (PERF_F) に入る
        if pm_cli_exchange "${_pm_seq}" "${_pm_blk}" && ! grep -q '^PERF_F dsp\.ds$' "${PM_W}/cli.out"; then
            _pm_t1="$(pm_ms)"
            pm_cli_parse "$((_pm_t1 - _pm_t0))"
            if [ "${_pm_blk}" = "${PM_W}/sample_info.cli" ]; then _pm_info_left="${PM_DS_INFO_EVERY}"; fi
            _pm_info_left=$((_pm_info_left - 1))
            # データソースの数が変わったら (デプロイ・追加・削除) 次の回に情報を読み直す
            _pm_n="$(cut -f3 "${PM_W}/cli.fail" 2>/dev/null)"
            if [ -n "${_pm_n}" ] && [ "${_pm_n}" != "${_pm_nds}" ]; then
                [ -n "${_pm_nds}" ] && _pm_info_left=0
                _pm_nds="${_pm_n}"
            fi
            [ "${_pm_fail}" -gt 0 ] && pm_log INFO "① jboss-cli の取得を再開しました (失敗 ${_pm_fail} 回)"
            _pm_fail=0
        else
            _pm_fail=$((_pm_fail + 1))
            [ "${_pm_fail}" = 1 ] && pm_log WARN "① jboss-cli の取得に失敗しました (seq=${_pm_seq})。続けて試します。詳細: ${PM_W}/cli.err"
        fi
        # 統計が無効なデータソースは実行時に有効化する (60 秒に 1 回まで)
        if [ -s "${PM_W}/cli.enable" ] && [ $(( PM_EPOCH - _pm_en_last )) -ge 60 ]; then
            _pm_en_last="${PM_EPOCH}"
            _pm_seq=$((_pm_seq + 1))
            pm_cli_enable_stats "${_pm_seq}"
        fi
        pm_sleep_tick "${PERF_CLI_INTERVAL}"
    done
}

# =============================================================================
# ② ヒープ・GC: jstat
# =============================================================================
# jstat は「間隔」を指定して 1 つだけ常駐させ、出力の各行に時刻を付けて CSV にする。
# 標準の -gc の列に、セーフポイントと直近の GC の原因を足したカスタムオプション perfgc を使う
# (jstat は <user.home>/.jvmstat/jstat_options を読む)。
# カウンタ名・書式は JDK 21 の jstat_options (-gc / -gccause) と同じ。
PM_JSTAT_OPTIONS='option perfgc {
  column { header "^S0C^" data sun.gc.generation.0.space.1.capacity scale K align right width 11 format "0.0" }
  column { header "^S1C^" data sun.gc.generation.0.space.2.capacity scale K align right width 11 format "0.0" }
  column { header "^S0U^" data sun.gc.generation.0.space.1.used scale K align right width 11 format "0.0" }
  column { header "^S1U^" data sun.gc.generation.0.space.2.used scale K align right width 11 format "0.0" }
  column { header "^EC^" data sun.gc.generation.0.space.0.capacity align right scale K width 12 format "0.0" }
  column { header "^EU^" data sun.gc.generation.0.space.0.used align right scale K width 12 format "0.0" }
  column { header "^OC^" data sun.gc.generation.1.space.0.capacity align right scale K width 12 format "0.0" }
  column { header "^OU^" data sun.gc.generation.1.space.0.used align right width 12 scale K format "0.0" }
  column { header "^MC^" data sun.gc.metaspace.capacity align right width 10 scale K format "0.0" }
  column { header "^MU^" data sun.gc.metaspace.used align right width 10 scale K format "0.0" }
  column { header "^CCSC^" data sun.gc.compressedclassspace.capacity align right width 9 scale K format "0.0" }
  column { header "^CCSU^" data sun.gc.compressedclassspace.used align right width 9 scale K format "0.0" }
  column { header "^YGC^" data sun.gc.collector.0.invocations align right width 6 format "0" }
  column { header "^YGCT^" data sun.gc.collector.0.time/sun.os.hrt.frequency align right width 9 scale sec format "0.000" }
  column { header "^FGC^" data sun.gc.collector.1.invocations align right width 5 scale raw format "0" }
  column { header "^FGCT^" data sun.gc.collector.1.time/sun.os.hrt.frequency align right width 9 scale sec format "0.000" }
  column { header "^CGC^" data sun.gc.collector.2.invocations align right width 5 scale raw format "0" }
  column { header "^CGCT^" data sun.gc.collector.2.time/sun.os.hrt.frequency align right width 9 scale sec format "0.000" }
  column { header "^GCT^" data (sun.gc.collector.0.time + sun.gc.collector.1.time + sun.gc.collector.2.time)/sun.os.hrt.frequency align right width 9 scale sec format "0.000" required true }
  column { header "^SPN^" data sun.rt.safepoints align right width 8 scale raw format "0" }
  column { header "^SPT^" data sun.rt.safepointTime/sun.os.hrt.frequency align right width 10 scale sec format "0.000" }
  column { header "^SPS^" data sun.rt.safepointSyncTime/sun.os.hrt.frequency align right width 10 scale sec format "0.000" }
  column { header "^LGCC" data sun.gc.lastCause align left width 20 scale raw }
}'

# jstat の出力 (空白区切り・先頭列が JVM の稼働秒) を、時刻付きの CSV にする。
# 最後の列 LGCC (GC の原因) は空白を含むので、見出しの列数より後ろは 1 つの値にまとめる。
pm_jstat_csv() {  # csv-file
    _pm_f="$1"
    _pm_nh=0
    set -f
    while IFS= read -r _pm_l; do
        # shellcheck disable=SC2086
        set -- ${_pm_l}
        case "${1:-}" in
            Timestamp)
                shift
                _pm_nh=$#
                [ -s "${_pm_f}" ] || ( IFS=,; printf 'timestamp,epoch,uptime_s,%s\n' "$*" ) >> "${_pm_f}"
                ;;
            [0-9]*)
                [ "${_pm_nh}" -gt 0 ] || continue
                pm_now
                # 先頭 = 稼働秒、続く (見出しの列数 - 1) 個 = 各列、残り全部 = 最後の列
                _pm_row="${PM_TS},${PM_EPOCH},$1"; shift
                _pm_i=1; _pm_tail=""
                for _pm_v in "$@"; do
                    if [ "${_pm_i}" -lt "${_pm_nh}" ]; then _pm_row="${_pm_row},${_pm_v}"
                    else _pm_tail="${_pm_tail}${_pm_tail:+ }${_pm_v}"; fi
                    _pm_i=$((_pm_i + 1))
                done
                case "${_pm_tail}" in *[!0-9.-]*) _pm_tail="\"$(printf '%s' "${_pm_tail}" | tr -d '"')\"" ;; esac
                printf '%s,%s\n' "${_pm_row}" "${_pm_tail}" >> "${_pm_f}"
                ;;
        esac
    done
    set +f
}

# /tmp の hsperfdata に、このコンテナの JVM ではないもの (他のコンテナと /tmp を共有) があるか
pm_hsperf_shared_check() {
    for _pm_h in /tmp/hsperfdata_*/*; do
        [ -e "${_pm_h}" ] || continue
        _pm_hp="${_pm_h##*/}"
        pm_is_uint "${_pm_hp}" || continue
        if [ ! -r "/proc/${_pm_hp}/cmdline" ] || ! tr '\0' ' ' < "/proc/${_pm_hp}/cmdline" 2>/dev/null | grep -q java; then
            pm_warn_once hsperfshared "② /tmp/hsperfdata に、このコンテナに無い JVM のカウンタ (${_pm_h}) があります。/tmp を他のコンテナと共有していると PID が重なり、jstat / jcmd が別の JVM を読みます。コンテナごとに別のボリュームを当ててください (終了した JVM の残骸なら問題ありません)"
            return 0
        fi
    done
    return 0
}

pm_run_jstat() {
    PM_NAME=jstat
    trap 'exit 0' TERM INT
    pm_wait_jboss || exit 0
    if ! pm_resolve_tool jstat; then
        pm_log WARN "② jstat を起動できません (jstat が無く、java に jdk.jcmd モジュールもありません)"
        exit 0
    fi
    mkdir -p "${PM_W}/jstat-home/.jvmstat"
    printf '%s\n' "${PM_JSTAT_OPTIONS}" > "${PM_W}/jstat-home/.jvmstat/jstat_options"
    PM_TOOL_SYSPROPS="-Duser.home=${PM_W}/jstat-home"
    pm_meta jvm jstat_command "$(pm_tool_desc)"
    _pm_miss=0; _pm_opt=""
    while :; do
        pm_jboss_alive || PM_JPID="$(pm_find_jboss_pid)" || { sleep 5; continue; }
        if ! pm_hsperf_exists "${PM_JPID}"; then
            # JVM の起動直後はまだ無いことがあるため、30 秒続けて無いときだけ警告する
            _pm_miss=$((_pm_miss + 1))
            [ "${_pm_miss}" -ge 3 ] && pm_warn_once "hsperf${PM_JPID}" "② jstat: JVM の性能カウンタ (/tmp/hsperfdata_*/${PM_JPID}) がありません。/tmp が書き込めない、または JBoss に -XX:-UsePerfData / -XX:+PerfDisableSharedMem が指定されています"
            sleep 10
            continue
        fi
        _pm_miss=0
        pm_hsperf_shared_check
        # カスタムオプションが使えるか 1 回だけ確かめる (使えなければ標準の -gc)
        if [ -z "${_pm_opt}" ]; then
            if pm_tool_exec -perfgc "${PM_JPID}" 1 1 2>> "${PM_W}/jstat.err" | grep -q 'LGCC'; then _pm_opt=perfgc
            else _pm_opt=gc; pm_log WARN "② jstat のカスタムオプション perfgc が使えないため -gc で取得します (詳細: ${PM_W}/jstat.err)"; fi
            pm_meta jvm jstat_option "-${_pm_opt}"
        fi
        pm_log INFO "② jstat -${_pm_opt} を開始します (pid=${PM_JPID}, ${PERF_JSTAT_INTERVAL} 秒間隔, $(pm_tool_desc))"
        pm_tool_exec "-${_pm_opt}" -t "${PM_JPID}" "${PERF_JSTAT_INTERVAL}s" 2>> "${PM_W}/jstat.err" | pm_jstat_csv "${PM_OUT}/jvm_jstat_gc.csv"
        pm_log INFO "② jstat -${_pm_opt} が終了しました。5 秒後に再開します (JVM の再起動・停止の可能性)"
        sleep 5
    done
}

# =============================================================================
# ② ヒープ・GC: jcmd (GC.heap_info・JVM の版とフラグ)・JFR の開始の確認
# =============================================================================
# GC.heap_info の出力 (GC の種類で書き方が違う) を 1 行の CSV にする。
PM_JCMD_AWK='
function kb(s,    n, u) {
  n = s; sub(/[KMGkmgBb]+$/, "", n); u = toupper(substr(s, length(n) + 1, 1))
  n = n + 0; if (u == "M") n *= 1024; else if (u == "G") n *= 1048576; else if (u == "B") n = n / 1024
  return int(n)
}
function num(line, word,    re, s) { re = word "[ =]+[0-9]+[KMGBkb]*"; if (match(line, re)) { s = substr(line, RSTART, RLENGTH); sub(word "[ =]+", "", s); return kb(s) } return "" }
function csvq(s) { if (s ~ /[",\r\n]/) { gsub(/"/, "\"\"", s); return "\"" s "\"" } return s }
# GC.heap_info 以外 (スレッドダンプなど) が続いても読まない
/^Full thread dump |^Native Memory Tracking:|^CodeHeap |^CodeCache:/ { OTHER = 1; next }
OTHER { next }
/garbage-first heap|Shenandoah Heap|ZHeap|^ *ZGC/ {
  gc = ($0 ~ /garbage-first/) ? "G1" : ($0 ~ /Shenandoah/) ? "Shenandoah" : "Z"
  ht = num($0, "total"); hc = num($0, "committed"); hr = num($0, "reserved"); hu = num($0, "used")
  if (ht == "" && hc != "") ht = hc
  HEAP = 1; next
}
/region size/ {
  rs = num($0, "region size")
  if (match($0, /[0-9]+ young \([0-9]+[KMG]\)/)) { s = substr($0, RSTART, RLENGTH); split(s, a, /[ ()]+/); yr = a[1]; yk = kb(a[3]) }
  if (match($0, /[0-9]+ survivors \([0-9]+[KMG]\)/)) { s = substr($0, RSTART, RLENGTH); split(s, a, /[ ()]+/); sr = a[1]; sk = kb(a[3]) }
  next
}
/(def new generation|PSYoungGen|par new generation)/ { if (gc == "") gc = ($0 ~ /PSYoungGen/) ? "Parallel" : "Serial"; ygt = num($0, "total"); ygu = num($0, "used"); HEAP = 1; next }
/(tenured generation|ParOldGen)/ { ogt = num($0, "total"); ogu = num($0, "used"); next }
/^ *Metaspace +used/ { mu = num($0, "used"); mc = num($0, "committed"); mr = num($0, "reserved"); next }
/^ *class space +used/ { cu = num($0, "used"); cc = num($0, "committed"); cr = num($0, "reserved"); next }
END {
  if (!HEAP) exit
  if (ht == "" && ygt != "") { ht = ygt + ogt; hu = ygu + ogu }
  print csvq(ts) "," epoch "," gc "," ht "," hc "," hr "," hu "," rs "," yr "," yk "," sr "," sk "," ygt "," ygu "," ogt "," ogu "," mu "," mc "," mr "," cu "," cc "," cr "," ms >> (dir "/jvm_jcmd_heap.csv")
}
'

PM_JCMD_HEAP_H="timestamp,epoch,gc,heap_total_kb,heap_committed_kb,heap_reserved_kb,heap_used_kb,region_size_kb,young_regions,young_kb,survivor_regions,survivor_kb,young_gen_total_kb,young_gen_used_kb,old_gen_total_kb,old_gen_used_kb,metaspace_used_kb,metaspace_committed_kb,metaspace_reserved_kb,class_used_kb,class_committed_kb,class_reserved_kb,jcmd_ms"

pm_jcmd_run() {  # out-file command...
    _pm_of="$1"; shift
    pm_tool_exec "${PM_JPID}" "$@" > "${_pm_of}" 2>> "${PM_W}/jcmd.err"
}

pm_threaddump() {
    mkdir -p "${PM_OUT}/threaddump" 2>/dev/null
    _pm_td="${PM_OUT}/threaddump/threaddump_$(date '+%Y%m%d_%H%M%S').txt"
    if pm_jcmd_run "${PM_W}/td.tmp" Thread.print -l; then
        { echo "# $(date '+%Y-%m-%d %H:%M:%S') jcmd ${PM_JPID} Thread.print -l"; cat "${PM_W}/td.tmp"; } > "${_pm_td}"
        pm_log INFO "スレッドダンプを取得しました: ${_pm_td}"
        echo "${_pm_td}"
    else
        pm_log WARN "スレッドダンプを取得できませんでした (詳細: ${PM_W}/jcmd.err)"
        return 1
    fi
}

# JFR の記録が JBoss で動いているか確かめ、無ければ (起動時のオプションが効いていないとき) jcmd で始める
pm_jfr_ensure() {
    [ "${PERF_JFR}" = "true" ] || { pm_meta jfr state "off"; return 0; }
    case "${PM_JFR_MODE}" in off) pm_meta jfr state "off"; return 0 ;; esac
    pm_jcmd_run "${PM_W}/jfr.chk" JFR.check || { pm_log WARN "② JFR.check に失敗しました (詳細: ${PM_W}/jcmd.err)"; return 1; }
    if grep -q 'name=perf-metrics' "${PM_W}/jfr.chk"; then
        pm_meta jfr state "running (${PM_JFR_MODE})"
        pm_log INFO "② JFR: 記録 perf-metrics が動いています ($(grep 'name=perf-metrics' "${PM_W}/jfr.chk" | head -n 1 | sed 's/^ *//'))"
        return 0
    fi
    if [ "${PM_JFR_MODE}" = user ]; then
        pm_meta jfr state "user ($(grep -c '^Recording' "${PM_W}/jfr.chk") recordings)"
        return 0
    fi
    # 起動時のオプションが効いていない (CMD が standalone.sh ではない・PRESERVE_JAVA_OPTS 等) → jcmd で始める
    mkdir -p "${PM_JFR_DIR}/repo" 2>/dev/null
    pm_jcmd_run "${PM_W}/jfr.cfg" JFR.configure "repositorypath=${PM_JFR_DIR}/repo" preserve-repository=true \
        || pm_log WARN "② JFR.configure に失敗しました (リポジトリは既定の /tmp になります)"
    set -f
    _pm_oifs="${IFS}"; IFS=' '
    # shellcheck disable=SC2046
    if pm_jcmd_run "${PM_W}/jfr.start" JFR.start $(pm_jfr_items ' '); then
        IFS="${_pm_oifs}"; set +f
        pm_meta jfr state "started-by-jcmd"
        pm_log INFO "② JFR: jcmd JFR.start で記録を始めました (${PM_JFR_DIR})"
    else
        IFS="${_pm_oifs}"; set +f
        pm_meta jfr state "start-failed"
        pm_log WARN "② JFR を開始できませんでした (詳細: ${PM_W}/jcmd.err)"
    fi
}

pm_jcmd_once() {  # JVM ごとに 1 回: 版・コマンド行・フラグ・JFR
    pm_jcmd_run "${PM_W}/jcmd.tmp" VM.version || return 1
    {
        echo "# $(date '+%Y-%m-%d %H:%M:%S') jcmd ${PM_JPID} VM.version"; cat "${PM_W}/jcmd.tmp"
        pm_jcmd_run "${PM_W}/jcmd.tmp2" VM.command_line && { echo "# jcmd ${PM_JPID} VM.command_line"; sed "${PM_MASK_SED}" "${PM_W}/jcmd.tmp2"; }
        pm_jcmd_run "${PM_W}/jcmd.tmp2" VM.flags && { echo "# jcmd ${PM_JPID} VM.flags"; sed "${PM_MASK_SED}" "${PM_W}/jcmd.tmp2"; }
    } >> "${PM_OUT}/jvm_info.txt"
    pm_meta jvm version "$(sed -n '2p' "${PM_W}/jcmd.tmp")"
    pm_meta jvm pid "${PM_JPID}"
    pm_jfr_ensure
    return 0
}

pm_run_jcmd() {
    PM_NAME=jcmd
    trap 'exit 0' TERM INT
    pm_wait_jboss || exit 0
    if ! pm_resolve_tool jcmd; then
        pm_log WARN "② jcmd を起動できません (jcmd が無く、java に jdk.jcmd モジュールもありません)"
        exit 0
    fi
    printf '%s\n' "${PM_JCMD_AWK}" > "${PM_W}/jcmd.awk"
    pm_csv_init "${PM_OUT}/jvm_jcmd_heap.csv" "${PM_JCMD_HEAP_H}"
    pm_meta jvm jcmd_command "$(pm_tool_desc)"
    pm_log INFO "② jcmd: ${PERF_JCMD_INTERVAL} 秒間隔 (GC.heap_info, $(pm_tool_desc))"
    _pm_done_pid=""; _pm_first=1
    while :; do
        pm_jboss_alive || PM_JPID="$(pm_find_jboss_pid)" || { sleep 5; continue; }
        if [ "${_pm_done_pid}" != "${PM_JPID}" ]; then
            if pm_jcmd_once; then
                _pm_done_pid="${PM_JPID}"
            else
                [ "${_pm_first}" = 1 ] && pm_log INFO "② jcmd: JVM へまだアタッチできません。続けて試します (詳細: ${PM_W}/jcmd.err)"
                _pm_first=0
                pm_is_writable /tmp || pm_warn_once jcmdtmp "② jcmd: /tmp に書き込めないため JVM へアタッチできません (タスク定義で /tmp にボリュームを当ててください)"
                sleep 10
                continue
            fi
        fi
        pm_now
        _pm_t0="$(pm_ms)"
        if pm_jcmd_run "${PM_W}/jcmd.out" GC.heap_info; then
            _pm_t1="$(pm_ms)"
            awk -v ts="${PM_TS}" -v epoch="${PM_EPOCH}" -v ms="$((_pm_t1 - _pm_t0))" -v dir="${PM_OUT}" -f "${PM_W}/jcmd.awk" "${PM_W}/jcmd.out" 2>> "${PM_W}/jcmd.err"
        else
            pm_warn_once "jcmdheap${PM_JPID}" "② jcmd ${PM_JPID} GC.heap_info に失敗しました (詳細: ${PM_W}/jcmd.err)"
        fi
        pm_sleep_tick "${PERF_JCMD_INTERVAL}"
    done
}

# =============================================================================
# ② ヒープ・GC: JFR → CSV (収集中は jfr、試験の後は perf-metrics.sh jfr-csv)
# =============================================================================
# 単一ファイルの Java (java PerfJfrCsv.java) で、公開 API (jdk.jfr.consumer) だけを使って読む。
# Red Hat の OpenJDK 21 runtime イメージにも jdk.jfr・jdk.compiler モジュールが入っている。
#   収集中 (--stream): JBoss の JVM が書いている JFR のリポジトリ (perf/jfr/repo/<日時>_<pid>) を
#                      追いかけ (EventStream.openRepository)、行ができるたびに CSV へ追記する
#   試験の後         : 記録 (終了時の perf_<pid>_<日時>.jfr・jfr-dump・リポジトリのチャンク) を変換する
# 同じものが出力先の jfr/PerfJfrCsv.java にも置かれ、PC (JDK 17 以降) でも変換できる。
PM_JFR_JAVA='// perf-metrics.sh (Lite): JFR (Flight Recorder) heap / GC events -> CSV files for the Excel report.
// Usage:
//   java PerfJfrCsv.java <out-dir> <interval-seconds> <jfr dir or file> [...]           convert recordings
//   java PerfJfrCsv.java --stream <out-dir> <interval-seconds> <repository-dir> <pid>  follow a running JVM
// Writes jfr_heap.csv (one row per periodic sample: heap and pools, allocation, GCs since the previous
// sample), jfr_gc.csv (one row per GC), jfr_env.csv (GC / heap / CPU configuration) and jfr_summary.csv.
// Needs only the public jdk.jfr.consumer API (JDK 17+; tested with Red Hat OpenJDK 21 and JDK 17).
// Runs as a single-file source program. It is embedded in a shell string, so it has no quote characters
// other than the double quote.
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.regex.*;
import jdk.jfr.Timespan;
import jdk.jfr.ValueDescriptor;
import jdk.jfr.consumer.*;

public class PerfJfrCsv {
    static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    static final ZoneId ZONE = ZoneId.systemDefault();
    static final Pattern MASK = Pattern.compile("(?i)([A-Za-z0-9_.-]*(password|passwd|secret)[A-Za-z0-9_.-]*[=:])[^ ,]*");
    static final Pattern REPO_DIR = Pattern.compile("^\\d{4}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_(\\d+)$");
    static final Pattern EXIT_DUMP = Pattern.compile("^perf_(\\d+)_.*\\.jfr$");
    static final Pattern DEMAND_DUMP = Pattern.compile("^perf_dump_(\\d+)_.*\\.jfr$");
    static final String GC_H = "timestamp,epoch,epoch_ms,pid,gc_id,name,cause,g1_type,sum_of_pauses_ms,longest_pause_ms,duration_ms,"
            + "heap_before_mb,heap_after_mb,heap_committed_mb,eden_before_mb,survivor_before_mb,survivor_after_mb,old_before_mb,old_after_mb,"
            + "metaspace_before_mb,metaspace_after_mb,metaspace_committed_mb,gc_cpu_user_ms,gc_cpu_sys_ms,gc_cpu_real_ms,tenuring_threshold,evacuation_failed";
    static final String HEAP_H = "timestamp,epoch,epoch_ms,pid,heap_used_mb,heap_committed_mb,heap_max_mb,eden_used_mb,eden_committed_mb,"
            + "survivor_used_mb,survivor_committed_mb,old_used_mb,old_committed_mb,alloc_mb,alloc_mb_per_sec,gc_count,full_gc_count,"
            + "gc_pause_total_ms,gc_pause_max_ms,gc_cpu_ms,heap_after_gc_mb,old_after_gc_mb";
    static final Set<String> FULL = new HashSet<>(Arrays.asList("G1Full", "SerialOld", "ParallelOld", "PSMarkSweep"));
    static final double MB = 1048576.0;

    static long intervalMs = 10000, groupMs = 2000, gcDelayMs = 1000;
    static Path outDir;
    static PrintWriter gcOut, heapOut;
    static boolean live = false;
    static final LinkedHashMap<String, String> ENV = new LinkedHashMap<>();
    static final Map<String, long[]> TYPES = new TreeMap<>();      // count, first, last (epoch seconds)
    static final Map<String, Long> SYSGC = new TreeMap<>();        // caller of System.gc() -> count
    static final List<String[]> FILES = new ArrayList<>();
    static boolean envDirty = false;
    static long envWritten = 0, summaryWritten = 0;

    // ---- state of one JVM (pid)
    static String pid = "";
    static long clock = Long.MIN_VALUE;             // latest event end time (ms): the stream is ordered by commit time
    static long skipGcId = -1, skipTickMs = -1;     // already written (resuming a stream)
    static final TreeMap<Long, Gc> GCS = new TreeMap<>();
    static final Set<Long> FINISHED = new HashSet<>();
    static final List<Gc> DONE = new ArrayList<>(); // finished GCs not yet counted in a periodic row
    static Tick tick = null;
    static long prevTickMs = -1;
    static Map<Long, Long> prevAlloc = null;

    static class Gc {
        final long id; Instant start; long endMs, lastMs; boolean haveGc, failed;
        String name, cause, g1Type; Integer tenuring;
        Double dur, sumP, longP, hb, ha, hc, eb, sb, sa, ob, oa, mtb, mta, mtc, cu, cs, cr;
        Gc(long id) { this.id = id; }
    }
    static class Tick {
        final long t; Double used, committed, max;
        final Map<String, double[]> pools = new HashMap<>();
        final Map<Long, Long> alloc = new HashMap<>();
        Tick(long t) { this.t = t; }
    }

    public static void main(String[] args) throws Exception {
        boolean stream = args.length > 0 && args[0].equals("--stream");
        String[] a = stream ? Arrays.copyOfRange(args, 1, args.length) : args;
        if (a.length < 3 || (stream && a.length < 4)) {
            System.err.println("usage: java PerfJfrCsv.java <out-dir> <interval-seconds> <jfr dir or file> [...]");
            System.err.println("       java PerfJfrCsv.java --stream <out-dir> <interval-seconds> <repository-dir> <pid>");
            System.exit(2);
        }
        outDir = Paths.get(a[0]);
        Files.createDirectories(outDir);
        long sec = 10;
        try { sec = Math.max(1, Long.parseLong(a[1])); } catch (NumberFormatException e) { sec = 10; }
        intervalMs = sec * 1000;
        groupMs = Math.min(2000, intervalMs / 2);
        gcDelayMs = Math.min(1000, groupMs / 2);
        if (stream) runStream(Paths.get(a[2]), a[3]);
        else runBatch(Arrays.copyOfRange(a, 2, a.length));
    }

    // ---- convert recordings (after the test)
    static void runBatch(String[] roots) throws IOException {
        List<String[]> sel = pick(roots);
        if (sel.isEmpty()) {
            System.err.println("no .jfr files found");
            System.exit(1);
        }
        gcOut = open("jfr_gc.csv", false);
        heapOut = open("jfr_heap.csv", false);
        line(gcOut, GC_H);
        line(heapOut, HEAP_H);
        String cur = null;
        for (String[] f : sel) {
            if (!f[1].equals(cur)) {
                if (cur != null) endJvm();
                startJvm(f[1]);
                cur = f[1];
            }
            readFile(Paths.get(f[0]));
        }
        if (cur != null) endJvm();
        gcOut.close();
        heapOut.close();
        writeEnv();
        writeSummary(null, "converted");
        System.out.println("files=" + sel.size() + " events=" + total() + " out=" + outDir);
    }

    static void readFile(Path f) {
        long before = total();
        String status = "ok";
        try (EventStream es = EventStream.openFile(f)) {
            es.onEvent(PerfJfrCsv::handleSafe);
            es.start();
        } catch (Throwable t) {
            status = (total() > before ? "partial: " : "error: ") + t.getClass().getSimpleName() + " " + String.valueOf(t.getMessage());
        }
        FILES.add(new String[] { f.toString(), String.valueOf(fsize(f)), String.valueOf(total() - before), status });
    }

    // ---- follow a running JVM (during the test)
    static void runStream(Path repo, String target) throws Exception {
        live = true;
        startJvm(target);
        resume();
        gcOut = openAppend("jfr_gc.csv", GC_H);
        heapOut = openAppend("jfr_heap.csv", HEAP_H);
        long tpid = Long.parseLong(target);
        String status = "stream";
        try (EventStream es = EventStream.openRepository(repo)) {
            es.setStartTime(Instant.EPOCH);
            es.onEvent(PerfJfrCsv::handleSafe);
            es.onFlush(PerfJfrCsv::onFlush);
            Thread w = new Thread(() -> watch(tpid, es), "perf-jfr-watch");
            w.setDaemon(true);
            w.start();
            es.start();
        } catch (Throwable t) {
            status = "stream stopped: " + t.getClass().getSimpleName() + " " + String.valueOf(t.getMessage());
            System.err.println(status);
        }
        endJvm();
        gcOut.close();
        heapOut.close();
        writeEnv();
        writeSummary(repo, status);
        System.out.println("stream ended: events=" + total());
    }

    // close the stream a little after the JVM ended (its last chunk is written at exit)
    static void watch(long tpid, EventStream es) {
        try {
            while (ProcessHandle.of(tpid).map(ProcessHandle::isAlive).orElse(false)) Thread.sleep(2000);
            Thread.sleep(5000);
        } catch (InterruptedException e) { /* closing anyway */ }
        es.close();
    }

    static void onFlush() {
        long now = System.currentTimeMillis();
        if (envDirty && now - envWritten > 5000) writeEnv();
        if (now - summaryWritten > 60000) writeSummary(null, "stream");
    }

    // skip what an earlier run of the stream already wrote for this JVM
    static void resume() {
        String[] g = lastRow(outDir.resolve("jfr_gc.csv"));
        if (g != null && g.length > 4 && g[3].equals(pid)) skipGcId = parseLong(g[4], -1);
        String[] h = lastRow(outDir.resolve("jfr_heap.csv"));
        if (h != null && h.length > 3 && h[3].equals(pid)) skipTickMs = parseLong(h[2], -1);
    }

    static void startJvm(String p) {
        pid = p == null ? "" : p;
        clock = Long.MIN_VALUE;
        GCS.clear(); FINISHED.clear(); DONE.clear();
        tick = null; prevTickMs = -1; prevAlloc = null;
    }

    static void endJvm() {
        settle(true);
        DONE.clear();
    }

    // ---- events
    static void handleSafe(RecordedEvent e) {
        try { handle(e); } catch (RuntimeException ex) { /* one bad event must not stop the rest */ }
    }

    static void handle(RecordedEvent e) {
        String type = e.getEventType().getName();
        Instant st = e.getStartTime();
        long endMs = e.getEndTime().toEpochMilli();
        long[] c = TYPES.computeIfAbsent(type, k -> new long[] { 0, Long.MAX_VALUE, Long.MIN_VALUE });
        c[0]++; c[1] = Math.min(c[1], st.getEpochSecond()); c[2] = Math.max(c[2], st.getEpochSecond());
        if (endMs > clock) clock = endMs;
        settle(false);
        Gc g;
        switch (type) {
            case "jdk.GCHeapMemoryUsage": {
                Tick t = tickAt(st.toEpochMilli());
                t.used = num(e, "used"); t.committed = num(e, "committed"); t.max = num(e, "max");
                break;
            }
            case "jdk.GCHeapMemoryPoolUsage": {
                String k = poolKind(str(e, "name"));
                if (k == null) break;
                Double u = num(e, "used"), cm = num(e, "committed");
                double[] v = tickAt(st.toEpochMilli()).pools.computeIfAbsent(k, x -> new double[] { 0, 0 });
                if (u != null) v[0] += u;
                if (cm != null) v[1] += cm;
                break;
            }
            case "jdk.ThreadAllocationStatistics": {
                Object th = val(e, "thread");
                Double al = num(e, "allocated");
                if (th instanceof RecordedThread && al != null) tickAt(st.toEpochMilli()).alloc.put(((RecordedThread) th).getId(), al.longValue());
                break;
            }
            case "jdk.GarbageCollection":
                if ((g = gc(e)) == null) break;
                g.haveGc = true; g.start = st; g.endMs = endMs;
                g.name = str(e, "name"); g.cause = str(e, "cause");
                g.sumP = ms(e, "sumOfPauses"); g.longP = ms(e, "longestPause");
                g.dur = e.getDuration().toNanos() / 1e6;
                break;
            case "jdk.GCHeapSummary":
                if ((g = gc(e)) == null) break;
                if (before(e)) g.hb = num(e, "heapUsed");
                else {
                    g.ha = num(e, "heapUsed");
                    Object hs = val(e, "heapSpace");
                    if (hs instanceof RecordedObject) g.hc = num((RecordedObject) hs, "committedSize");
                }
                break;
            case "jdk.G1HeapSummary":
                if ((g = gc(e)) == null) break;
                if (before(e)) { g.eb = num(e, "edenUsedSize"); g.sb = num(e, "survivorUsedSize"); g.ob = num(e, "oldGenUsedSize"); }
                else { g.sa = num(e, "survivorUsedSize"); g.oa = num(e, "oldGenUsedSize"); }
                break;
            case "jdk.MetaspaceSummary": {
                if ((g = gc(e)) == null) break;
                Object m = val(e, "metaspace");
                if (!(m instanceof RecordedObject)) break;
                if (before(e)) g.mtb = num((RecordedObject) m, "used");
                else { g.mta = num((RecordedObject) m, "used"); g.mtc = num((RecordedObject) m, "committed"); }
                break;
            }
            case "jdk.GCCPUTime":
                if ((g = gc(e)) == null) break;
                g.cu = nanosMs(e, "userTime"); g.cs = nanosMs(e, "systemTime"); g.cr = nanosMs(e, "realTime");
                break;
            case "jdk.G1GarbageCollection":
                if ((g = gc(e)) != null) g.g1Type = str(e, "type");
                break;
            case "jdk.YoungGarbageCollection": {
                if ((g = gc(e)) == null) break;
                Double tt = num(e, "tenuringThreshold");
                if (tt != null) g.tenuring = tt.intValue();
                break;
            }
            case "jdk.EvacuationFailed":
            case "jdk.PromotionFailed":
                if ((g = gc(e)) != null) g.failed = true;
                break;
            case "jdk.SystemGC":
                SYSGC.merge(site(e), 1L, Long::sum);
                break;
            case "jdk.GCConfiguration":
                env("gc", e, "youngCollector", "oldCollector", "parallelGCThreads", "concurrentGCThreads", "usesDynamicGCThreads",
                        "isExplicitGCConcurrent", "isExplicitGCDisabled", "pauseTarget", "gcTimeRatio");
                break;
            case "jdk.GCHeapConfiguration":
                env("heap", e, "minSize", "maxSize", "initialSize", "usesCompressedOops", "compressedOopsMode", "objectAlignment", "heapAddressBits");
                break;
            case "jdk.YoungGenerationConfiguration": env("young", e, "minSize", "maxSize", "newRatio"); break;
            case "jdk.GCSurvivorConfiguration": env("survivor", e, "maxTenuringThreshold", "initialTenuringThreshold"); break;
            case "jdk.GCTLABConfiguration": env("tlab", e, "usesTLABs", "minTLABSize", "tlabRefillWasteLimit"); break;
            case "jdk.ContainerConfiguration":
                env("container", e, "containerType", "cpuSlicePeriod", "cpuQuota", "cpuShares", "effectiveCpuCount", "memorySoftLimit",
                        "memoryLimit", "swapMemoryLimit", "hostTotalMemory");
                break;
            case "jdk.CPUInformation": env("cpu", e, "cpu", "sockets", "cores", "hwThreads"); break;
            case "jdk.CompilerConfiguration": env("compiler", e, "threadCount", "tieredCompilation", "dynamicCompilerThreadCount"); break;
            case "jdk.JVMInformation": {
                Double p = num(e, "pid");
                if (pid.isEmpty() && p != null) pid = String.valueOf(p.longValue());
                env("jvm", e, "jvmName", "jvmVersion", "pid", "jvmStartTime", "jvmFlags", "jvmArguments", "javaArguments");
                break;
            }
            case "jdk.OSInformation": env("os", e, "osVersion"); break;
            case "jdk.VirtualizationInformation": put("os", "virtualization", envValue(e, "name")); break;
            default: break;
        }
    }

    static Gc gc(RecordedEvent e) {
        Double d = num(e, "gcId");
        if (d == null) return null;
        long id = d.longValue();
        if (FINISHED.contains(id)) return null;
        Gc g = GCS.get(id);
        if (g == null) { g = new Gc(id); GCS.put(id, g); }
        g.lastMs = clock;
        return g;
    }

    // one periodic sample = the periodic events emitted together (within groupMs)
    static Tick tickAt(long t) {
        if (tick != null && Math.abs(t - tick.t) <= groupMs) return tick;
        if (tick != null) finishTick();
        tick = new Tick(t);
        return tick;
    }

    // finish GCs and samples whose related events have all arrived
    static void settle(boolean all) {
        Iterator<Gc> it = GCS.values().iterator();
        while (it.hasNext()) {
            Gc g = it.next();
            boolean ready = g.haveGc ? (all || clock - g.endMs > gcDelayMs) : (all || clock - g.lastMs > 60000);
            if (!ready) continue;
            it.remove();
            FINISHED.add(g.id);
            if (g.haveGc) finishGc(g);
        }
        if (FINISHED.size() > 5000) FINISHED.clear();
        if (tick != null && (all || clock - tick.t > groupMs)) finishTick();
    }

    static void finishGc(Gc g) {
        DONE.add(g);
        if (g.id <= skipGcId) return;
        Instant at = g.start;
        line(gcOut, ts(at.getEpochSecond()) + "," + at.getEpochSecond() + "," + at.toEpochMilli() + "," + pid + "," + g.id
                + "," + q(g.name) + "," + q(g.cause) + "," + q(g.g1Type) + "," + n(g.sumP) + "," + n(g.longP) + "," + n(g.dur)
                + "," + mb(g.hb) + "," + mb(g.ha) + "," + mb(g.hc) + "," + mb(g.eb) + "," + mb(g.sb) + "," + mb(g.sa) + "," + mb(g.ob) + "," + mb(g.oa)
                + "," + mb(g.mtb) + "," + mb(g.mta) + "," + mb(g.mtc) + "," + n(g.cu) + "," + n(g.cs) + "," + n(g.cr)
                + "," + (g.tenuring == null ? "" : String.valueOf(g.tenuring)) + "," + (g.failed ? "1" : ""));
    }

    static void finishTick() {
        Tick t = tick;
        tick = null;
        if (t == null) return;
        // allocation: per thread, the increase of the bytes allocated since the previous sample
        Double alloc = null;
        if (!t.alloc.isEmpty()) {
            if (prevAlloc != null) {
                long sum = 0;
                for (Map.Entry<Long, Long> en : t.alloc.entrySet()) {
                    long d = en.getValue() - prevAlloc.getOrDefault(en.getKey(), 0L);
                    if (d > 0) sum += d;
                }
                alloc = (double) sum;
            }
            prevAlloc = t.alloc;
        }
        // GCs that ended since the previous sample
        int count = 0, full = 0;
        double pause = 0, pauseMax = 0, cpu = 0;
        boolean anyCpu = false;
        Gc last = null;
        Iterator<Gc> it = DONE.iterator();
        while (it.hasNext()) {
            Gc g = it.next();
            if (g.endMs > t.t) continue;
            it.remove();
            count++;
            if (g.name != null && FULL.contains(g.name)) full++;
            if (g.sumP != null) pause += g.sumP;
            if (g.longP != null) pauseMax = Math.max(pauseMax, g.longP);
            if (g.cu != null || g.cs != null) { anyCpu = true; cpu += (g.cu == null ? 0 : g.cu) + (g.cs == null ? 0 : g.cs); }
            if (g.ha != null && (last == null || g.endMs >= last.endMs)) last = g;
        }
        long prev = prevTickMs;
        prevTickMs = t.t;
        if (t.t <= skipTickMs) return;
        double dt = prev > 0 ? (t.t - prev) / 1000.0 : 0;
        double[] eden = t.pools.get("eden"), surv = t.pools.get("survivor"), old = t.pools.get("old");
        long s = t.t / 1000;
        line(heapOut, ts(s) + "," + s + "," + t.t + "," + pid + "," + mb(t.used) + "," + mb(t.committed) + "," + mb(t.max)
                + "," + (eden == null ? "," : mb(eden[0]) + "," + mb(eden[1])) + "," + (surv == null ? "," : mb(surv[0]) + "," + mb(surv[1]))
                + "," + (old == null ? "," : mb(old[0]) + "," + mb(old[1]))
                + "," + mb(alloc) + "," + (alloc != null && dt > 0 ? n(alloc / MB / dt) : "")
                + "," + count + "," + full + "," + n(pause) + "," + (count > 0 ? n(pauseMax) : "") + "," + (anyCpu ? n(cpu) : "")
                + "," + (last == null ? "" : mb(last.ha)) + "," + (last == null ? "" : mb(last.oa)));
    }

    // ---- value helpers (a missing field returns null, so one JDK version difference does not break the rest)
    static Object val(RecordedObject e, String f) { return e.hasField(f) ? e.getValue(f) : null; }
    static Double num(RecordedObject e, String f) {
        Object v = val(e, f);
        if (v instanceof Number) {
            double d = ((Number) v).doubleValue();
            long l = ((Number) v).longValue();
            if (l == Long.MIN_VALUE || l == Long.MAX_VALUE) return null;
            return d;
        }
        if (v instanceof Boolean) return ((Boolean) v) ? 1.0 : 0.0;
        return null;
    }
    static String str(RecordedObject e, String f) { Object v = val(e, f); return v == null ? null : String.valueOf(v); }
    static boolean before(RecordedObject e) { String w = str(e, "when"); return w != null && w.startsWith("Before"); }
    // @Timespan fields: getValue returns the raw number, getDuration converts it with its unit
    static Double ms(RecordedObject e, String f) {
        if (!e.hasField(f)) return null;
        try {
            Duration d = e.getDuration(f);
            if (d.getSeconds() == Long.MIN_VALUE || d.getSeconds() == Long.MAX_VALUE) return null;
            return d.toNanos() / 1e6;
        } catch (RuntimeException ex) { return null; }
    }
    // GC CPU time fields are nanoseconds (with or without the @Timespan annotation)
    static Double nanosMs(RecordedObject e, String f) {
        Double d = ms(e, f);
        if (d != null) return d;
        Double v = num(e, f);
        return v == null ? null : v / 1e6;
    }
    static String poolKind(String n) {
        if (n == null) return null;
        String s = n.toLowerCase(Locale.ROOT);
        if (s.contains("eden")) return "eden";
        if (s.contains("survivor")) return "survivor";
        if (s.contains("old") || s.contains("tenured")) return "old";
        return null;
    }
    static String method(RecordedFrame fr) {
        RecordedMethod m = fr.getMethod();
        if (m == null) return "(unknown)";
        RecordedClass c = m.getType();
        return (c == null ? "" : c.getName() + ".") + m.getName();
    }
    // The first frame that is not in the JDK itself (the caller of System.gc() in the application or JBoss).
    static String site(RecordedEvent e) {
        RecordedStackTrace st = e.getStackTrace();
        if (st == null || st.getFrames().isEmpty()) return "(no stack trace)";
        String first = null;
        for (RecordedFrame fr : st.getFrames()) {
            String m = method(fr);
            if (first == null) first = m;
            if (!(m.startsWith("java.") || m.startsWith("jdk.") || m.startsWith("sun.") || m.startsWith("javax."))) return m;
        }
        return first;
    }
    static ValueDescriptor field(RecordedObject e, String f) {
        for (ValueDescriptor d : e.getFields()) if (d.getName().equals(f)) return d;
        return null;
    }
    static String envValue(RecordedEvent e, String f) {
        Object v = val(e, f);
        if (v == null) return null;
        if (v instanceof Number) {
            long l = ((Number) v).longValue();
            if (l == Long.MIN_VALUE || l == Long.MAX_VALUE) return null;
            ValueDescriptor d = field(e, f);
            if (d != null && d.getAnnotation(Timespan.class) != null) {
                if (l < 0) return String.valueOf(l);
                Double m = ms(e, f);
                if (m != null) return n(m) + " ms";
            }
        }
        if (f.equals("jvmStartTime")) {
            try { return ts(e.getInstant(f).getEpochSecond()); } catch (RuntimeException ex) { /* keep the raw value */ }
        }
        String s = String.valueOf(v);
        if (f.equals("jvmArguments") || f.equals("jvmFlags") || f.equals("javaArguments")) s = MASK.matcher(s).replaceAll("$1********");
        return s;
    }
    static void env(String cat, RecordedEvent e, String... fields) {
        for (String f : fields) put(cat, f, envValue(e, f));
    }
    static void put(String cat, String key, String value) {
        if (value == null) return;
        String k = cat + "\t" + key;
        if (!value.equals(ENV.get(k))) { ENV.put(k, value); envDirty = true; }
    }

    // ---- output
    static String q(String s) {
        if (s == null) return "";
        if (s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")) return "\"" + s.replace("\"", "\"\"") + "\"";
        return s;
    }
    static String n(Double d) {
        if (d == null || d.isNaN() || d.isInfinite()) return "";
        if (d == Math.rint(d) && Math.abs(d) < 1e15) return String.valueOf(d.longValue());
        return String.format(Locale.ROOT, "%.3f", d);
    }
    static String n(double d) { return n(Double.valueOf(d)); }
    static String mb(Double b) { return b == null ? "" : n(b / MB); }
    static String mb(double b) { return n(b / MB); }
    static String ts(long ep) { return TS.format(Instant.ofEpochSecond(ep).atZone(ZONE)); }
    static long total() { long s = 0; for (long[] v : TYPES.values()) s += v[0]; return s; }
    static long fsize(Path f) { try { return Files.size(f); } catch (IOException e) { return -1; } }
    static long parseLong(String s, long d) { try { return Long.parseLong(s.trim()); } catch (RuntimeException e) { return d; } }
    static PrintWriter open(String name, boolean append) throws IOException {
        OutputStream o = append ? Files.newOutputStream(outDir.resolve(name), StandardOpenOption.CREATE, StandardOpenOption.APPEND)
                : Files.newOutputStream(outDir.resolve(name));
        return new PrintWriter(new BufferedWriter(new OutputStreamWriter(o, StandardCharsets.UTF_8)));
    }
    static PrintWriter openAppend(String name, String header) throws IOException {
        Path p = outDir.resolve(name);
        boolean empty = !Files.exists(p) || Files.size(p) == 0;
        PrintWriter w = open(name, true);
        if (empty) line(w, header);
        return w;
    }
    static void line(PrintWriter w, String s) {
        w.print(s);
        w.print("\n");
        if (live) w.flush();
    }
    // the last data row of a CSV (only the first columns are used: they are never quoted)
    static String[] lastRow(Path p) {
        try (RandomAccessFile f = new RandomAccessFile(p.toFile(), "r")) {
            long len = f.length();
            if (len == 0) return null;
            long from = Math.max(0, len - 65536);
            byte[] b = new byte[(int) (len - from)];
            f.seek(from);
            f.readFully(b);
            String[] lines = new String(b, StandardCharsets.UTF_8).split("\n");
            for (int i = lines.length - 1; i >= 0; i--) {
                String l = lines[i].trim();
                if (l.isEmpty() || l.startsWith("timestamp,")) continue;
                return l.split(",", -1);
            }
        } catch (IOException e) { /* no previous rows */ }
        return null;
    }
    static void replace(String name, List<String> rows) {
        try {
            Path tmp = outDir.resolve("." + name + ".tmp");
            Files.write(tmp, (String.join("\n", rows) + "\n").getBytes(StandardCharsets.UTF_8));
            try { Files.move(tmp, outDir.resolve(name), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
            catch (IOException e) { Files.move(tmp, outDir.resolve(name), StandardCopyOption.REPLACE_EXISTING); }
        } catch (IOException e) { System.err.println("cannot write " + name + ": " + e); }
    }
    static void writeEnv() {
        List<String> rows = new ArrayList<>();
        rows.add("category,key,value");
        for (Map.Entry<String, String> en : ENV.entrySet()) {
            String[] k = en.getKey().split("\t", 2);
            rows.add(q(k[0]) + "," + q(k[1]) + "," + q(en.getValue()));
        }
        replace("jfr_env.csv", rows);
        envDirty = false;
        envWritten = System.currentTimeMillis();
    }
    static void writeSummary(Path repo, String status) {
        List<String> rows = new ArrayList<>();
        rows.add("kind,name,count,first,last,detail");
        for (String[] f : FILES) rows.add("file," + q(f[0]) + "," + f[2] + ",,," + q("bytes=" + f[1] + " " + f[3]));
        if (repo != null || live) rows.add("stream," + q(repo == null ? "" : repo.toString()) + "," + total() + ",,," + q(status + " pid=" + pid + " updated=" + ts(System.currentTimeMillis() / 1000)));
        for (Map.Entry<String, long[]> en : TYPES.entrySet())
            rows.add("event," + q(en.getKey()) + "," + en.getValue()[0] + "," + ts(en.getValue()[1]) + "," + ts(en.getValue()[2]) + ",");
        for (Map.Entry<String, Long> en : SYSGC.entrySet()) rows.add("system-gc," + q(en.getKey()) + "," + en.getValue() + ",,,");
        replace("jfr_summary.csv", rows);
        summaryWritten = System.currentTimeMillis();
    }

    // Select the recordings to read. For each JVM (pid) use the dump written at exit when it exists
    // (it contains every chunk), otherwise the newest dump taken with perf-metrics.sh jfr-dump, otherwise
    // the chunks left in the repository. JVMs are read in the order they started.
    static List<String[]> pick(String[] roots) throws IOException {
        Map<String, List<Path>> exits = new HashMap<>(), demands = new HashMap<>(), chunks = new HashMap<>();
        Map<String, Long> firstSeen = new HashMap<>();
        List<Path> others = new ArrayList<>();
        for (String r : roots) {
            Path p = Paths.get(r);
            if (!Files.exists(p)) continue;
            List<Path> all = new ArrayList<>();
            if (Files.isDirectory(p)) {
                try (java.util.stream.Stream<Path> s = Files.walk(p)) {
                    s.filter(x -> Files.isRegularFile(x) && x.getFileName().toString().endsWith(".jfr")).forEach(all::add);
                }
            } else all.add(p);
            for (Path f : all) {
                String name = f.getFileName().toString();
                Path parent = f.getParent();
                String pname = parent == null || parent.getFileName() == null ? "" : parent.getFileName().toString();
                Matcher ex = EXIT_DUMP.matcher(name), de = DEMAND_DUMP.matcher(name), rd = REPO_DIR.matcher(pname);
                String id;
                if (de.matches()) { id = de.group(1); demands.computeIfAbsent(id, k -> new ArrayList<>()).add(f); }
                else if (ex.matches()) { id = ex.group(1); exits.computeIfAbsent(id, k -> new ArrayList<>()).add(f); }
                else if (rd.matches()) { id = rd.group(1); chunks.computeIfAbsent(id, k -> new ArrayList<>()).add(f); }
                else { others.add(f); continue; }
                long t = mtime(f);
                firstSeen.merge(id, t, Math::min);
            }
        }
        List<String> pids = new ArrayList<>(firstSeen.keySet());
        pids.sort(Comparator.comparing((String x) -> firstSeen.get(x)).thenComparing(x -> x));
        List<String[]> sel = new ArrayList<>();
        for (String id : pids) {
            List<Path> l;
            if (exits.containsKey(id)) l = exits.get(id);
            else if (demands.containsKey(id)) {
                l = new ArrayList<>(demands.get(id));
                l.sort(Comparator.comparing(PerfJfrCsv::mtime));
                l = Collections.singletonList(l.get(l.size() - 1));
            } else l = chunks.get(id);
            List<Path> s2 = new ArrayList<>(l);
            Collections.sort(s2);
            for (Path f : s2) sel.add(new String[] { f.toString(), id });
        }
        Collections.sort(others);
        for (Path f : others) sel.add(new String[] { f.toString(), "" });
        return sel;
    }
    static long mtime(Path f) { try { return Files.getLastModifiedTime(f).toMillis(); } catch (IOException e) { return Long.MAX_VALUE; } }
}'

# 変換プログラムを作業ディレクトリ (無ければ出力先の jfr/) に書き、そのパスを出す
pm_jfr_src() {
    for _pm_d in "${PM_W:-}" "${PM_JFR_DIR:-}" /tmp; do
        [ -n "${_pm_d}" ] && [ -d "${_pm_d}" ] || continue
        if printf '%s\n' "${PM_JFR_JAVA}" > "${_pm_d}/PerfJfrCsv.java" 2>/dev/null; then
            printf '%s' "${_pm_d}/PerfJfrCsv.java"
            return 0
        fi
    done
    return 1
}

# JBoss の JVM が書いている JFR のリポジトリ (<日時>_<pid>) を追いかけて CSV にする
pm_run_jfr() {
    PM_NAME=jfr
    trap 'exit 0' TERM INT
    [ "${PERF_JFR}" = "true" ] || exit 0
    case "${PM_JFR_MODE}" in
        startup|jcmd) ;;
        *) pm_log INFO "② JFR: 記録方法が ${PM_JFR_MODE} のため収集中の CSV 化は行いません (記録があれば試験の後に perf-metrics.sh jfr-csv)"; exit 0 ;;
    esac
    pm_wait_jboss || exit 0
    _pm_java="$(pm_java_of_jboss)" || { pm_log WARN "② JFR: java が見つからないため CSV 化を行いません"; exit 0; }
    _pm_src="$(pm_jfr_src)" || { pm_log WARN "② JFR: 変換プログラムを書き出せないため CSV 化を行いません"; exit 0; }
    _pm_nice=""
    command -v nice > /dev/null 2>&1 && _pm_nice="nice -n 10"
    pm_log INFO "② JFR: 記録を CSV にします (${PERF_JFR_INTERVAL} 秒間隔 = jfr_heap.csv、GC ごと = jfr_gc.csv、${PM_JFR_DIR}/repo)"
    _pm_fails=0
    while :; do
        pm_jboss_alive || PM_JPID="$(pm_find_jboss_pid)" || { sleep 5; continue; }
        # JVM が JFR を始めると、リポジトリに <日時>_<pid> のディレクトリができる
        _pm_repo=""; _pm_waited=0
        while pm_jboss_alive; do
            for _pm_d in "${PM_JFR_DIR}/repo/"*_"${PM_JPID}"; do
                [ -d "${_pm_d}" ] && _pm_repo="${_pm_d}"
            done
            [ -n "${_pm_repo}" ] && break
            _pm_waited=$((_pm_waited + 5))
            [ "${_pm_waited}" = 300 ] && pm_warn_once "jfrrepo${PM_JPID}" "② JFR: 記録のリポジトリ (${PM_JFR_DIR}/repo/*_${PM_JPID}) が 300 秒たってもできません。JFR が動いていない可能性があります (perf-metrics.sh status で確認)"
            sleep 5
        done
        [ -n "${_pm_repo}" ] || continue
        pm_log INFO "② JFR: ${_pm_repo} の CSV 化を始めます (pid=${PM_JPID})"
        # shellcheck disable=SC2086
        ( unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS
          exec ${_pm_nice} "${_pm_java}" -Dperf.metrics.collector=jfr -Xms16m "-Xmx${PERF_JFR_HEAP}" -XX:+UseSerialGC -XX:TieredStopAtLevel=1 \
              -XX:-UsePerfData -Xss512k "${_pm_src}" --stream "${PM_OUT}" "${PERF_JFR_INTERVAL}" "${_pm_repo}" "${PM_JPID}" ) >> "${PM_W}/jfr.log" 2>&1 &
        _pm_jp=$!
        echo "${_pm_jp}" > "${PM_W}/jfr-stream.pid" 2>/dev/null
        wait "${_pm_jp}"
        _pm_rc=$?
        if pm_jboss_alive; then
            _pm_fails=$((_pm_fails + 1))
            if [ "${_pm_fails}" -ge 5 ]; then
                pm_log WARN "② JFR の CSV 化が続けて止まったため、収集中の CSV 化をやめます。試験の後に perf-metrics.sh jfr-csv で変換してください (詳細: ${PM_W}/jfr.log)"
                exit 0
            fi
            pm_log WARN "② JFR の CSV 化が止まりました (rc=${_pm_rc})。60 秒後に続きから再開します (詳細: ${PM_W}/jfr.log)"
            sleep 60
        else
            pm_log INFO "② JFR: JBoss の JVM (pid=${PM_JPID}) が終了したため、この記録の CSV 化を終えました"
        fi
    done
}

# 試験の後の変換 (perf-metrics.sh jfr-csv)。JBoss が動いていれば、先に記録を書き出す (jfr-dump)。
pm_jfr_csv() {
    _pm_dir="${1:-${PM_JFR_DIR:-${PM_OUT}/jfr}}"
    if pm_collector_running jfr; then
        echo "JFR は収集中に CSV (jfr_heap.csv・jfr_gc.csv) へ書いています。記録全体から作り直すときは perf-metrics.sh stop の後に実行してください"
        return 1
    fi
    PM_JPID="$(pm_find_jboss_pid)" || PM_JPID=""
    if [ -n "${PM_JPID}" ] && pm_resolve_tool jcmd && [ -d "${_pm_dir}" ]; then
        mkdir -p "${_pm_dir}/dump" 2>/dev/null
        pm_tool_exec "${PM_JPID}" JFR.dump name=perf-metrics "filename=${_pm_dir}/dump/perf_dump_%p_%t.jfr" > /dev/null 2>&1 \
            && echo "JBoss が動いているため、記録を書き出しました (${_pm_dir}/dump/)"
    fi
    _pm_cnt="$(find "${_pm_dir}" -name '*.jfr' -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${_pm_cnt:-0}" = 0 ]; then
        echo "JFR のファイルがありません (${_pm_dir})。JBoss の終了時に perf_<pid>_<日時>.jfr が書かれ、記録中は repo/ にチャンクがあります (jfr-dump でも作れます)"
        return 1
    fi
    _pm_java="$(pm_java_of_jboss)" || { echo "java が見つかりません"; return 1; }
    _pm_src="$(pm_jfr_src)" || { echo "変換プログラムを書き出せません"; return 1; }
    echo "JFR を CSV に変換しています (${_pm_cnt} ファイル、${_pm_dir} → ${PM_OUT})..."
    # 収集中の CPU を奪わないよう優先度を下げる (性能試験の後に実行することを推奨)
    _pm_nice=""
    command -v nice >/dev/null 2>&1 && _pm_nice="nice -n 19"
    # shellcheck disable=SC2086
    ( unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS
      exec ${_pm_nice} "${_pm_java}" -Dperf.metrics.collector=jfr-csv -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xmx512m -XX:-UsePerfData \
          "${_pm_src}" "${PM_OUT}" "${PERF_JFR_INTERVAL}" "${_pm_dir}" ) 2>&1
}

# =============================================================================
# ③ -XX:ActiveProcessorCount の要否 (判断材料と判定・CPU の使われ方)
# =============================================================================
# ---- JSON (ECS タスクメタデータ) を「パス<TAB>値」の行にする小さな解析器 ----
PM_JSON_AWK='
function skipws(    c) { while (i <= n) { c = substr(buf, i, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") i++; else break } }
function pstr(    s, c, e) {
  s = ""; i++
  while (i <= n) {
    c = substr(buf, i, 1)
    if (c == "\\") { e = substr(buf, i + 1, 1); if (e == "u") { s = s "?"; i += 6; continue } if (e == "n" || e == "t" || e == "r") s = s " "; else s = s e; i += 2; continue }
    if (c == "\"") { i++; return s }
    s = s c; i++
  }
  return s
}
function pval(p,    c, k, idx, s) {
  skipws(); c = substr(buf, i, 1)
  if (c == "{") {
    i++; skipws(); if (substr(buf, i, 1) == "}") { i++; return }
    while (i <= n) {
      skipws(); if (substr(buf, i, 1) != "\"") return
      k = pstr(); skipws(); i++
      pval(p == "" ? k : p "." k)
      skipws(); c = substr(buf, i, 1); i++
      if (c != ",") return
    }
    return
  }
  if (c == "[") {
    i++; skipws(); if (substr(buf, i, 1) == "]") { i++; return }
    idx = 0
    while (i <= n) {
      pval(p "." idx); idx++
      skipws(); c = substr(buf, i, 1); i++
      if (c != ",") return
    }
    return
  }
  if (c == "\"") { print p "\t" pstr(); return }
  s = ""
  while (i <= n) { c = substr(buf, i, 1); if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\r" || c == "\n") break; s = s c; i++ }
  print p "\t" s
}
{ buf = buf $0 "\n" }
END { n = length(buf); i = 1; pval("") }
'

# サイドカー (JVM を動かさないと分かっているコンテナ) の名前・イメージの目印
PM_SIDECAR_RE='cloudwatch-agent|cwagent|aws-otel|adot|otel-collector|fluent|firelens|log_router|envoy|appmesh|xray|datadog|newrelic|ecs-exec|ssm-agent'

# ③ の判定 (pm_cpu_env から呼ぶ。単体試験でも使う)
#   入力: tcpu=タスクの vCPU ccpu=コンテナの CPU ユニット napp=JVM のコンテナ数 q=クォータ (コア)
#         apc=ActiveProcessorCount eff=JVM が認識した CPU 数 gc=選ばれた GC gco=その由来
#   出力: 結果<TAB>推奨値<TAB>取り分 (vCPU)<TAB>説明
PM_JUDGE_AWK='
  function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }
  BEGIN {
    share = ""; how = ""
    # コンテナの cpu が未指定でも、ECS は最小のシェア (2 など) を入れることがあるため 64 未満は未指定と見なす
    if (ccpu + 0 >= 64) { share = ccpu / 1024; how = "コンテナ定義の cpu " ccpu " ユニット" }
    else if (tcpu + 0 > 0) { n = (napp + 0 > 0) ? napp : 1; share = tcpu / n; how = "タスクの " tcpu " vCPU を JVM のコンテナ " n " 個で分けた値" }
    else if (q + 0 > 0) { share = q; how = "cgroup のクォータ" }
    rec = ""
    if (share != "") { rec = int(share + 0.5); if (rec < 1) rec = 1; share = sprintf("%.2f", share); sub(/\.?0+$/, "", share) }
    r = ""; msg = ""
    if (apc + 0 > 0) {
      r = "設定済み"; msg = "-XX:ActiveProcessorCount=" apc " が指定されています"
      if (tcpu + 0 > 0 && apc > ceil(tcpu)) { r = "要確認"; msg = msg "。タスクの vCPU (" tcpu ") を超えています" }
      else if (rec != "" && apc != rec) msg = msg "。取り分の目安は " rec " (" how ")"
    } else if (eff == "") {
      r = "判定不可"; msg = "JVM が認識した CPU 数を取得できません"
    } else if (rec == "") {
      r = "判定不可"; msg = "ECS メタデータ・クォータが無く、割り当てられた CPU が分かりません (JVM は " eff " CPU と認識)"
    } else if (eff + 0 > rec + 0) {
      r = "要"; msg = "JVM は CPU を " eff " 個と認識していますが、このコンテナの取り分は約 " share " vCPU (" how ") です"
      if (q == "") msg = msg "。cgroup に CPU の上限 (クォータ) が無いため、JVM はタスクの VM の CPU 数をそのまま使います"
      msg = msg "。GC・JIT・Undertow (I/O・タスク) などのスレッド数が " eff " CPU 前提で作られるため、-XX:ActiveProcessorCount=" rec " の指定を推奨します"
      if (napp + 0 > 1 && ccpu + 0 < 64) msg = msg "。同じタスクの他の JVM のコンテナも同じ CPU 数を前提にします"
    } else if (eff + 0 == rec + 0) {
      r = "不要"; msg = "JVM の認識 (" eff " CPU) と取り分 (約 " share " vCPU、" how ") が一致しています"
    } else {
      r = "要検討"; msg = "JVM の認識 (" eff " CPU) が取り分 (約 " share " vCPU) より少ないため、-XX:ActiveProcessorCount=" rec " で増やせます"
    }
    if (eff + 0 == 1 && gc == "Serial" && gco ~ /ergonomic/) msg = msg "。CPU 1 と判定されたため SerialGC が自動で選ばれています (2 以上で G1)。ActiveProcessorCount=2 または -XX:+UseG1GC の明示を検討してください"
    printf "%s\t%s\t%s\t%s\n", r, rec, share, msg
  }
'

# ③ -XX:ActiveProcessorCount の判断材料を集めて cpu_env.csv に書き、判定する (JVM ごとに 1 回)。
# JVM へアタッチできるまでは何も書かずに 1 を返す (PM_CPU_NOJCMD=1 ならアタッチせずに書く)。
pm_cpu_env() {
    _pm_jok=0
    if [ -z "${PM_CPU_NOJCMD:-}" ] && [ -n "${PM_TOOL_BIN}${PM_TOOL_MAIN}" ]; then
        pm_jcmd_run "${PM_W}/flags.all" VM.flags -all || return 1
        _pm_jok=1
    fi
    _pm_f="${PM_W}/cpu_env.part"
    : > "${_pm_f}"
    pm_now
    _pm_pre="${PM_TS},${PM_EPOCH},${PM_JPID}"
    _pm_cr() {  # category key value [note]
        printf '%s,%s,%s,"%s","%s"\n' "${_pm_pre}" "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ' | sed 's/"/""/g')" "$(printf '%s' "${4:-}" | tr '\n' ' ' | sed 's/"/""/g')" >> "${_pm_f}"
    }
    # ---- ECS (タスク定義で割り当てた CPU) ----
    _pm_tcpu=""; _pm_ccpu=""; _pm_napp=""; _pm_clist=""
    if pm_ecs_fetch; then
        _pm_tcpu="$(pm_jget "${PM_ECS_TASK}" Limits.CPU)"
        _pm_cname="$(pm_jget "${PM_ECS_CONT}" Name)"
        _pm_ccpu="$(pm_jget "${PM_ECS_CONT}" Limits.CPU)"
        _pm_cr ecs launch_type "$(pm_jget "${PM_ECS_TASK}" LaunchType)" ""
        _pm_cr ecs task_cpu_vcpu "${_pm_tcpu}" "タスク定義の cpu (vCPU 単位。1 vCPU = 1024 CPU ユニット)"
        _pm_cr ecs task_memory_mib "$(pm_jget "${PM_ECS_TASK}" Limits.Memory)" ""
        _pm_cr ecs container_name "${_pm_cname}" ""
        _pm_cr ecs container_cpu_units "${_pm_ccpu}" "コンテナ定義の cpu (CPU ユニット)。空欄・64 未満は未指定と見なす"
        _pm_cr ecs container_memory_mib "$(pm_jget "${PM_ECS_CONT}" Limits.Memory)" ""
        # タスク内のコンテナ (Type=NORMAL) と、そのうち JVM を動かすと見なす数 (サイドカーを除く)
        # (1 行目 = コンテナの一覧、2 行目 = JVM を動かすと見なしたコンテナの数)
        _pm_ca="$(printf '%s\n' "${PM_ECS_TASK}" | awk -F '\t' -v re="${PM_SIDECAR_RE}" '
            $1 ~ /^Containers\.[0-9]+\./ { split($1, p, "."); i = p[2]; k = substr($1, length(p[1]) + length(p[2]) + 3); V[i, k] = $2; if (!(i in S)) { S[i] = 1; O[++n] = i } }
            END {
              for (j = 1; j <= n; j++) { i = O[j]; t = V[i, "Type"]; if (t != "" && t != "NORMAL") continue
                nm = V[i, "Name"]; im = V[i, "Image"]; side = (tolower(nm " " im) ~ re) ? "sidecar" : "app"
                if (side == "app") app++
                printf "%s(cpu=%s,mem=%s,%s);", nm, V[i, "Limits.CPU"], V[i, "Limits.Memory"], side }
              printf "\n%d\n", app + 0 }')"
        _pm_clist="$(printf '%s\n' "${_pm_ca}" | sed -n 1p)"
        _pm_napp="$(printf '%s\n' "${_pm_ca}" | sed -n 2p)"
        _pm_cr ecs containers "${_pm_clist}" "app = JVM を動かすと見なしたコンテナ、sidecar = 名前・イメージで判別したサイドカー"
    else
        _pm_cr ecs metadata "" "ECS タスクメタデータ (ECS_CONTAINER_METADATA_URI_V4) を取得できません (ECS 外での実行)"
    fi
    pm_is_uint "${PERF_JVM_CONTAINERS}" && [ "${PERF_JVM_CONTAINERS}" -gt 0 ] && _pm_napp="${PERF_JVM_CONTAINERS}"
    _pm_cr ecs jvm_containers "${_pm_napp}" "$(if [ -n "${PERF_JVM_CONTAINERS}" ]; then echo 'PERF_JVM_CONTAINERS で指定'; else echo '自動判定 (PERF_JVM_CONTAINERS で上書き可)'; fi)"
    # ---- OS から見える CPU ----
    _pm_cr os nproc "$(nproc 2>/dev/null)" "このプロセスが使える CPU 数 (sched_getaffinity)"
    _pm_cr os cpus_online "$(getconf _NPROCESSORS_ONLN 2>/dev/null)" "OS が認識しているオンラインの CPU 数 (Fargate では microVM の vCPU 数)"
    _pm_cr os cpuinfo_processors "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)" "/proc/cpuinfo"
    _pm_cr os cpu_model "$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)" ""
    _pm_cr os cpus_allowed_list "$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "/proc/${PM_JPID}/status" 2>/dev/null)" "JBoss の JVM が使える CPU (EAP の CPU 数は min(availableProcessors, この数))"
    _pm_cr os kernel "$(uname -r 2>/dev/null)" ""
    # ---- cgroup (CPU の上限 = クォータ / 比率 = シェア) ----
    _pm_q=""
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        _pm_cr cgroup version 2 ""
        _pm_cm="$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"
        _pm_cr cgroup cpu.max "${_pm_cm}" "クォータ 周期 (max = 上限なし)"
        _pm_q="$(printf '%s' "${_pm_cm}" | awk '$1 != "max" && $2 > 0 { printf "%.2f", $1 / $2 }')"
        _pm_cr cgroup cpu.weight "$(cat /sys/fs/cgroup/cpu.weight 2>/dev/null)" "比率 (シェア)。上限ではない"
        _pm_cr cgroup cpuset.cpus.effective "$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null)" ""
        _pm_cr cgroup cpu.pressure "$([ -r /sys/fs/cgroup/cpu.pressure ] && echo available || echo none)" "PSI (CPU の待ち)"
    else
        _pm_cr cgroup version 1 ""
        for _pm_g in /sys/fs/cgroup/cpu /sys/fs/cgroup/cpu,cpuacct /sys/fs/cgroup/cpuacct,cpu; do
            [ -r "${_pm_g}/cpu.cfs_quota_us" ] || continue
            _pm_qq="$(cat "${_pm_g}/cpu.cfs_quota_us" 2>/dev/null)"; _pm_pp="$(cat "${_pm_g}/cpu.cfs_period_us" 2>/dev/null)"
            _pm_cr cgroup cpu.cfs_quota_us "${_pm_qq}" "-1 = 上限なし"
            _pm_cr cgroup cpu.cfs_period_us "${_pm_pp}" ""
            _pm_cr cgroup cpu.shares "$(cat "${_pm_g}/cpu.shares" 2>/dev/null)" "比率 (シェア)。上限ではない"
            _pm_q="$(awk -v q="${_pm_qq}" -v p="${_pm_pp}" 'BEGIN { if (q > 0 && p > 0) printf "%.2f", q / p }')"
            break
        done
    fi
    _pm_cr cgroup cpu_quota_cores "${_pm_q}" "クォータから求めた CPU の上限 (空欄 = 上限なし。Fargate は CPU シェアで配分しクォータを使わない)"
    # ---- JBoss の JVM が認識した CPU 数と、それで決まったスレッド数 ----
    _pm_apc=""; _pm_eff=""; _pm_gc=""; _pm_gco=""
    if [ "${_pm_jok}" = 1 ]; then
        for _pm_k in ActiveProcessorCount UseContainerSupport ParallelGCThreads ConcGCThreads G1ConcRefinementThreads CICompilerCount UseDynamicNumberOfGCThreads UseG1GC UseSerialGC UseParallelGC UseZGC UseShenandoahGC MaxHeapSize MaxRAMPercentage InitialRAMPercentage; do
            # 例: "     int ActiveProcessorCount   = -1   {product} {default}" (由来は {command line} など空白を含む)
            _pm_l="$(awk -v k="${_pm_k}" '$2 == k { o = ""; if (match($0, /\{[^}]*\}[ ]*$/)) o = substr($0, RSTART, RLENGTH); sub(/ +$/, "", o); print $4 "\t" o; exit }' "${PM_W}/flags.all")"
            [ -n "${_pm_l}" ] || continue
            _pm_v="${_pm_l%%"${PM_TAB}"*}"; _pm_o="${_pm_l#*"${PM_TAB}"}"
            _pm_cr jvm "${_pm_k}" "${_pm_v}" "${_pm_o}"
            case "${_pm_k}" in
                ActiveProcessorCount) _pm_apc="${_pm_v}" ;;
                UseG1GC|UseSerialGC|UseParallelGC|UseZGC|UseShenandoahGC)
                    [ "${_pm_v}" = true ] && { _pm_gc="${_pm_k#Use}"; _pm_gc="${_pm_gc%GC}"; _pm_gco="${_pm_o}"; } ;;
            esac
        done
        _pm_cr jvm gc "${_pm_gc}" "${_pm_gco}"
        if pm_jcmd_run "${PM_W}/vminfo.txt" VM.info; then
            awk '/container \(cgroup\) information:/ { p = 1; next } p && /^$/ { exit } p && /:/ { k = $0; sub(/:.*$/, "", k); v = $0; sub(/^[^:]*: */, "", v); print k "\t" v }' \
                "${PM_W}/vminfo.txt" > "${PM_W}/vminfo.container"
            while IFS="${PM_TAB}" read -r _pm_k _pm_v; do
                [ -n "${_pm_k}" ] || continue
                _pm_cr jvm_container "${_pm_k}" "${_pm_v}" "jcmd VM.info の container (cgroup) information"
                [ "${_pm_k}" = active_processor_count ] && _pm_eff="${_pm_v}"
            done < "${PM_W}/vminfo.container"
            _pm_cpuline="$(sed -n 's/^CPU: total [0-9]* (initial active \([0-9]*\)).*/\1/p' "${PM_W}/vminfo.txt" | head -n 1)"
            # VM.info には環境変数 (パスワードを含み得る) も出るため、必要な所を取ったら消す
            rm -f "${PM_W}/vminfo.txt"
        fi
    fi
    # VM.info に container 情報が無い (JVM がコンテナと判定していない) ときの代わり:
    #   ActiveProcessorCount の指定値 → 管理インタフェースの availableProcessors → VM.info の CPU 行
    if [ -z "${_pm_eff}" ] && pm_is_uint "${_pm_apc}" && [ "${_pm_apc}" -gt 0 ]; then
        _pm_eff="${_pm_apc}"
    fi
    if [ -z "${_pm_eff}" ] && [ -s "${PM_OUT}/perf_meta.csv" ]; then
        _pm_eff="$(awk -F, '$1 == "jboss" && $2 == "available-processors" { v = $3 } END { gsub(/"/, "", v); print v }' "${PM_OUT}/perf_meta.csv")"
        [ -n "${_pm_eff}" ] && _pm_cr jvm available_processors "${_pm_eff}" "jboss-cli の platform-mbean (Runtime.availableProcessors())"
    fi
    if [ -z "${_pm_eff}" ] && [ -n "${_pm_cpuline:-}" ]; then
        # 例: "CPU: total 4 (initial active 4) (4 cores per cpu, ...)"
        _pm_eff="${_pm_cpuline}"
        _pm_cr jvm initial_active_processors "${_pm_eff}" "jcmd VM.info の CPU 行 (JVM がコンテナと判定していないため、OS の CPU 数をそのまま使っています)"
    fi
    _pm_cpuline=""
    # ---- 同じコンテナで、オプション無しの JVM を起動したら何と判定されるか (プローブ) ----
    _pm_java="$(pm_java_of_jboss)"
    if [ -n "${_pm_java}" ]; then
        _pm_probe="$( (unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS; "${_pm_java}" -XX:-UsePerfData -Xshare:auto -XshowSettings:system -version 2>&1) )"
        printf '%s\n' "${_pm_probe}" | awk -F ': *' '/^ +(Provider|Effective CPU Count|CPU Period|CPU Quota|CPU Shares|List of Processors|Memory Limit|Memory Soft Limit)/ { k = $1; sub(/^ +/, "", k); print k "\t" $2 }' \
            > "${PM_W}/probe.sys"
        while IFS="${PM_TAB}" read -r _pm_k _pm_v; do
            [ -n "${_pm_k}" ] && _pm_cr probe "${_pm_k}" "${_pm_v}" "新しい JVM の -XshowSettings:system"
        done < "${PM_W}/probe.sys"
        printf '%s\n' "${_pm_probe}" | grep -q 'System not containerized' && _pm_cr probe containerized false "JVM はコンテナと判定していません (cgroup に CPU / メモリの上限が無い)"
        _pm_pl="$( (unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS; "${_pm_java}" -XX:-UsePerfData -Xlog:os+container=debug -version 2>&1) | grep -E 'active_processor_count|CPU Quota|CPU Period|CPU Shares|is_containerized|OSContainer::init' | sed 's/^\[[^]]*\]\[[^]]*\]\[[^]]*\] *//' | head -n 8 | tr '\n' ';')"
        _pm_cr probe os_container_log "${_pm_pl}" "新しい JVM の -Xlog:os+container=debug (CPU 数を決めた経緯)"
        _pm_pf="$( (unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS; "${_pm_java}" -XX:-UsePerfData -XX:+PrintFlagsFinal -version 2>/dev/null) | awk '$2 ~ /^(ActiveProcessorCount|ParallelGCThreads|ConcGCThreads|CICompilerCount|UseG1GC|UseSerialGC|UseParallelGC)$/ { printf "%s=%s ", $2, $4 }')"
        _pm_cr probe default_flags "${_pm_pf}" "オプション無しの JVM がこのコンテナで選ぶ値"
    fi
    # ---- 判定 ----
    _pm_j="$(awk -v tcpu="${_pm_tcpu}" -v ccpu="${_pm_ccpu}" -v napp="${_pm_napp}" -v q="${_pm_q}" -v apc="${_pm_apc}" \
              -v eff="${_pm_eff}" -v gc="${_pm_gc}" -v gco="${_pm_gco}" "${PM_JUDGE_AWK}")"
    _pm_jr="$(printf '%s' "${_pm_j}" | cut -f1)"; _pm_jrec="$(printf '%s' "${_pm_j}" | cut -f2)"
    _pm_jsh="$(printf '%s' "${_pm_j}" | cut -f3)"; _pm_jm="$(printf '%s' "${_pm_j}" | cut -f4-)"
    _pm_cr judgement result "${_pm_jr}" "要 / 要検討 / 不要 / 設定済み / 要確認 / 判定不可"
    _pm_cr judgement recommended_active_processor_count "${_pm_jrec}" "目安 (取り分を四捨五入、最小 1)"
    _pm_cr judgement share_vcpu "${_pm_jsh}" "このコンテナの CPU の取り分 (vCPU)"
    _pm_cr judgement jvm_cpus "${_pm_eff}" "JVM が認識した CPU 数"
    _pm_cr judgement message "${_pm_jm}" ""
    pm_append_locked "${PM_OUT}/cpu_env.csv" "${_pm_f}" "${PM_CPU_ENV_H}"
    PM_SHARE="${_pm_jsh}"; PM_JVMCPUS="${_pm_eff}"
    pm_log RESULT "③ ActiveProcessorCount: ${_pm_jr} — ${_pm_jm} (cpu_env.csv)"
    return 0
}

# ---- CPU の使われ方・待ち (/proc・cgroup) ----
PM_SCHED_H="timestamp,epoch,pid,cpus,jvm_cpus,share_vcpu,jboss_cpu_cores,app_cpu_cores,gc_cpu_cores,jit_cpu_cores,jboss_threads,jboss_threads_running,jboss_nonvol_ctxsw_per_sec,procs_running,procs_blocked,load1,cpu_steal_pct,psi_some_avg10,psi_full_avg10,psi_some_ms,cfs_periods,cfs_throttled,cfs_throttled_ms"
PM_THREADS_H="timestamp,epoch,pid,group,threads,running,cpu_cores,nonvol_ctxsw_per_sec"

# 入力は「種類 パス」の行。ファイルは getline で読む (途中で消えたスレッドのファイルは無視)。
# 前回の値 (CPU 時間など) を状態ファイルに残し、差分から区間の CPU 使用量を求める。
PM_CPU_AWK='
function pstat(l,    a, b, n, rest) {
  a = index(l, "("); b = 0
  for (n = length(l); n > a; n--) if (substr(l, n, 1) == ")") { b = n; break }
  if (a == 0 || b == 0) return 0
  COMM = substr(l, a + 1, b - a - 1); rest = substr(l, b + 2)
  split(rest, F, " ")
  return 1
}
# JBoss のスレッド名 (/proc の comm は 15 文字まで) → 用途
function grp(n) {
  if (n ~ /^(GC Thread|G1 |ZWorker|ZDirector|ZDriver|ZUncommit|ZStat|Shenandoah|ParGC|PSPromo|ConcGC)/) return "gc"
  if (n ~ /^(C1 CompilerThre|C2 CompilerThre|JVMCI)/) return "jit"
  if (n ~ /^JFR /) return "jfr"
  if (n ~ /^(VM Thread|VM Periodic|Service Thread|Monitor Deflati|Signal Dispatch|Reference Handl|Finalizer|Common-Cleaner|Notification Th|Attach Listene|Sweeper)/) return "vm"
  if (n ~ /^(MSC service|ServerService|management|DeploymentScan|Transaction|Periodic Recov|IdleRemover|Reference Reape|Controller Boo|ElytronTimer)/) return "jboss"
  if (n ~ / I\/O-[0-9]*$/ || n ~ / Accept$/) return "http-io"
  if (n ~ / task-[0-9]*$/) return "http-task"
  if (n ~ /^(EE-Managed|EJB default|EJB )/) return "ee-ejb"
  return "other"
}
function line(tag, p, l,    a, k, tid) {
  if (tag == "prev") { split(l, a, " ")
    if (a[1] == "ms") PMS = a[2]; else if (a[1] == "cpu") { for (k = 2; k <= 9; k++) PC[k] = a[k] }
    else if (a[1] == "psi") PPSI = a[2]; else if (a[1] == "thr") { PNP = a[2]; PNT = a[3]; PTU = a[4] } else if (a[1] == "pt") PPT = a[2]
    else if (a[1] == "t") { PTT[a[2]] = a[3]; PTV[a[2]] = a[4] }
    return }
  if (tag == "stat") { split(l, a, " ")
    if (a[1] == "cpu") { for (k = 2; k <= 9; k++) NCPU[k] = a[k] } else if (a[1] == "procs_running") PRUN = a[2]; else if (a[1] == "procs_blocked") PBLK = a[2]
    return }
  if (tag == "loadavg") { split(l, a, " "); L1 = a[1]; return }
  if (tag == "psi") {
    if (l ~ /^some /) { if (match(l, /avg10=[0-9.]+/)) PSIS = substr(l, RSTART + 6, RLENGTH - 6); if (match(l, /total=[0-9]+/)) PSIT = substr(l, RSTART + 6, RLENGTH - 6) }
    if (l ~ /^full /) { if (match(l, /avg10=[0-9.]+/)) PSIF = substr(l, RSTART + 6, RLENGTH - 6) }
    return }
  if (tag == "cpustat") { split(l, a, " "); if (a[1] == "nr_periods") NNP = a[2]; else if (a[1] == "nr_throttled") NNT = a[2]; else if (a[1] == "throttled_usec") NTU = a[2]; else if (a[1] == "throttled_time") NTU = int(a[2] / 1000); return }
  if (tag == "pstat") { if (pstat(l)) PTK = F[12] + F[13]; return }
  if (tag == "tstat") { if (pstat(l)) { tid = p; sub(/^.*\/task\//, "", tid); sub(/\/.*$/, "", tid); TK[tid] = F[12] + F[13]; TS0[tid] = F[1]; TG[tid] = grp(COMM); TIDS[++NTH] = tid } return }
  if (tag == "tstatus") { if (l ~ /^nonvoluntary_ctxt_switches:/) { tid = p; sub(/^.*\/task\//, "", tid); sub(/\/.*$/, "", tid); split(l, a, /[: \t]+/); TV[tid] = a[2] } return }
}
function rd(p, tag,    l) { while ((getline l < p) > 0) line(tag, p, l); close(p) }
{ tag = $1; p = substr($0, length($1) + 2); rd(p, tag) }
END {
  el = (PMS != "") ? (nowms - PMS) / 1000.0 : 0
  # ---- JBoss のスレッドを用途別に ----
  if (jpid != "") {
    for (i = 1; i <= NTH; i++) {
      t = TIDS[i]; g = TG[t]
      for (k = 0; k < 2; k++) { gg = (k == 0) ? "all" : g
        if (!(gg in GN)) GO[++NG] = gg
        GN[gg]++; if (TS0[t] == "R") GR[gg]++
        if (el > 0 && (t in PTT)) { dt = TK[t] - PTT[t]; if (dt > 0) GT[gg] += dt; dv = TV[t] - PTV[t]; if (dv > 0) GV[gg] += dv }
      }
    }
    for (i = 1; i <= NG; i++) { gg = GO[i]
      printf "%s,%s,%s,%s,%d,%d,%s,%s\n", ts, epoch, jpid, gg, GN[gg], GR[gg] + 0, \
        (el > 0 ? sprintf("%.3f", GT[gg] / hz / el) : ""), (el > 0 ? sprintf("%.1f", GV[gg] / el) : "") >> thf }
  }
  # ---- CPU の使われ方・待ち・steal・スロットリング ----
  tot = 0; for (k = 2; k <= 9; k++) { d[k] = NCPU[k] - PC[k]; tot += d[k] }
  if (el > 0 && tot > 0) {
    j = (jpid != "") ? 1 : 0
    app = GT["http-task"] + GT["http-io"] + GT["ee-ejb"] + GT["other"]
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%s,%s,%s,%s,%s,%s\n", ts, epoch, jpid, cpus, jvmcpus, share, \
      (j && PPT != "" ? sprintf("%.3f", (PTK - PPT) / hz / el) : ""), (j ? sprintf("%.3f", app / hz / el) : ""), \
      (j ? sprintf("%.3f", GT["gc"] / hz / el) : ""), (j ? sprintf("%.3f", GT["jit"] / hz / el) : ""), \
      (j ? GN["all"] + 0 : ""), (j ? GR["all"] + 0 : ""), (j ? sprintf("%.1f", GV["all"] / el) : ""), \
      PRUN, PBLK, L1, d[9] * 100 / tot, PSIS, PSIF, (PSIT != "" && PPSI != "" ? sprintf("%.1f", (PSIT - PPSI) / 1000.0) : ""), \
      (NNP != "" && PNP != "" ? NNP - PNP : ""), (NNT != "" && PNT != "" ? NNT - PNT : ""), (NTU != "" && PTU != "" ? sprintf("%.1f", (NTU - PTU) / 1000.0) : "") >> schedf
  }
  printf "ms %s\n", nowms > newstate
  printf "cpu" > newstate; for (k = 2; k <= 9; k++) printf " %s", NCPU[k] > newstate; printf "\n" > newstate
  if (PSIT != "") printf "psi %s\n", PSIT > newstate
  if (NNP != "") printf "thr %s %s %s\n", NNP, NNT, NTU > newstate
  if (jpid != "") { printf "pt %s\n", PTK > newstate; for (i = 1; i <= NTH; i++) printf "t %s %s %s\n", TIDS[i], TK[TIDS[i]], TV[TIDS[i]] + 0 > newstate }
  close(newstate)
}
'

pm_hz_page() {
    PM_HZ="$(getconf CLK_TCK 2>/dev/null)"; pm_is_uint "${PM_HZ}" || PM_HZ=100
}

# 1 回分の /proc の読み取り対象を「種類 パス」の行で書き出す
pm_cpu_list() {  # jboss-pid psi-file cpustat-file
    [ -r "${PM_W}/cpu.prev" ] && echo "prev ${PM_W}/cpu.prev"
    echo "stat /proc/stat"; echo "loadavg /proc/loadavg"
    [ -n "$2" ] && echo "psi $2"
    [ -n "$3" ] && echo "cpustat $3"
    if [ -n "$1" ]; then
        echo "pstat /proc/$1/stat"
        for _pm_t in /proc/"$1"/task/[0-9]*; do echo "tstat ${_pm_t}/stat"; echo "tstatus ${_pm_t}/status"; done
    fi
}

pm_cpu_sample() {  # psi-file cpustat-file
    pm_now
    _pm_nowms="$(pm_ms)"
    pm_cpu_list "${PM_JPID}" "$1" "$2" > "${PM_W}/cpu.list"
    awk -v ts="${PM_TS}" -v epoch="${PM_EPOCH}" -v nowms="${_pm_nowms}" -v hz="${PM_HZ}" -v cpus="${PM_CPUS}" -v jpid="${PM_JPID}" \
        -v jvmcpus="${PM_JVMCPUS:-}" -v share="${PM_SHARE:-}" -v thf="${PM_OUT}/cpu_threads.csv" -v schedf="${PM_OUT}/cpu_sched.csv" \
        -v newstate="${PM_W}/cpu.new" "${PM_CPU_AWK}" "${PM_W}/cpu.list" 2>> "${PM_W}/cpu.err"
    mv -f "${PM_W}/cpu.new" "${PM_W}/cpu.prev" 2>/dev/null
}

pm_run_cpu() {
    PM_NAME=cpu
    trap 'exit 0' TERM INT
    pm_hz_page
    pm_csv_init "${PM_OUT}/cpu_sched.csv" "${PM_SCHED_H}"
    pm_csv_init "${PM_OUT}/cpu_threads.csv" "${PM_THREADS_H}"
    PM_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
    # cgroup の CPU 統計 (スロットリング) と PSI (CPU の待ち) の場所
    _pm_cst=""; _pm_psi=""
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        [ -r /sys/fs/cgroup/cpu.stat ] && _pm_cst=/sys/fs/cgroup/cpu.stat
        [ -r /sys/fs/cgroup/cpu.pressure ] && _pm_psi=/sys/fs/cgroup/cpu.pressure
    else
        for _pm_g in /sys/fs/cgroup/cpu /sys/fs/cgroup/cpu,cpuacct /sys/fs/cgroup/cpuacct,cpu; do
            [ -r "${_pm_g}/cpu.stat" ] && { _pm_cst="${_pm_g}/cpu.stat"; break; }
        done
    fi
    [ -z "${_pm_psi}" ] && [ -r /proc/pressure/cpu ] && _pm_psi=/proc/pressure/cpu
    pm_meta cpu sources "cpu.stat=${_pm_cst:-なし} pressure=${_pm_psi:-なし}"
    PM_JPID=""; PM_SHARE=""; PM_JVMCPUS=""
    _pm_env_pid=""; _pm_env_next=0; _pm_env_fail=0; _pm_tool=0
    pm_log INFO "③ CPU: ${PERF_CPU_INTERVAL} 秒間隔 (JBoss のスレッドの用途別 CPU・実行待ち・steal・PSI・スロットリング)"
    while :; do
        pm_jboss_alive || PM_JPID="$(pm_find_jboss_pid)" || PM_JPID=""
        # JVM ごとに 1 回、ActiveProcessorCount の判断材料と判定 (アタッチできるまで 30 秒ごとに試す)
        if [ -n "${PM_JPID}" ] && [ "${_pm_env_pid}" != "${PM_JPID}" ] && [ "$(date +%s)" -ge "${_pm_env_next}" ]; then
            if [ "${_pm_tool}" = 0 ]; then pm_resolve_tool jcmd || PM_CPU_NOJCMD=1; _pm_tool=1; fi
            if pm_cpu_env; then
                _pm_env_pid="${PM_JPID}"; _pm_env_fail=0
            else
                _pm_env_fail=$((_pm_env_fail + 1)); _pm_env_next=$(( $(date +%s) + 30 ))
                if [ "${_pm_env_fail}" -ge 10 ]; then
                    pm_log WARN "③ jcmd で JVM へアタッチできないため、jcmd の値 (VM.flags・VM.info) 無しで判定します (/tmp の書き込み可否を確認してください)"
                    PM_CPU_NOJCMD=1; _pm_env_next=0
                fi
            fi
        fi
        pm_cpu_sample "${_pm_psi}" "${_pm_cst}"
        pm_sleep_tick "${PERF_CPU_INTERVAL}"
    done
}

# =============================================================================
# ビルド時の確認 / 運用コマンド
# =============================================================================
pm_install() {
    pm_say "ビルド時の確認 (perf-metrics.sh ${PERF_METRICS_VERSION})"
    if ! command -v awk > /dev/null 2>&1; then
        # awk が無いと ①②③ のどれも CSV にできないため、入れられなければビルドを失敗させる
        if command -v microdnf > /dev/null 2>&1; then
            microdnf install -y --nodocs gawk > /dev/null 2>&1 && microdnf clean all > /dev/null 2>&1
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y --nodocs gawk > /dev/null 2>&1 && dnf clean all > /dev/null 2>&1
        fi
        rm -rf /var/cache/yum /var/cache/dnf 2>/dev/null
        if command -v awk > /dev/null 2>&1; then
            pm_say "  gawk を導入しました"
        else
            pm_say "ERROR: awk がありません (gawk を導入できませんでした)。リポジトリへの接続を確認してください" >&2
            return 1
        fi
    fi
    for _pm_t in awk mkfifo curl nice tar gzip; do
        if command -v "${_pm_t}" > /dev/null 2>&1; then pm_say "  ${_pm_t}: $(command -v "${_pm_t}")"; else pm_say "  ${_pm_t}: なし"; fi
    done
    _pm_java="$(pm_java_of_jboss 2>/dev/null)" || _pm_java=""
    pm_say "  java: ${_pm_java:-なし}  (主版数 $(pm_java_major || echo 不明))"
    for _pm_t in jstat jcmd; do
        if pm_resolve_tool "${_pm_t}"; then pm_say "  ${_pm_t}: $(pm_tool_desc)"; else pm_say "  ${_pm_t}: なし (② の ${_pm_t} は動きません)"; fi
    done
    if [ -n "${_pm_java}" ]; then
        _pm_mods="$(env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS "${_pm_java}" -XX:-UsePerfData --list-modules 2>/dev/null)"
        for _pm_t in jdk.jfr jdk.jcmd jdk.compiler; do
            if printf '%s\n' "${_pm_mods}" | grep -q "^${_pm_t}@"; then pm_say "  module ${_pm_t}: あり"; else pm_say "  module ${_pm_t}: なし"; fi
        done
    fi
    if [ -f "${JBOSS_HOME:-/opt/jboss-eap}/bin/jboss-cli.sh" ]; then
        pm_say "  jboss-cli.sh: ${JBOSS_HOME:-/opt/jboss-eap}/bin/jboss-cli.sh"
    else
        pm_say "  jboss-cli.sh: なし (JBoss EAP 導入前のイメージでは正常。① は実行時に JBOSS_HOME から探します)"
    fi
    pm_say "性能試験用メトリクス収集 (Lite) を有効にしました (PERF_METRICS_ENABLED=true)"
    return 0
}

PM_COLLECTOR_NAMES="cli jstat jcmd jfr cpu"

pm_status() {
    if ! pm_load_state; then
        echo "perf-metrics: 実行中の収集が見つかりません (PERF_METRICS_ENABLED=${PERF_METRICS_ENABLED})"
        return 1
    fi
    echo "perf-metrics ${PERF_METRICS_VERSION}"
    echo "  出力先          : ${PM_OUT}"
    echo "  作業ディレクトリ: ${PM_W}"
    echo "  開始            : ${PM_START_TS}"
    for _pm_c in ${PM_COLLECTOR_NAMES}; do
        [ -r "${PM_W}/${_pm_c}.pid" ] || continue
        _pm_p="$(cat "${PM_W}/${_pm_c}.pid")"
        if kill -0 "${_pm_p}" 2>/dev/null; then _pm_s="実行中"; else _pm_s="停止"; fi
        echo "  収集 ${_pm_c}: ${_pm_s} (pid=${_pm_p})"
    done
    echo "  ファイル (行数 / 最終行の時刻):"
    for _pm_f in "${PM_OUT}"/*.csv; do
        [ -f "${_pm_f}" ] || continue
        case "${_pm_f##*/}" in
            perf_meta.csv|jfr_env.csv|jfr_summary.csv) _pm_lt="-" ;;
            *) _pm_lt="$(tail -n 1 "${_pm_f}" | cut -d, -f1 | tr -d '"')" ;;
        esac
        printf '    %-26s %8s  %s\n' "$(basename "${_pm_f}")" "$(wc -l < "${_pm_f}" | tr -d ' ')" "${_pm_lt}"
    done
    if [ -d "${PM_JFR_DIR:-${PM_OUT}/jfr}" ]; then
        echo "  JFR: $(find "${PM_JFR_DIR:-${PM_OUT}/jfr}" -name '*.jfr' -type f 2>/dev/null | wc -l | tr -d ' ') ファイル ($(du -sh "${PM_JFR_DIR:-${PM_OUT}/jfr}" 2>/dev/null | cut -f1))"
    fi
    if [ -s "${PM_OUT}/cpu_env.csv" ]; then
        echo "  ③ ActiveProcessorCount: $(awk -F, '$5 == "result" { r = $6 } END { gsub(/"/, "", r); print r }' "${PM_OUT}/cpu_env.csv")  (詳細: perf-metrics.sh cpu-check)"
    fi
    echo "  直近のログ:"
    tail -n 5 "${PM_LOG_FILE}" 2>/dev/null | sed 's/^/    /'
    return 0
}

pm_cpu_check() {
    pm_load_state || { echo "perf-metrics: 実行中の収集が見つかりません"; return 1; }
    [ -s "${PM_OUT}/cpu_env.csv" ] || { echo "まだ判定していません (JBoss の JVM へのアタッチ待ち)。しばらくしてから実行してください"; return 1; }
    # 最後の JVM の分だけを表示する
    _pm_lp="$(awk -F, 'NR > 1 { p = $3 } END { print p }' "${PM_OUT}/cpu_env.csv")"
    awk -F, -v p="${_pm_lp}" 'NR > 1 && $3 == p { v = $6; for (i = 7; i < NF; i++) v = v "," $i; gsub(/^"|"$/, "", v); printf "  %-10s %-36s %s\n", $4, $5, v }' "${PM_OUT}/cpu_env.csv"
}

pm_stop() {
    pm_load_state || { echo "perf-metrics: 実行中の収集が見つかりません"; return 1; }
    for _pm_c in ${PM_COLLECTOR_NAMES}; do
        [ -r "${PM_W}/${_pm_c}.pid" ] || continue
        _pm_p="$(cat "${PM_W}/${_pm_c}.pid")"
        if kill -0 "${_pm_p}" 2>/dev/null; then
            pm_kill_tree "${_pm_p}"
            echo "停止しました: ${_pm_c} (pid=${_pm_p})"
        fi
    done
    PM_NAME=stop
    pm_log INFO "perf-metrics.sh stop で収集を停止しました (JFR は JBoss 側で記録を続けます。止めるには jcmd <pid> JFR.stop name=perf-metrics)"
    echo "JFR は JBoss 側で記録を続けます (終了時に ${PM_JFR_DIR:-${PM_OUT}/jfr} へ保存)。記録全体を CSV にし直すには perf-metrics.sh jfr-csv"
    return 0
}

pm_jfr_dump() {
    pm_load_state || { echo "perf-metrics: 実行中の収集が見つかりません"; return 1; }
    PM_JPID="$(pm_find_jboss_pid)" || { echo "JBoss EAP の JVM が見つかりません"; return 1; }
    pm_resolve_tool jcmd || { echo "jcmd がありません"; return 1; }
    mkdir -p "${PM_JFR_DIR}/dump" 2>/dev/null
    pm_tool_exec "${PM_JPID}" JFR.dump name=perf-metrics "filename=${PM_JFR_DIR}/dump/perf_dump_%p_%t.jfr"
}

pm_pack() {
    pm_load_state || { echo "perf-metrics: 出力先が分かりません (PERF_OUTPUT_DIR を指定してください)"; return 1; }
    if pm_collector_running jfr; then
        echo "(JFR は収集中に CSV へ書いているため、変換は行いません)"
    elif [ -d "${PM_JFR_DIR}" ] && [ "${1:-}" != "no-jfr-csv" ]; then
        pm_jfr_csv "${PM_JFR_DIR}" || echo "(JFR の CSV 変換は行いませんでした)"
    fi
    _pm_par="$(dirname "${PM_OUT}")"
    _pm_tgz="${_pm_par}/perf_$(basename "${_pm_par}")_$(date '+%Y%m%d_%H%M%S').tar"
    # .jfr (大きい) は PERF_PACK_JFR=true のときだけ含める (CSV に変換済みのため)
    _pm_ex=""
    [ "${PERF_PACK_JFR:-false}" = true ] || _pm_ex="--exclude=*.jfr"
    if command -v gzip > /dev/null 2>&1; then
        # shellcheck disable=SC2086
        tar -C "${_pm_par}" ${_pm_ex} -czf "${_pm_tgz}.gz" "$(basename "${PM_OUT}")" && echo "${_pm_tgz}.gz"
    else
        # shellcheck disable=SC2086
        tar -C "${_pm_par}" ${_pm_ex} -cf "${_pm_tgz}" "$(basename "${PM_OUT}")" && echo "${_pm_tgz}"
    fi
}

pm_main() {
    _pm_cmd="${1:-}"
    [ "$#" -gt 0 ] && shift
    PM_SELF="$0"
    pm_setup_tz
    case "${_pm_cmd}" in
        run)
            case "${1:-}" in
                cli) pm_run_cli ;;
                jstat) pm_run_jstat ;;
                jcmd) pm_run_jcmd ;;
                jfr) pm_run_jfr ;;
                cpu) pm_run_cpu ;;
                *) echo "usage: perf-metrics.sh run cli|jstat|jcmd|jfr|cpu" >&2; exit 2 ;;
            esac
            ;;
        install) pm_install ;;
        status) pm_status ;;
        cpu-check) pm_cpu_check ;;
        stop) pm_stop ;;
        pack) pm_pack "$@" ;;
        jfr-dump) pm_jfr_dump ;;
        jfr-csv)
            pm_load_state || { PM_OUT="${PERF_OUTPUT_DIR:-$(pwd)}"; PM_W=""; }
            pm_jfr_csv "$@"
            ;;
        threaddump)
            pm_load_state || { echo "perf-metrics: 実行中の収集が見つかりません" >&2; exit 1; }
            PM_NAME=threaddump
            PM_JPID="$(pm_find_jboss_pid)" || { echo "JBoss EAP の JVM が見つかりません" >&2; exit 1; }
            pm_resolve_tool jcmd || { echo "jcmd がありません" >&2; exit 1; }
            pm_threaddump
            ;;
        start) perf_metrics_start "$@" ;;
        version) echo "perf-metrics.sh ${PERF_METRICS_VERSION}" ;;
        *)
            echo "usage: perf-metrics.sh status | cpu-check | stop | jfr-dump | jfr-csv | threaddump | pack | install | version" >&2
            exit 2
            ;;
    esac
}

# 直接実行されたときだけコマンドを処理する (エントリポイントから . で読み込まれたときは
# 関数の定義だけで終わる)
case "${0##*/}" in
    perf-metrics.sh|perf-metrics) pm_main "$@"; exit $? ;;
esac
:

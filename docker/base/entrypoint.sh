#!/bin/sh
# =============================================================================
# efs-entrypoint.sh
#
# readonlyRootFilesystem=true のタスクでも動作するエントリポイント。
# 書き込み先は EFS マウント (/mnt/logs, /mnt/data) と、タスク定義で
# 「書き込み可能ボリューム」を当てた JBoss の standalone 配下ディレクトリのみ。
#
# やること:
#   0. 診断ヘルパーの定義。
#      異常時は必ず「何が・どこで・なぜ」を出力してから終了する。
#      無音で落ちないことが本スクリプト最大の設計目標である (理由は下記)。
#   1. configuration の復元 (configuration-seed → configuration)
#      イメージビルド時に作った configuration-seed を起動時に書き戻す。
#      ECS では configuration に「空の」書き込み可能ボリュームがマウントされる
#      ため、この復元をしないと JBoss の設定一式が丸ごと消える。
#   2. EFS 上にアプリログ用ディレクトリを作成する
#      (イメージビルド時に焼き込んだシンボリックリンクの「実体側」を用意する)
#   3. 起動ごとの一意なディレクトリ名 (LOG_ID) を決め、
#      /mnt/logs/<Component_name>/logs/<Service_Name>/mid/<LOG_ID> を作成し、
#      EFS 上の `current` シンボリックリンクをそのディレクトリへ張り替える。
#      LOG_ID の決め方は LOG_ID_SOURCE で選ぶ (下記「一意ディレクトリ名の方針」)。
#   3-B. JBoss のログ出力先を「current 経由のパス」ではなく
#      mid/<LOG_ID> の実体パスへ固定 (pin) する。  ★ server.log 不正ローテーション対策
#      (-Djboss.server.log.dir / JBOSS_LOG_DIR / logging.properties の fileName)
#      gc.log と access_log.log も同じ理由で、共有の置き場を指す明示指定を実体パスへ揃える
#      (JAVA_OPTS 等の -Xlog / -Xloggc のパス、standalone.xml の access-log の directory)
#   4. JBoss が起動時に書き込む standalone 配下の可変ディレクトリを
#      「実際に書き込んでみて」検証する。
#   5. サービスが intra-web かつフロントコンテナの場合のみ、
#      EFS 上に /mnt/data/pdf がなければ作成する。
#   6. JBoss を起動する (本番の entrypoint.sh と同じ分岐)。
#      CMD が eap なら standalone.sh を本番と同じ引数で起動し (3-B の pin を付ける)、
#      eap 以外なら CMD をそのまま exec する。
#   6-B. (性能試験用イメージのみ) PERF_METRICS_ENABLED=true なら perf-metrics.sh を
#      読み込み、メトリクスの収集をバックグラウンドで始める。実装はすべて
#      perf-metrics.sh の 1 ファイルにあり、ここは読み込んで呼ぶだけ。
#      統計の有効化 (-Dwildfly.*.statistics-enabled=true) を standalone.sh の引数に、
#      JFR・NMT の JVM オプションを PREPEND_JAVA_OPTS に足す (JAVA_OPTS は変えない)。
#      収集側で何が起きても JBoss の起動は止めない。
#
# 【なぜ fail-fast と事前検証にここまでこだわるのか】
#   JBoss EAP の起動時ロギングは
#     -Dlogging.configuration=file:<configuration>/logging.properties
#   でブートストラップされる。この 1 ファイルが欠けると CONSOLE ハンドラも
#   FILE ハンドラも構成されず、server.log は作られず標準出力にも何も出ない。
#   つまり「configuration の復元に失敗する」= 「原因が一切ログに残らないまま
#   コンテナが黙って死ぬ」という最悪の障害モードに直結する。
#   本スクリプトは JBoss へ制御を渡す前に必要条件をすべて検証し、
#   満たさない場合は理由を明示して exit 1 する。
#   詳細は docs/TROUBLESHOOTING.md を参照。
#
# 【なぜ JBoss の書き込み先を実体パスへ固定 (pin) するのか】
#   `current` は同じ EFS を使う全タスクが共有する「最後に起動したタスクを指す
#   可変リンク」である。一方 JBoss の periodic-rotating-file-handler は
#   日付変更時に「close → パス文字列で rename → パス文字列で再 open」を行う。
#   ファイルを開いた後の fd は inode に結び付くが、rename / 再 open はその時点の
#   current を辿り直すため、後から起動した別タスクのディレクトリを操作してしまう。
#     - 新タスクが書き込み中の server.log が旧タスクに server.log.<前日> へ
#       rename され、新タスクはその「前日付ファイル」へ追記し続ける
#     - 旧タスクは新タスクのディレクトリに server.log を作って書き込む
#     - 2 回目の rename は REPLACE_EXISTING で先の server.log.<前日> を上書きし、
#       丸 1 日分のログが消える
#   standalone/log のリンクはビルド時に焼き込むしかない (readonlyRootFilesystem)
#   ため、JBoss 自身に「自分専用の実体パス」を渡して current を書き込み経路から
#   外す。current は「最後に起動したタスク」を示す目印としてのみ張り替える。
#   詳細・実機検証結果は docs/LOG_ROTATION.md を参照。
#
# 【JAVA_OPTS の -Djboss.server.log.dir=${JBOSS_HOME}/standalone/log について】
#   本番のエントリポイントは JAVA_OPTS にこの指定を入れている。値は JBoss の既定
#   (jboss.server.base.dir/log) と同じで、イメージに焼いた standalone/log → mid/current
#   のリンクを指す。JBoss 本体はこのパスを実体に解決せずに使う (ServerEnvironment) ため、
#   この指定では日付変更時の rename / 再 open が current を辿り、上の事故は防げない。
#   一方、standalone.sh は JAVA_OPTS → 起動引数の順に読んで最後の指定を採り、
#   JBoss 本体も起動引数の -D でシステムプロパティを上書きする。そこで本スクリプトは
#   「共有の置き場 (standalone/log や mid/ 配下) を指す明示指定」を運用者が選んだ
#   出力先とは見なさず、起動引数の pin で上書きする (それ以外の場所は明示指定を尊重)。
#   → 残したままでも pin は効く。ただし既定値と同じで役割が無く、ps で見える値が
#     実際の出力先と食い違うため、本番の JAVA_OPTS からは削除を推奨する。
#     削除して JAVA_OPTS が空になると standalone.conf の既定値 (ヒープサイズ等) が
#     効き始めるので、削除前に起動ログの JAVA_OPTS 行を確認すること。
#   詳細は docs/LOG_ROTATION.md の「10-1」を参照。
#
# 【gc.log と access_log.log について】
#   どちらも server.log と同じく「閉じる → パス名で rename → パス名で開き直す」で
#   ローテーションするため、パスが current を辿ると他タスクのファイルを改名してしまう。
#     gc.log         : JVM (HotSpot) が容量 (EAP の既定 3MB) ごとに行う。rename の前に
#                      パス名で gc.log.N を削除するため、他タスクの GC ログが消えることもある。
#                      JBoss EAP は standalone.conf の既定で GC_LOG=true (gc.log を出す)。
#     access_log.log : Undertow が日付変更後の最初のリクエストで行う。ファイルは最初の
#                      リクエストで初めて開く (遅延 open) ので、起動直後に別タスクが
#                      current を張り替えると、日付に関係なく他タスクのファイルに書き始める。
#   既定の書き方なら pin だけで自分のディレクトリに出る (gc.log は standalone.sh が
#   $JBOSS_LOG_DIR/gc.log を使い、access-log の directory の既定は ${jboss.server.log.dir})。
#   ただし次の明示指定は pin を素通りするため、3-B で実体パスへ書き換える。
#     - JAVA_OPTS (と JAVA_TOOL_OPTIONS / JDK_JAVA_OPTIONS) の -Xlog:…file=<パス> / -Xloggc:<パス>
#       が共有の置き場を指すもの。standalone.sh は JAVA_OPTS に GC ログの指定があると自分の指定を
#       足さずにそのまま使い、JVM のオプションは起動引数では上書きできないため、パス部分だけを
#       書き換える (JAVA_OPTS の他の部分は 1 文字も変えない)
#     - standalone.xml の access-log で、directory が /opt/jboss-eap/standalone/log などの
#       絶対パスや ${jboss.server.base.dir}/log、relative-to="jboss.server.base.dir" のもの。
#       directory="${jboss.server.log.dir}<その下>" に書き換える (relative-to は外す)
#   イメージの standalone.conf にある GC ログの指定は書き換えられない (WARN のみ)。
#   詳細は docs/LOG_ROTATION.md の「10-2」を参照。
#
# 一意ディレクトリ名の方針 (LOG_ID_SOURCE で切り替え):
#   random (既定) : ECS メタデータエンドポイントに依存せず、コンテナ起動時に自前で
#                   「起動時刻(YYYYMMDDhhmmss) + '-' + ランダム英数字 8 桁」を生成する。
#                   同一 EFS 配下は複数の ECS サービス・複数タスクから同時に呼ばれ
#                   得るため、ランダム 8 桁は /dev/urandom (暗号品質のエントロピー)
#                   を最優先に生成し、秒精度のタイムスタンプと組み合わせることで
#                   衝突確率を実質ゼロにする。/dev/urandom が無い環境向けに
#                   uuid / awk 乱数へ多段フォールバックする。さらに生成直後に
#                   mkdir で実在チェックし、万一衝突しても引き直す。
#   taskid        : (旧実装 entrypoint.taskid.sh 相当) ECS メタデータエンドポイント
#                   v4 から TaskARN を取得し、末尾のタスク ID をディレクトリ名に
#                   使う。aws ecs describe-tasks / CloudWatch と突合せしやすい。
#                   取得できない場合は random 方式へフォールバックする。
#                   同一タスク内でコンテナが再起動 (ECS の restartPolicy) した
#                   場合は同じディレクトリを再利用する (既存 server.log には追記、
#                   最終更新が前日以前なら JBoss が起動直後に日付付きへ rotate)。
#   どちらのモードでも configuration の復元・fail-fast 検証・3-B の pin は共通。
#   (旧実装を別ファイルで保守していた頃は、復元処理の移植漏れで無音死する
#    危険があった。モード切替に一本化してその乖離を無くした)
#
# 必要な環境変数(すべてイメージビルド時に ENV で焼き込み済み):
#   EFS_LOG_DIR    : /mnt/logs/<Component_name>/logs/<Service_Name>
#   COMPONENT_ROLE : front | back
#   Service_Name   : サービス名 (interapi / intra-api / intra-web(intraweb) / sfapi)
#   JBOSS_HOME     : JBoss EAP のインストール先 (既定 /opt/jboss-eap)
#   SERVER_CONFIG  : CMD=eap のとき standalone.sh -c に渡す設定ファイル名
#                    (base の ENV の既定は standalone.xml。CMD=eap で未設定なら FATAL)
#
# CMD=eap のときに JBoss へ渡す環境変数 (本番の entrypoint.sh と同じ。任意):
#   EXTRASLB_TRUSTSTORE_PATH     : -Djavax.net.ssl.truststore の値
#   EXTRASLB_TRUSTSTORE_PASSWORD : -Djavax.net.ssl.trustStorePassword の値 (起動ログでは伏せる)
#   EXTRASLB_TRUSTSTORE_TYPE     : -Djavax.net.ssl.trustStoreType の値
#   JBOSS_SERVER_OPTS            : standalone.sh への追加の引数。空白区切りで複数指定でき、
#                                  値の中の引用符は解釈しない (本番と同じく単語分割して渡す)
#
# 任意の環境変数(タスク定義から上書き可能):
#   CONFIG_SEED_MODE  : overwrite (既定) | missing | skip
#                       overwrite = 毎起動 seed で上書きする (推奨)
#                       missing   = 設定ファイルが無いときだけ復元する
#                       skip      = 復元しない (configuration を永続化する運用)
#   JBOSS_CONFIG_FILE : 存在を確認する設定ファイル名
#                       (既定は SERVER_CONFIG。それも未設定なら standalone.xml)
#   LOG_ID_SOURCE     : random (既定) | taskid     … 上記「一意ディレクトリ名の方針」
#   JBOSS_LOG_PIN     : on (既定) | off
#                       on  = JBoss の書き込み先を mid/<LOG_ID> の実体パスへ固定する
#                             (CMD が eap / standalone.sh なら -Djboss.server.log.dir を
#                              自動付与。共有の置き場を指す明示指定はこれで上書きする。
#                              gc.log・access_log.log の共有の置き場を指す指定も揃える)
#                       off = 従来どおり current 経由で書く。複数タスクが並走すると
#                             日付変更時のローテーションが他タスクのログを壊す。
#                             切り分け・再現試験以外では使わないこと
#   PERF_METRICS_ENABLED : false (既定) | true
#                       front / back のビルド引数 PERF_METRICS_ENABLED から ENV に焼き込む。
#                       true = 性能試験用のメトリクス収集 (perf-metrics.sh) を起動時に始める。
#                       イメージに perf-metrics.sh が無い (false でビルドした) ときは警告だけ。
#                       収集の設定 (PERF_INTERVAL など) は perf-metrics.sh の先頭を参照
# =============================================================================
set -eu

# --- 0. umask 設定 -----------------------------------------------------------
# 既定の umask 022 では、以下で作成するディレクトリが 0755 (group に write 権限
# なし) になる。EFS アクセスポイントで同一 gid・別 uid の後続タスクが
# `mid/<一意名>` ディレクトリを作成/更新しようとすると group write 不可で
# 失敗する。umask 002 に切り替えて 0775 (group write 可) で作成させ、
# ディレクトリの作成失敗を防ぐ。
umask 002

# --- 0-1. 診断ヘルパー -------------------------------------------------------
JBOSS_HOME="${JBOSS_HOME:-/opt/jboss-eap}"
STANDALONE_DIR="${JBOSS_HOME}/standalone"

say() {
    echo "[efs-entrypoint] $*"
}

# 異常終了時は必ず「現場の状態」を添えて落とす。
# ECS では CloudWatch (awslogs) が stdout/stderr を拾うため、
# ここで出した情報だけが唯一の手掛かりになることが多い。
dump_diag() {
    {
        echo "---------------- diagnostics ----------------"
        echo "# id"
        id 2>/dev/null || true
        echo "# ls -la ${STANDALONE_DIR}"
        ls -la "${STANDALONE_DIR}" 2>/dev/null || true
        echo "# mount (standalone / mnt のみ)"
        mount 2>/dev/null | grep -E 'standalone|/mnt' || echo "(該当マウント無し)"
        echo "# readlink -f ${STANDALONE_DIR}/log"
        readlink -f "${STANDALONE_DIR}/log" 2>/dev/null || echo "(解決不能 = dangling symlink)"
        echo "---------------------------------------------"
    } >&2
}

die() {
    echo "[efs-entrypoint] FATAL: $*" >&2
    dump_diag
    exit 1
}

# 予期しない箇所での set -e 停止も無音にしない (exec 後は発火しない)
on_exit() {
    _st=$?
    if [ "${_st}" -ne 0 ]; then
        echo "[efs-entrypoint] FATAL: エントリポイントが異常終了しました (exit=${_st})" >&2
    fi
}
trap on_exit EXIT

# ディレクトリが「本当に書き込めるか」を実書き込みで判定する。
# mount 情報のパースではなく実書き込みで見ることで、
#   - readonlyRootFilesystem=true によるボリューム未マウント (EROFS)
#   - EFS アクセスポイントの uid/gid 不一致 (EACCES)
# の双方を取りこぼさずに検出できる。
is_writable() {
    _d="$1"
    [ -d "${_d}" ] || return 1
    _probe="${_d}/.efs-entrypoint-writetest.$$"
    if ( : > "${_probe}" ) 2>/dev/null; then
        rm -f "${_probe}" 2>/dev/null || true
        return 0
    fi
    return 1
}

: "${EFS_LOG_DIR:?EFS_LOG_DIR が未設定です (イメージビルド時の ENV 焼き込み漏れ)}"

# --- 0-2. 切り替え用の環境変数の検証 ---------------------------------------
# EFS 上の current を張り替える前に弾く (typo のタスクが current だけ
# 書き換えて死ぬと、pin の無い旧イメージのタスクが並走している移行期に害がある)。
case "${LOG_ID_SOURCE:-random}" in
    random|taskid) ;;
    *) die "LOG_ID_SOURCE の値が不正です: '${LOG_ID_SOURCE}' (random|taskid)" ;;
esac
case "${JBOSS_LOG_PIN:-on}" in
    on|off) ;;
    *) die "JBOSS_LOG_PIN の値が不正です: '${JBOSS_LOG_PIN}' (on|off)" ;;
esac
# 起動コマンドが空なら止める。タスク定義で entryPoint を上書きすると、Docker / ECS は
# イメージの CMD (eap) を引き継がないため、command の指定漏れで起きる。
# そのまま進むと current を張り替えた後に exec "$@" が何もせず、exit 0 で終わってしまう。
[ "$#" -gt 0 ] \
    || die "起動コマンド (CMD) がありません。タスク定義で entryPoint を上書きした場合は command に [\"eap\"] も指定してください。"
# CMD=eap は 6 章で standalone.sh を -c "${SERVER_CONFIG}" 付きで起動する。
# SERVER_CONFIG が空だと -c "" になり JBoss が起動できないため、ここで止める。
if [ "${1:-}" = "eap" ]; then
    [ -n "${SERVER_CONFIG:-}" ] \
        || die "CMD=eap ですが SERVER_CONFIG (standalone.sh -c に渡す設定ファイル名。例: standalone.xml) が未設定です。"
    [ -x "${JBOSS_HOME}/bin/standalone.sh" ] \
        || die "CMD=eap ですが ${JBOSS_HOME}/bin/standalone.sh がありません。JBOSS_HOME と JBoss EAP の導入を確認してください。"
    # 本番と同じく空でもそのまま渡すが、空の trustStoreType は JVM 既定のトラストストアを
    # 読めなくする (WildFly 26 では HTTPS の SSL コンテキストが起動に失敗し、アプリも 404 になった)
    [ -n "${EXTRASLB_TRUSTSTORE_TYPE:-}" ] \
        || echo "[efs-entrypoint] WARN: EXTRASLB_TRUSTSTORE_TYPE が空です。-Djavax.net.ssl.trustStoreType= (空) になり JVM 既定のトラストストアを読めないため、JBoss の SSL コンテキスト (HTTPS など) が起動に失敗し得ます。" >&2
fi

# --- ランダム英数字 8 桁の生成 ----------------------------------------------
# [0-9a-z] の 36 文字集合から 8 桁 (36^8 ≒ 2.8e12 通り) を生成する。
# 大文字を含めないのは、目視での紛れや取り回しの事故を避けるため。
# 複数サービス・複数タスクから同時に呼ばれても、秒精度タイムスタンプと
# 合わせて一意になるだけのエントロピーを確保する。
gen_rand8() {
    _r=""
    # 1) /dev/urandom (最優先: 高エントロピー)。head がパイプを閉じても
    #    set -e に影響しないよう、パイプ全体を || true で保護する。
    if [ -r /dev/urandom ]; then
        _r="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8 || true)"
    fi
    # 2) カーネル uuid から英数字を抽出 (/dev/urandom が使えない場合)
    if [ "${#_r}" -lt 8 ] && [ -r /proc/sys/kernel/random/uuid ]; then
        _r="$(LC_ALL=C tr -dc 'a-z0-9' < /proc/sys/kernel/random/uuid 2>/dev/null | head -c 8 || true)"
    fi
    # 3) 最後の砦: PID + ナノ秒を種にした awk 乱数 (外部デバイス非依存)
    if [ "${#_r}" -lt 8 ]; then
        _seed="$$$(date +%N 2>/dev/null || echo 0)"
        _r="$(awk -v seed="${_seed}" 'BEGIN{
                srand(seed); c="0123456789abcdefghijklmnopqrstuvwxyz"; s="";
                for(i=0;i<8;i++){ s=s substr(c,int(rand()*36)+1,1) } print s }')"
    fi
    printf '%s' "${_r}"
}

# --- ECS タスク ID の取得 (LOG_ID_SOURCE=taskid) -----------------------------
# タスクメタデータエンドポイント v4 の /task から TaskARN を取り出し、
# 最後の '/' 以降をタスク ID とする。
#   新形式: arn:aws:ecs:<region>:<account>:task/<cluster>/<task-id>
#   旧形式: arn:aws:ecs:<region>:<account>:task/<task-id>
# jq の無いイメージでも動くよう sed で抜き、curl / wget どちらでも取得できる
# ようにする。ディレクトリ名に使うため英数字とハイフン以外を含む値は採用しない。
# 起動直後はエンドポイントの応答が遅れることがあるため数回だけ再試行する。
fetch_task_id() {
    [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ] || return 1
    _url="${ECS_CONTAINER_METADATA_URI_V4}/task"
    _n=0
    while [ "${_n}" -lt 3 ]; do
        _meta="$(curl -fsS --max-time 3 "${_url}" 2>/dev/null \
              || wget -q -T 3 -O - "${_url}" 2>/dev/null \
              || true)"
        _arn="$(printf '%s' "${_meta}" \
              | sed -n 's/.*"TaskARN"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
        _id="${_arn##*/}"
        case "${_id}" in
            ""|*[!A-Za-z0-9-]*) ;;
            *) printf '%s' "${_id}"; return 0 ;;
        esac
        _n=$((_n + 1))
        sleep 1
    done
    return 1
}

# --- 共有の置き場かどうか (-Djboss.server.log.dir・gc.log・access_log.log で共通) ---
# 共有の置き場 = そこへ書くと、全タスクで 1 本の current を辿る (または他タスクの
# ディレクトリに当たる) 場所:
#   - イメージに焼いた ${JBOSS_HOME}/standalone/log (→ mid/current) とその下
#   - mid/ とその下 (mid/current、他タスクや前回起動の mid/<ID>)
# ディレクトリ $1 がそこにあれば 0 を返し、standalone/log や mid/<何か> より下の残り
# ("" または "/サブ/…") を SHARED_REST に入れる。書き換えるときは ${LOG_OWN}${SHARED_REST}
# (自分の実体パス) にする。実在するディレクトリは物理パスでも調べる (別の綴りや、
# EFS 側がシンボリックリンク経由のとき)。
# MID_REAL (mid の実体パス。3-B で求める) を使うので、3-B より後で呼ぶこと。
under_mid() {   # under_mid <パス> <mid の場所>
    case "$1" in
        "$2") return 0 ;;
        "$2/"*)
            _mr="${1#"$2/"}"
            case "${_mr}" in */*) SHARED_REST="/${_mr#*/}" ;; esac
            return 0
            ;;
    esac
    return 1
}
shared_log_rest() {   # shared_log_rest <ディレクトリ>
    SHARED_REST=""
    _sd="$1"
    while :; do case "${_sd}" in ?*/) _sd="${_sd%/}" ;; *) break ;; esac; done
    case "${_sd}" in
        "${STANDALONE_DIR}/log")   return 0 ;;
        "${STANDALONE_DIR}/log/"*) SHARED_REST="/${_sd#"${STANDALONE_DIR}/log/"}"; return 0 ;;
    esac
    under_mid "${_sd}" "${MID_DIR}" && return 0
    _sp="$(cd "${_sd}" 2>/dev/null && pwd -P)" || return 1
    under_mid "${_sp}" "${MID_REAL}"
}

# 全タスクが同じファイルを使う EFS 上の場所 (EFS_LOG_DIR とその下。/webapp/…/logs のリンク先)
# なら 0。mid/ の下は shared_log_rest で先に判定すること。EFS_REAL は 3-B で求める。
on_shared_efs() {   # on_shared_efs <ディレクトリ>
    _ep="$(cd "$1" 2>/dev/null && pwd -P)" || _ep=""
    for _eq in "$1" "${_ep}"; do
        case "${_eq}" in
            "${EFS_LOG_DIR}"|"${EFS_LOG_DIR}/"*|"${EFS_REAL}"|"${EFS_REAL}/"*) return 0 ;;
        esac
    done
    return 1
}

# --- -Djboss.server.log.dir の明示指定の扱い ---------------------------------
# 起動引数 (CMD=eap のときは JBOSS_SERVER_OPTS) と JAVA_OPTS にある指定を 1 つずつ調べる。
#   - 共有の置き場を指す値は pin で上書きする。イメージに焼いた ${JBOSS_HOME}/standalone/log
#     (→ mid/current) と、mid/ 配下になる値 (current 経由・他タスクのディレクトリ)。
#     これを JBoss が使うと、日付変更時の rename / 再 open が他タスクのファイルに当たる。
#     本番の JAVA_OPTS にある -Djboss.server.log.dir=${JBOSS_HOME}/standalone/log がこれ。
#   - それ以外の値は、運用者が意図して別の場所へ出していると見なし、pin しない。
# 値は standalone.sh と同じく引用符を外してから判定する。
# MID_REAL (mid の実体パス。3-B で求める) を使うので、3-B より後で呼ぶこと。
is_shared_log_dir() {
    shared_log_rest "$(printf '%s' "$1" | tr -d "'\"")"
}

# 1 つの引数を判定し、上書きする指定は SHARED_LOG_DIRS に出どころ付きで足し、
# 尊重する指定は FOREIGN_LOG_DIR に入れる。
classify_log_dir_opt() {   # classify_log_dir_opt <引数> <出どころ>
    case "$1" in
        -Djboss.server.log.dir=*)
            if is_shared_log_dir "${1#*=}"; then
                SHARED_LOG_DIRS="${SHARED_LOG_DIRS:+${SHARED_LOG_DIRS}, }$2: ${1#*=}"
            else
                FOREIGN_LOG_DIR="${1#*=}"
            fi
            ;;
    esac
}

# 尊重すべき明示指定があれば 0 を返す (その値は FOREIGN_LOG_DIR)。引数には CMD ("$@") を渡す。
# CMD=eap のとき JBoss に渡る利用者指定の引数は JBOSS_SERVER_OPTS だけなので、
# 6 章の exec と同じく空白で分けて調べる (パス名展開はしない)。
find_foreign_log_dir() {
    FOREIGN_LOG_DIR=""
    SHARED_LOG_DIRS=""
    if [ "${1:-}" = "eap" ]; then
        set -f
        # shellcheck disable=SC2086
        set -- ${JBOSS_SERVER_OPTS:-}
        set +f
    fi
    for _a in "$@"; do
        classify_log_dir_opt "${_a}" "起動引数"
    done
    set -f
    for _a in ${JAVA_OPTS:-}; do
        classify_log_dir_opt "$(printf '%s' "${_a}" | tr -d "'\"")" "JAVA_OPTS"
    done
    set +f
    [ -n "${FOREIGN_LOG_DIR}" ]
}

# --- 起動行をログへ出すときの伏せ字 -------------------------------------------
# -D<名前>=<値> のうち、名前に pass / secret を含むもの (trustStorePassword など) の
# 値を **** にする。CloudWatch Logs にパスワードを平文で残さないため
# (exec する引数そのものは変えない)。値が空なら伏せない (未設定だと分かるように)。
mask_args() {
    _m=""
    for _a in "$@"; do
        case "${_a}" in
            -D*=?*)
                case "${_a%%=*}" in
                    *[Pp][Aa][Ss][Ss]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*) _a="${_a%%=*}=****" ;;
                esac
                ;;
        esac
        _m="${_m}${_m:+ }${_a}"
    done
    printf '%s' "${_m}"
}

# --- sed 用のエスケープ -------------------------------------------------------
# re_quote   : 基本正規表現 (BRE) の特殊文字 ] [ \ . * ^ $ をエスケープする
# repl_quote : 置換文字列の特殊文字 \ & をエスケープする
# 区切り文字には '#' を使うため、'#' を含むパスは呼び出し側で除外する。
re_quote()   { printf '%s' "$1" | sed -e 's/[][\.*^$]/\\&/g'; }
repl_quote() { printf '%s' "$1" | sed -e 's/[\&]/\\&/g'; }

# --- logging.properties の fileName を実体パスへ揃える (3-B で使用) ----------
# JBoss はこのファイルで起動直後 (logging サブシステム起動前) のロギングを構成し、
# 稼働中は logging サブシステムが解決済みの絶対パス
#   handler.FILE.fileName=/opt/jboss-eap/standalone/log/server.log
# で書き直す。seed が「一度起動したインストール」から作られていたり、
# configuration を永続化している (CONFIG_SEED_MODE=missing/skip、同一タスク内の
# コンテナ再起動) と、ここに「current 経由」や「前回起動の mid/<ID>」のパスが
# 残り、起動直後の数行が他タスク・前回起動のファイルへ書かれ得る。
# 配布物の既定である ${org.jboss.boot.log.file:...} 形式は standalone.sh が
# JBOSS_LOG_DIR から解決するため、書き換え対象にならない。
pin_logging_properties() {
    _lp="${CONF_DIR}/logging.properties"
    [ -f "${_lp}" ] || return 0
    case "${STANDALONE_DIR}${MID_DIR}${LOG_OWN}" in
        *'#'*)
            echo "[efs-entrypoint] WARN: パスに '#' を含むため logging.properties の書き換えを省略します" >&2
            return 0
            ;;
    esac
    _link_re="$(re_quote "${STANDALONE_DIR}/log")"
    _mid_re="$(re_quote "${MID_DIR}")"
    _own_rp="$(repl_quote "${LOG_OWN}")"
    grep -q -e "^handler\.[^=]*\.fileName=${_link_re}/" \
            -e "^handler\.[^=]*\.fileName=${_mid_re}/[^/]*/" "${_lp}" 2>/dev/null || return 0
    if sed -i \
        -e "s#^\(handler\.[^=]*\.fileName=\)${_link_re}/#\1${_own_rp}/#" \
        -e "s#^\(handler\.[^=]*\.fileName=\)${_mid_re}/[^/]*/#\1${_own_rp}/#" \
        "${_lp}" 2>/dev/null; then
        say "logging.properties の fileName を ${LOG_OWN} へ揃えました"
    else
        echo "[efs-entrypoint] WARN: ${_lp} を書き換えられません。起動直後の数行が current 経由で書かれる可能性があります" >&2
    fi
}

# --- gc.log (JVM の GC ログ) の出力先を実体パスへ揃える (3-B で使用) ----------
# standalone.sh は GC_LOG=true (JBoss EAP の standalone.conf の既定) のとき
#   -Xlog:gc*:file="$JBOSS_LOG_DIR/gc.log":time,uptimemillis:filecount=5,filesize=3M
# (JDK 8 は -Xloggc:"$JBOSS_LOG_DIR/gc.log" …) を JVM に渡す。JBOSS_LOG_DIR は 3-B で実体パスに
# するので、この既定の gc.log は何もしなくても自分のディレクトリに出る。
# ところが JAVA_OPTS に GC ログの指定 (-Xlog:gc… / -Xloggc:…) が既にあると、standalone.sh は
# 自分の指定を足さずにそれをそのまま JVM に渡す。そのパスが共有の置き場を指していると、
# JVM が容量 (filesize) ごとに行うローテーション
#   閉じる → パス名で gc.log.N を削除 → パス名で gc.log を gc.log.N へ rename → パス名で開き直す
# が current を辿り、他タスクの現役 gc.log を改名し、他タスクの gc.log.N を削除する。
# JVM のオプションは standalone.sh の起動引数では上書きできないため、該当する指定の
# パス部分だけを ${LOG_OWN}<共有の置き場より下の残り> に書き換える (他の部分は 1 文字も変えない)。
# 値は空白で区切った字句ごとに調べる (引用符は外して判定し、書き換えは元の字句の中で行う)。
#   -Xlog:<対象>:[file=]<パス>[:<装飾>[:<オプション>]]   -Xloggc:<パス>
# 相対パス・stdout / stderr・mid/ の外は書き換えない (EFS 上で全タスクが共有する場所なら WARN)。
pin_gc_log_var() {   # pin_gc_log_var <変数名>
    eval "_gv=\${$1:-}"
    [ -n "${_gv}" ] || return 0
    _gnew="${_gv}"
    set -f
    for _gt in ${_gv}; do
        _gu="$(printf '%s' "${_gt}" | tr -d "'\"")"
        case "${_gu}" in
            -Xloggc:*) _gf="${_gu#-Xloggc:}" ;;
            -Xlog:*:*) _gf="${_gu#-Xlog:*:}"; _gf="${_gf%%:*}"; _gf="${_gf#file=}" ;;
            *) continue ;;
        esac
        case "${_gf}" in /?*/?*) ;; *) continue ;; esac
        _gd="${_gf%/*}"; _gb="${_gf##*/}"
        if ! shared_log_rest "${_gd}"; then
            if on_shared_efs "${_gd}"; then
                echo "[efs-entrypoint] WARN: $1 の GC ログの出力先 ${_gf} は全タスクで共有する EFS 上の場所です。複数の JVM が同じ gc.log を改名・削除し合うため、\$JBOSS_LOG_DIR の下にしてください (docs/LOG_ROTATION.md 10-2)。" >&2
            fi
            continue
        fi
        case "${_gt}" in
            *"${_gf}"*) ;;
            *) echo "[efs-entrypoint] WARN: $1 の GC ログの指定を書き換えられません (パスの途中に引用符があります): ${_gt}" >&2
               continue ;;
        esac
        # 字句の中のパスだけを置き換え、値全体の中の同じ字句 (最初の 1 つ) を差し替える
        _gtn="${_gt%%"${_gf}"*}${LOG_OWN}${SHARED_REST}/${_gb}${_gt#*"${_gf}"}"
        _gnew="${_gnew%%"${_gt}"*}${_gtn}${_gnew#*"${_gt}"}"
        mkdir -p "${LOG_OWN}${SHARED_REST}" 2>/dev/null || true
        GC_PINNED="${GC_PINNED:+${GC_PINNED}, }$1: ${_gf}"
    done
    set +f
    if [ "${_gnew}" != "${_gv}" ]; then
        eval "$1=\${_gnew}"
        # shellcheck disable=SC2163  # $1 は変数名 (その名前の変数を export する)
        export "$1"
    fi
}

# イメージの standalone.conf (standalone.sh が読み込む) にある GC ログの指定は、読み取り専用の
# ルート FS 上にあるためエントリポイントからは書き換えられない。共有の置き場を指していそうな
# 行があれば、イメージ側で直すよう WARN だけ出す ($JBOSS_LOG_DIR を使う書き方なら pin に乗る)。
warn_gc_conf() {
    _gcf="${RUN_CONF:-${JBOSS_HOME}/bin/standalone.conf}"
    [ -r "${_gcf}" ] || return 0
    _gcl="$(grep -n -e '-Xlog' "${_gcf}" 2>/dev/null | grep -v -e '^[0-9]*:[[:space:]]*#' \
            | grep -e 'standalone/log' -e '/mid/' | head -n 3 | tr '\n' ' ' || true)"
    [ -n "${_gcl}" ] || return 0
    echo "[efs-entrypoint] WARN: ${_gcf} に共有の置き場 (standalone/log・mid/) を指していそうな GC ログの指定があります: ${_gcl}" >&2
    echo "[efs-entrypoint] WARN: この指定はエントリポイントから書き換えられません。容量でのローテーションが他タスクの gc.log を改名・削除し得るので、イメージの standalone.conf を \$JBOSS_LOG_DIR/gc.log を使う書き方に直してください (docs/LOG_ROTATION.md 10-2)。" >&2
}

pin_gc_logs() {
    GC_PINNED=""
    for _gvar in JAVA_OPTS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS; do
        pin_gc_log_var "${_gvar}"
    done
    if [ -n "${GC_PINNED}" ]; then
        say "note: 共有の置き場を指す GC ログの指定 (${GC_PINNED}) を ${LOG_OWN} へ書き換えました (docs/LOG_ROTATION.md 10-2)"
    fi
    warn_gc_conf
}

# --- access_log.log (Undertow のアクセスログ) の出力先を実体パスへ揃える (3-B で使用) ---
# standalone.xml の <access-log/> の directory の既定は ${jboss.server.log.dir} なので、
# 既定の書き方なら 3-B の pin (-Djboss.server.log.dir=<実体パス>) で自分のディレクトリに出る。
# ところが directory を /opt/jboss-eap/standalone/log のような絶対パス、
# ${jboss.server.base.dir}/log・${jboss.home.dir}/standalone/log、あるいは
# relative-to="jboss.server.base.dir" + directory="log" で書くと pin を素通りする。
# Undertow (DefaultAccessLogReceiver) は日付変更後の最初のリクエストで
#   閉じる → パス名で access_log.log を access_log.<日付>.log へ rename → パス名で開き直す
# を行い、ファイルは最初のリクエストで初めて開く (遅延 open) ため、パスが current を辿ると
# 他タスクのディレクトリで改名・作成・追記してしまう。
# そこで共有の置き場を指す access-log は directory="${jboss.server.log.dir}<その下の残り>" に
# 書き換えて (relative-to は外す) pin に乗せる。判定できない式 (${env.X} など)、全タスクで
# 共有する EFS 上の場所 (mid/ の外)、属性が複数行にわたる要素は WARN だけ出す。
# 対象は起動する設定ファイル ${CONF_DIR}/${JBOSS_CONFIG_FILE} (seed から毎起動復元されたもの)。
# shellcheck disable=SC2016  # ${jboss.server.log.dir} は JBoss が解決する式 (シェルでは展開しない)
LOGDIR_EXPR='${jboss.server.log.dir}'

# 要素の属性の並び $1 から、属性 $2 の値を取り出す ("…" と '…' の両方。無ければ空)
xml_attr() {
    printf '%s' "$1" | sed -n -e "s/.*[[:space:]]$2=\"\([^\"]*\)\".*/\1/p" -e 't' \
                              -e "s/.*[[:space:]]$2='\([^']*\)'.*/\1/p" | head -n 1
}

pin_access_log_line() {   # pin_access_log_line <行番号> <行の内容>
    _an="$1"
    _ae="${2#*<access-log}"
    case "${_ae}" in
        *'>'*) _ae="${_ae%%>*}" ;;
        *) echo "[efs-entrypoint] WARN: ${_ax} ${_an} 行目の access-log は属性が複数行にわたるため、出力先を確認できません。directory が共有の置き場 (standalone/log・mid/) を指していないか確認してください (docs/LOG_ROTATION.md 10-2)。" >&2
           return 0 ;;
    esac
    [ "$(xml_attr "${_ae}" use-server-log)" = "true" ] && return 0   # server.log に書く設定
    _adir="$(xml_attr "${_ae}" directory)"
    _arel="$(xml_attr "${_ae}" relative-to)"
    case "${_arel}" in
        "")                    _aeff="${_adir:-${LOGDIR_EXPR}}" ;;
        jboss.server.log.dir)  return 0 ;;                          # pin 済み
        jboss.server.base.dir) _aeff="${STANDALONE_DIR}/${_adir}" ;;
        jboss.home.dir)        _aeff="${JBOSS_HOME}/${_adir}" ;;
        *)                     return 0 ;;   # その他 (jboss.server.data.dir など) はタスクごとの場所
    esac
    if [ -n "${_arel}" ] && [ -z "${_adir}" ]; then
        echo "[efs-entrypoint] WARN: ${_ax} ${_an} 行目の access-log は relative-to=${_arel} だけで directory が無いため、出力先を確認できません (docs/LOG_ROTATION.md 10-2)。" >&2
        return 0
    fi
    # JBoss の式のうち、よく使うものだけ展開して判定する
    # shellcheck disable=SC2016  # '${…}' は JBoss の式そのもの (シェルでは展開しない)
    case "${_aeff}" in
        "${LOGDIR_EXPR}"|"${LOGDIR_EXPR}/"*) return 0 ;;            # pin 済み (既定を含む)
        '${jboss.server.base.dir}'*) _aeff="${STANDALONE_DIR}${_aeff#'${jboss.server.base.dir}'}" ;;
        '${jboss.home.dir}'*)        _aeff="${JBOSS_HOME}${_aeff#'${jboss.home.dir}'}" ;;
    esac
    # shellcheck disable=SC2016
    case "${_aeff}" in
        *'${'*)
            echo "[efs-entrypoint] WARN: ${_ax} ${_an} 行目の access-log の出力先 ${_aeff} は式を含むため確認できません。共有の置き場 (standalone/log・mid/) や全タスク共有の EFS を指していないか確認してください (docs/LOG_ROTATION.md 10-2)。" >&2
            return 0 ;;
        /*) ;;
        *) return 0 ;;
    esac
    if shared_log_rest "${_aeff}"; then
        _anew="${LOGDIR_EXPR}${SHARED_REST}"
        case "${_ax}${_adir}${_arel}" in
            *'#'*) echo "[efs-entrypoint] WARN: パスに '#' を含むため ${_ax} ${_an} 行目の access-log を書き換えられません (出力先: ${_aeff})" >&2
                   return 0 ;;
        esac
        if sed -i -e "${_an}s#\(<access-log[^>]*[[:space:]]directory=\)[\"']$(re_quote "${_adir}")[\"']#\1\"$(repl_quote "${_anew}")\"#" "${_ax}" 2>/dev/null \
           && { [ -z "${_arel}" ] \
                || sed -i -e "${_an}s#\(<access-log[^>]*\)[[:space:]]relative-to=[\"']$(re_quote "${_arel}")[\"']#\1#" "${_ax}" 2>/dev/null; } \
           && sed -n "${_an}p" "${_ax}" | grep -qF "directory=\"${_anew}\""; then
            say "note: access-log (${JBOSS_CONFIG_FILE} ${_an} 行目) の出力先 ${_arel:+relative-to=${_arel} }directory=${_adir} は共有の置き場を指すため、directory=${_anew} (= ${LOG_OWN}${SHARED_REST}) に書き換えました (docs/LOG_ROTATION.md 10-2)"
        else
            echo "[efs-entrypoint] WARN: ${_ax} ${_an} 行目の access-log を書き換えられません。access_log.log が current 経由で書かれ、日付変更時に他タスクのファイルを改名し得ます (出力先: ${_aeff})" >&2
        fi
        return 0
    fi
    if on_shared_efs "${_aeff}"; then
        echo "[efs-entrypoint] WARN: ${_ax} ${_an} 行目の access-log の出力先 ${_aeff} は全タスクで共有する EFS 上の場所です。複数のタスクが同じ access_log.log に書き、日付変更時に互いに改名し合うため、directory を指定しない (既定 ${LOGDIR_EXPR}) か ${LOGDIR_EXPR} の下にしてください (docs/LOG_ROTATION.md 10-2)。" >&2
    fi
    return 0
}

pin_access_log() {
    _ax="${CONF_DIR}/${JBOSS_CONFIG_FILE}"
    [ -f "${_ax}" ] || return 0
    _al="$(grep -n '<access-log[[:space:]/>]' "${_ax}" 2>/dev/null || true)"
    [ -n "${_al}" ] || return 0
    # ヒアドキュメントは使わない (bash は一時ファイルを作るため、読み取り専用のルート FS では失敗する)。
    # パイプの右側はサブシェルなので、ここで決めた変数は外へ持ち出さない (書き換えと出力だけ行う)。
    printf '%s\n' "${_al}" | while IFS= read -r _aline; do
        pin_access_log_line "${_aline%%:*}" "${_aline#*:}"
    done || true
}

# =============================================================================
# 1. configuration の復元 (configuration-seed → configuration)
# =============================================================================
# readonlyRootFilesystem=true では JBoss が configuration に書けない
# (standalone_xml_history の作成すら失敗する)。そのためタスク定義で
# /opt/jboss-eap/standalone/configuration に書き込み可能ボリュームを当てるが、
# ECS のボリュームは「空」でマウントされ、イメージ内の中身は見えなくなる。
# そこでビルド時に退避しておいた configuration-seed から毎起動書き戻す。
#
# 【Compose では失敗が表面化しない理由】
#   Docker の named volume は初回マウント時にイメージ側の中身を自動コピーする
#   (nocopy: true を指定しない限り)。したがってこの復元処理が壊れていても
#   Compose では正常に起動してしまう。ECS/Fargate は一切コピーしないため、
#   復元が失敗した瞬間に configuration が空になり JBoss が無音で死ぬ。
# -----------------------------------------------------------------------------
CONF_DIR="${JBOSS_CONF_DIR:-${STANDALONE_DIR}/configuration}"
SEED_DIR="${JBOSS_CONF_SEED_DIR:-${STANDALONE_DIR}/configuration-seed}"
CONFIG_SEED_MODE="${CONFIG_SEED_MODE:-overwrite}"
# 存在を確認する設定ファイル。CMD=eap は standalone.sh -c "${SERVER_CONFIG}" で起動する
# (6 章) ので、既定では SERVER_CONFIG と同じファイルを確認する。
JBOSS_CONFIG_FILE="${JBOSS_CONFIG_FILE:-${SERVER_CONFIG:-standalone.xml}}"

# 上書きの邪魔になる既存エントリを、コピー前に通れる状態にしておく。
#   - seed 側のディレクトリ構造を先に作る
#     (中間ディレクトリが「別 uid 所有・group write なし」で残っていると
#      その配下のファイル作成が EACCES になる)
#   - 既存ディレクトリには g+rwX を付け直す。chmod は所有者しか成功しない
#     ため best-effort だが、自タスクが作った残骸はこれで通るようになる。
prepare_conf_tree() {
    ( cd "${SEED_DIR}" && find . -type d -print 2>/dev/null ) \
    | while IFS= read -r _rel; do
        _dst="${CONF_DIR}/${_rel#./}"
        [ -d "${_dst}" ] || mkdir -p "${_dst}" 2>/dev/null || true
        [ -w "${_dst}" ] || chmod g+rwX "${_dst}" 2>/dev/null || true
    done
}

# cp が EACCES で落ちたときに「どのパスが誰の所有で書けないのか」を出す。
# これが無いと cp の 1 行 (cannot create regular file ...) だけが残り、
# 「ディレクトリが書けない」のか「既存ファイルが書けない」のか判別できない。
dump_conf_perm() {
    {
        echo "---------- configuration permissions ----------"
        echo "# id"
        id 2>/dev/null || true
        echo "# ls -ld ${CONF_DIR}"
        ls -ld "${CONF_DIR}" 2>/dev/null || true
        echo "# ${CONF_DIR} 配下で書き込めない既存エントリ (先頭 20 件)"
        find "${CONF_DIR}" -maxdepth 3 \( -type f -o -type d \) -print 2>/dev/null \
        | while IFS= read -r _p; do
            [ -w "${_p}" ] || ls -ld "${_p}" 2>/dev/null || true
        done | head -20
        echo "# ls -ld ${SEED_DIR}"
        ls -ld "${SEED_DIR}" 2>/dev/null || true
        echo "-----------------------------------------------"
    } >&2
}

restore_configuration() {
    [ -d "${SEED_DIR}" ] \
        || die "seed ディレクトリ ${SEED_DIR} がありません。base イメージのビルドで configuration-seed の作成に失敗しています。"

    if [ -z "$(ls -A "${SEED_DIR}" 2>/dev/null)" ]; then
        die "seed ディレクトリ ${SEED_DIR} が空です。base イメージのビルド時点で ${CONF_DIR} が空だった可能性があります。"
    fi

    # configuration 自体が無い場合、作れるのはルート FS が書ける環境だけ。
    # ECS (readonlyRootFilesystem=true) では失敗するが、その場合は
    # 直後の is_writable でより分かりやすいメッセージを出す。
    [ -d "${CONF_DIR}" ] || mkdir -p "${CONF_DIR}" 2>/dev/null || true

    if ! is_writable "${CONF_DIR}"; then
        echo "[efs-entrypoint] 考えられる原因:" >&2
        echo "[efs-entrypoint]   (a) タスク定義で ${CONF_DIR} に書き込み可能ボリュームを" >&2
        echo "[efs-entrypoint]       マウントしていない。readonlyRootFilesystem=true のため" >&2
        echo "[efs-entrypoint]       ルート FS 上のこのパスは EROFS になる。" >&2
        echo "[efs-entrypoint]   (b) EFS/アクセスポイントの uid/gid と実行ユーザーの不一致 (EACCES)。" >&2
        echo "[efs-entrypoint] 対処: タスク定義の volumes / mountPoints に" >&2
        echo "[efs-entrypoint]       { \"sourceVolume\": \"<name>\", \"containerPath\": \"${CONF_DIR}\" }" >&2
        echo "[efs-entrypoint]       を追加する。詳細は docs/TROUBLESHOOTING.md を参照。" >&2
        die "${CONF_DIR} に書き込めません。"
    fi

    if [ "${CONFIG_SEED_MODE}" = "missing" ] && [ -f "${CONF_DIR}/${JBOSS_CONFIG_FILE}" ]; then
        say "CONFIG_SEED_MODE=missing かつ ${JBOSS_CONFIG_FILE} が既存のため復元をスキップ"
        return 0
    fi

    prepare_conf_tree

    # cp のオプションに注意:
    #   -a / -p は所有権とタイムスタンプを保持しようとするが、EFS アクセス
    #   ポイントは uid/gid を強制するため chown が必ず失敗し、
    #   「ファイルはコピーできているのに終了コードが非 0」になる。
    #   set -e と組み合わさるとここで無音死する典型パターンなので使わない。
    #   -R (保持なし) なら新規ファイルは実行 uid の所有になり、
    #   パーミッションビットは seed 側 (ビルド時に g+rwX 済み) が引き継がれる。
    #   -f は「既存の書き込み不可ファイルを open できなかったら unlink して
    #   作り直す」オプション。ディレクトリ側に write 権限があれば通るため、
    #     cp: cannot create regular file '.../standalone.xml': Permission denied
    #   の典型原因である「前回タスクが別 uid・group write 無し (umask 022 時代の
    #   イメージ等) で作った残存ファイルを上書きできない」を解消する。
    #   ※ 上書きできない本当の理由がディレクトリ側 (EROFS / EACCES) の場合は
    #     -f でも通らないので、そのまま die して原因を出す。
    #   なお `cp -R "${SEED_DIR}/." "${CONF_DIR}/"` の末尾 `/.` が重要で、
    #   `seed/*` ではドットファイルを取りこぼし、`seed` では
    #   configuration/configuration-seed/ が出来てしまう。
    # 本処理は上書きであり、seed に存在しない残存ファイルの削除は行わない
    # (-f が unlink するのは「これから上書きする対象」だけ)。
    if ! cp -Rf "${SEED_DIR}/." "${CONF_DIR}/"; then
        echo "[efs-entrypoint] 考えられる原因:" >&2
        echo "[efs-entrypoint]   (a) ${CONF_DIR} 配下のサブディレクトリが別 uid 所有で" >&2
        echo "[efs-entrypoint]       group write 不可のまま残っている (ボリュームを永続化" >&2
        echo "[efs-entrypoint]       している場合に起きる)。中身を消して作り直すか、" >&2
        echo "[efs-entrypoint]       毎起動で空になるボリュームを使う。" >&2
        echo "[efs-entrypoint]   (b) EFS/アクセスポイントの uid/gid と実行ユーザーの不一致、" >&2
        echo "[efs-entrypoint]       または elasticfilesystem:ClientWrite の欠落 (EACCES)。" >&2
        echo "[efs-entrypoint]   (c) ${CONF_DIR} がボリューム未マウントで read-only (EROFS)。" >&2
        dump_conf_perm
        die "seed の書き戻しに失敗しました (${SEED_DIR} -> ${CONF_DIR})"
    fi

    # 次回起動 (同一 gid・別 uid のタスク) が上書きできるよう group write を
    # 付け直す。所有者でないファイルには失敗するが、それは今回書き込めた
    # ファイル群には該当しないため best-effort でよい。
    chmod -R g+rwX "${CONF_DIR}" 2>/dev/null || true

    say "configuration を復元しました (mode=${CONFIG_SEED_MODE}, $(ls -A1 "${CONF_DIR}" 2>/dev/null | wc -l) エントリ)"
}

case "${CONFIG_SEED_MODE}" in
    overwrite|missing)
        restore_configuration
        ;;
    skip)
        say "CONFIG_SEED_MODE=skip のため configuration の復元を行いません"
        ;;
    *)
        die "CONFIG_SEED_MODE の値が不正です: '${CONFIG_SEED_MODE}' (overwrite|missing|skip)"
        ;;
esac

# 復元後の必須ファイル検証。
# logging.properties が無いと JBoss は「server.log も標準出力も完全に無音」の
# まま起動に失敗する。ここで落として理由を残すのが本チェックの目的である。
if [ ! -f "${CONF_DIR}/logging.properties" ]; then
    echo "[efs-entrypoint] このファイルが無いと JBoss EAP は起動時ロギングを構成できず、" >&2
    echo "[efs-entrypoint] server.log も標準出力も完全に無音のまま起動に失敗します。" >&2
    echo "[efs-entrypoint] seed の作成漏れ (cp -r seed/* のようにドットファイルを取りこぼす" >&2
    echo "[efs-entrypoint] 書き方) か、ボリュームの二重マウントを疑ってください。" >&2
    die "${CONF_DIR}/logging.properties がありません。"
fi
[ -f "${CONF_DIR}/${JBOSS_CONFIG_FILE}" ] \
    || die "${CONF_DIR}/${JBOSS_CONFIG_FILE} がありません。SERVER_CONFIG (CMD=eap の -c) / JBOSS_CONFIG_FILE の値と seed の内容を確認してください。"

# =============================================================================
# 2. アプリログ用ディレクトリ (シンボリックリンクの実体)
# =============================================================================
mkdir -p "${EFS_LOG_DIR}" \
    || die "${EFS_LOG_DIR} を作成できません。EFS のマウント状態とアクセスポイントの uid/gid を確認してください。"

# =============================================================================
# 3. ミドルウェア(JBoss EAP)ログ用: 起動ごとの一意ディレクトリ (LOG_ID)
# =============================================================================
MID_DIR="${EFS_LOG_DIR}/mid"
mkdir -p "${MID_DIR}" || die "${MID_DIR} を作成できません。"

LOG_ID_SOURCE="${LOG_ID_SOURCE:-random}"
LOG_ID=""
case "${LOG_ID_SOURCE}" in
    random)
        ;;
    taskid)
        _tid="$(fetch_task_id || true)"
        if [ -n "${_tid}" ]; then
            # 同一タスク内のコンテナ再起動 (ECS restartPolicy) では同じ
            # ディレクトリを再利用するため、既存でもエラーにしない。
            mkdir -p "${MID_DIR}/${_tid}" \
                || die "${MID_DIR}/${_tid} を作成できません。EFS の書き込み権限を確認してください。"
            LOG_ID="${_tid}"
        else
            echo "[efs-entrypoint] WARN: ECS タスク ID を取得できないため random 方式 (起動時刻-ランダム8桁) で代替します (ECS_CONTAINER_METADATA_URI_V4='${ECS_CONTAINER_METADATA_URI_V4:-}')" >&2
        fi
        ;;
    *)
        die "LOG_ID_SOURCE の値が不正です: '${LOG_ID_SOURCE}' (random|taskid)"
        ;;
esac

if [ -z "${LOG_ID}" ]; then
    # 「起動時刻(秒) + ランダム 8 桁」で起動のたびに一意な名前を作る。
    # 万一同一秒・同一乱数で既存ディレクトリと衝突した場合に備え、
    # 衝突しない名前になるまで数回だけ引き直す (mkdir は原子的なので、
    # 複数タスクが同時に同名を狙っても片方だけが成功する)。
    _i=0
    while [ "${_i}" -lt 5 ]; do
        _cand="$(date +%Y%m%d%H%M%S)-$(gen_rand8)"
        if mkdir "${MID_DIR}/${_cand}" 2>/dev/null; then
            LOG_ID="${_cand}"
            break
        fi
        _i=$((_i + 1))
    done
    if [ -z "${LOG_ID}" ]; then
        # ここへ来ることはまず無いが、保険として PID を足して確実に作る
        LOG_ID="$(date +%Y%m%d%H%M%S)-$(gen_rand8)-$$"
        mkdir -p "${MID_DIR}/${LOG_ID}" \
            || die "${MID_DIR}/${LOG_ID} を作成できません。EFS の書き込み権限を確認してください。"
    fi
fi

# EFS 上の current リンクを今回起動のディレクトリへ張り替える。
# 相対リンクにしておくことで EFS をどこにマウントしても壊れない。
# (-n: current が既存リンクでもリンク先ディレクトリの中に作らない)
# current は「最後に起動したタスク」を示す目印であり、3-B の pin が有効なら
# JBoss の書き込み経路には使われない。GNU coreutils の ln -sfn は一時名で
# リンクを作ってから rename で置き換えるため、current が一瞬消えることはない。
ln -sfn "${LOG_ID}" "${MID_DIR}/current" \
    || die "current リンクを張り替えられません (${MID_DIR}/current)。既存 current の所有者と ${MID_DIR} の group write 権限を確認してください。"
say "JBoss EAP log dir: ${MID_DIR}/${LOG_ID} (LOG_ID_SOURCE=${LOG_ID_SOURCE})"

# =============================================================================
# 3-B. JBoss のログ出力先を実体パスへ固定 (pin)  ★ server.log 不正ローテーション対策
# =============================================================================
# 自分のディレクトリは current を辿らずに直接解決する。current は他タスクが
# いつでも張り替え得るため、readlink -f current では並行起動した別タスクの
# ディレクトリを掴む競合がある。
LOG_OWN="$(cd "${MID_DIR}/${LOG_ID}" 2>/dev/null && pwd -P)" \
    || die "${MID_DIR}/${LOG_ID} を解決できません。"
# 明示指定が共有の置き場を指すかの判定 (shared_log_rest / on_shared_efs) に使う
MID_REAL="$(cd "${MID_DIR}" 2>/dev/null && pwd -P)" \
    || die "${MID_DIR} を解決できません。"
EFS_REAL="$(cd "${EFS_LOG_DIR}" 2>/dev/null && pwd -P)" \
    || die "${EFS_LOG_DIR} を解決できません。"

# PIN_OPT: 6 章で standalone.sh の直後に付ける引数 (空なら付けない)
PIN_OPT=""
JBOSS_LOG_PIN="${JBOSS_LOG_PIN:-on}"
case "${JBOSS_LOG_PIN}" in
    on)
        if find_foreign_log_dir "$@"; then
            echo "[efs-entrypoint] WARN: -Djboss.server.log.dir=${FOREIGN_LOG_DIR} が明示指定されているため pin を適用しません (明示指定を優先します)。" >&2
            echo "[efs-entrypoint] WARN: その場所を複数のタスクで共有していると、日付変更時のローテーションが他タスクのログを壊します。" >&2
        else
            # standalone.sh はこの変数から -Dorg.jboss.boot.log.file (logging サブシステム
            # 起動前のブートログ) と GC ログ (GC_LOG=true 時。JBoss EAP の既定) の出力先を決める。
            export JBOSS_LOG_DIR="${LOG_OWN}"
            pin_logging_properties
            case "${1:-}" in
                eap|*/standalone.sh|standalone.sh)
                    # JBoss 本体の jboss.server.log.dir (FILE ハンドラの relative-to、
                    # Elytron の audit.log 等) を実体パスへ。付け方は 6 章。
                    PIN_OPT="-Djboss.server.log.dir=${LOG_OWN}"
                    say "log pin: JBoss は ${LOG_OWN} へ直接書き込みます (current は書き込み経路に使いません)"
                    if [ -n "${SHARED_LOG_DIRS}" ]; then
                        say "note: 共有の置き場 (current 経由) を指す -Djboss.server.log.dir の指定 (${SHARED_LOG_DIRS}) は pin で上書きします (docs/LOG_ROTATION.md 10-1)"
                    fi
                    ;;
                *)
                    echo "[efs-entrypoint] WARN: CMD が eap / standalone.sh ではないため -Djboss.server.log.dir を自動付与できません。" >&2
                    echo "[efs-entrypoint] WARN: ラッパーから JBoss へ -Djboss.server.log.dir=\"\${JBOSS_LOG_DIR}\" を渡してください (JBOSS_LOG_DIR=${LOG_OWN})。" >&2
                    ;;
            esac
            # gc.log (JVM) と access_log.log (Undertow) も同じ理由で、共有の置き場を指す
            # 明示指定を実体パスへ揃える (既定の書き方なら上の pin だけで自分のディレクトリに出る)
            pin_gc_logs
            pin_access_log
        fi
        ;;
    off)
        echo "[efs-entrypoint] WARN: JBOSS_LOG_PIN=off: JBoss は current 経由で書き込みます。" >&2
        echo "[efs-entrypoint] WARN: 複数タスクが並走すると、日付変更時のローテーションが他タスクの server.log を rename・上書きします (docs/LOG_ROTATION.md)。" >&2
        ;;
    *)
        die "JBOSS_LOG_PIN の値が不正です: '${JBOSS_LOG_PIN}' (on|off)"
        ;;
esac

# =============================================================================
# 4. JBoss が書き込む standalone 配下ディレクトリの検証
# =============================================================================
# readonlyRootFilesystem=true では、書き込み可能ボリュームを当てていない限り
# 以下はすべて EROFS になる。configuration だけ seed で救済しても、
# tmp / data が書けなければ JBoss はロギング構成より前段で落ち、
# やはり無音のまま終了する。実書き込みで検証して先に潰す。

# 2 段リンク (standalone/log → mid/current → mid/<LOG_ID>) は運用者やログ収集の
# 入口として残しているため、解決できること (dangling でないこと) を確認する。
# 解決先が自分の LOG_ID と違うのは、直後に別タスクが current を張り替えた場合で
# あり異常ではない (pin 有効時は JBoss の書き込みに影響しない)。
LOG_LINK="${STANDALONE_DIR}/log"
LOG_REAL="$(readlink -f "${LOG_LINK}" 2>/dev/null || true)"
if [ -z "${LOG_REAL}" ] || [ ! -d "${LOG_REAL}" ]; then
    die "${LOG_LINK} の解決に失敗しました (dangling symlink)。ビルド時のリンク先と EFS_LOG_DIR='${EFS_LOG_DIR}' が一致しているか確認してください。"
fi
if [ "${LOG_REAL}" != "${LOG_OWN}" ]; then
    say "note: ${LOG_LINK} は別タスクのディレクトリ ${LOG_REAL} を指しています (並行起動で current が張り替えられたため)"
fi
# JBoss が server.log を作る先 (= 自分の実体ディレクトリ) に実際に書けるか
is_writable "${LOG_OWN}" \
    || die "${LOG_OWN} に書き込めません。server.log を作成できないため JBoss は無音になります。EFS アクセスポイントの uid/gid を確認してください。"
say "log -> ${LOG_OWN} (書き込み可)"

# 起動に必須の可変ディレクトリ (書けなければ起動不能なので落とす)
for _d in tmp data; do
    _p="${STANDALONE_DIR}/${_d}"
    [ -d "${_p}" ] || continue
    if ! is_writable "${_p}"; then
        echo "[efs-entrypoint] JBoss EAP は起動時に standalone/tmp (VFS 展開) と" >&2
        echo "[efs-entrypoint] standalone/data に書き込みます。readonlyRootFilesystem=true では" >&2
        echo "[efs-entrypoint] 書き込み可能ボリュームのマウントが必須です。" >&2
        echo "[efs-entrypoint] タスク定義に containerPath=${_p} のマウントを追加してください。" >&2
        die "${_p} に書き込めません。"
    fi
done

# 必須ではないが書けないと機能が制限されるディレクトリ (警告のみ)
for _d in deployments content; do
    _p="${STANDALONE_DIR}/${_d}"
    [ -d "${_p}" ] || continue
    is_writable "${_p}" \
        || echo "[efs-entrypoint] WARN: ${_p} に書き込めません (デプロイスキャナ等が制限されます)" >&2
done

# =============================================================================
# 5. 帳票 pdf ディレクトリ (intra-web のフロントコンテナのみ)
# =============================================================================
if [ "${COMPONENT_ROLE:-}" = "front" ]; then
    case "${Service_Name:-}" in
        intra-web|intraweb)
            if [ ! -d /mnt/data/pdf ]; then
                mkdir -p /mnt/data/pdf || die "/mnt/data/pdf を作成できません。"
                say "created /mnt/data/pdf"
            fi
            ;;
    esac
fi

# =============================================================================
# 6. JBoss の起動 (本番の entrypoint.sh と同じ分岐)
# =============================================================================
#   CMD が eap → standalone.sh を本番と同じ引数で起動する
#   それ以外   → CMD をそのまま exec する
# 本番の entrypoint.sh の最後の分岐:
#   if [ "$1" = "eap" ]; then
#       exec ${JBOSS_HOME}/bin/standalone.sh -b 0.0.0.0 -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}" \
#           -Djavax.net.ssl.truststore="${EXTRASLB_TRUSTSTORE_PATH}" \
#           -Djavax.net.ssl.trustStorePassword="${EXTRASLB_TRUSTSTORE_PASSWORD}" \
#           -Djavax.net.ssl.trustStoreType="${EXTRASLB_TRUSTSTORE_TYPE}" ${JBOSS_SERVER_OPTS}
#   else
#       exec "$@"
#   fi
# ここでは eap の起動行をいったん "$@" に組み立て、3-B の pin を反映してから 1 か所で
# exec する (実際に渡す引数を、パスワードを伏せてログに出すため)。起動する内容は
# 本番と同じで、違いは pin (-Djboss.server.log.dir=<実体パス>) が付くことだけ。
if [ "${1:-}" = "eap" ]; then
    if [ "$#" -gt 1 ]; then
        shift
        echo "[efs-entrypoint] WARN: CMD=eap の後ろの引数は使いません (本番と同じ): $(mask_args "$@")" >&2
    fi
    # JBOSS_SERVER_OPTS は空白区切りで複数の引数を渡せるよう、本番と同じく
    # 引用符なしで展開する (単語分割させる)。
    # ※ -Djavax.net.ssl.truststore は本番の綴りのまま。JVM (JSSE) が読むのは大文字 S の
    #   javax.net.ssl.trustStore で、この綴りの指定は無視される (本番側で要確認)。
    # shellcheck disable=SC2086
    set -- "${JBOSS_HOME}/bin/standalone.sh" -b 0.0.0.0 -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}" \
        -Djavax.net.ssl.truststore="${EXTRASLB_TRUSTSTORE_PATH:-}" \
        -Djavax.net.ssl.trustStorePassword="${EXTRASLB_TRUSTSTORE_PASSWORD:-}" \
        -Djavax.net.ssl.trustStoreType="${EXTRASLB_TRUSTSTORE_TYPE:-}" \
        ${JBOSS_SERVER_OPTS:-}
fi

# 3-B の pin を standalone.sh の引数へ反映する (PIN_OPT が空なら何もしない)。
#   - 起動引数にある -Djboss.server.log.dir は取り除く。ここに残っているのは共有の置き場を
#     指す指定だけ (それ以外があれば 3-B で pin をやめている) で、standalone.sh も JBoss も
#     後に出てきた指定を採るため、残すと pin に勝ってしまう。
#   - pin はコマンドの直後に置く (standalone.sh は '--' より後ろの引数を読まない)。
#   JAVA_OPTS 側の指定は書き換えない。standalone.sh は JAVA_OPTS → 起動引数の順に読み、
#   JBoss 本体も起動引数の -D でシステムプロパティを上書きするので、起動引数の pin が勝つ。
if [ -n "${PIN_OPT}" ]; then
    _cmd="$1"; shift
    _n=$#
    for _a in "$@"; do
        case "${_a}" in -Djboss.server.log.dir=*) continue ;; esac
        set -- "$@" "${_a}"
    done
    shift "${_n}"
    set -- "${_cmd}" "${PIN_OPT}" "$@"
fi

# =============================================================================
# 6-B. 性能試験用メトリクス収集 (ビルド引数 PERF_METRICS_ENABLED=true のイメージのみ)
# =============================================================================
# 実装は perf-metrics.sh の 1 ファイルにまとめている。有効なときだけ読み込み (.)、
# 収集プロセスをバックグラウンドで起動する (JBoss の JVM が現れるのを待ってから取得する)。
# 出力先は 3 で決めた実体ディレクトリ (JBOSS_LOG_DIR = mid/<LOG_ID>) の perf/。
# 収集の開始に失敗しても JBoss の起動は続ける。
PERF_METRICS_SCRIPT="${PERF_METRICS_SCRIPT:-/usr/local/bin/perf-metrics.sh}"
case "${PERF_METRICS_ENABLED:-false}" in
    true)
        if [ -r "${PERF_METRICS_SCRIPT}" ]; then
            # shellcheck disable=SC1090  # 読み込むのは /usr/local/bin/perf-metrics.sh (PERF_METRICS_SCRIPT で変更可)
            . "${PERF_METRICS_SCRIPT}"
            perf_metrics_start "$@" \
                || echo "[efs-entrypoint] WARN: 性能試験用メトリクス収集を開始できませんでした (JBoss はそのまま起動します)" >&2
            case "${1:-}" in
                */standalone.sh|standalone.sh)
                    # 統計を有効にする引数 (-Dwildfly.datasources / undertow / transactions .statistics-enabled=true)
                    # を standalone.sh の直後へ足す (standalone.sh は '--' より後ろの引数を読まないため)
                    if [ -n "${PERF_SERVER_OPTS:-}" ]; then
                        _cmd="$1"; shift
                        # shellcheck disable=SC2086
                        set -- "${_cmd}" ${PERF_SERVER_OPTS} "$@"
                    fi
                    # JFR (-XX:StartFlightRecording) と NMT は JVM のオプションなので、standalone.sh が
                    # JAVA_OPTS の前に足す PREPEND_JAVA_OPTS で渡す。JAVA_OPTS を空から設定すると
                    # standalone.conf の既定値 (ヒープサイズ等) が効かなくなるため、JAVA_OPTS は変えない
                    if [ -n "${PERF_PREPEND_JAVA_OPTS:-}" ]; then
                        PREPEND_JAVA_OPTS="${PERF_PREPEND_JAVA_OPTS}${PREPEND_JAVA_OPTS:+ ${PREPEND_JAVA_OPTS}}"
                        export PREPEND_JAVA_OPTS
                    fi
                    ;;
            esac
        else
            echo "[efs-entrypoint] WARN: PERF_METRICS_ENABLED=true ですが ${PERF_METRICS_SCRIPT} がありません。" >&2
            echo "[efs-entrypoint] WARN: このイメージは PERF_METRICS_ENABLED=false でビルドされています。収集するには --build-arg PERF_METRICS_ENABLED=true で再ビルドしてください" >&2
        fi
        ;;
    false|"")
        ;;
    *)
        echo "[efs-entrypoint] WARN: PERF_METRICS_ENABLED の値が不正です: '${PERF_METRICS_ENABLED}' (true|false)。性能試験用メトリクス収集は行いません" >&2
        ;;
esac

say "preflight OK. starting: $(mask_args "$@")"
exec "$@"

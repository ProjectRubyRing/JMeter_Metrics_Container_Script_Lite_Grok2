# syntax=docker/dockerfile:1
# =============================================================================
# フロントコンテナ (webapp9mf02) 用 Dockerfile
#
# readonlyRootFilesystem=true でもタスク起動後にルート FS へ書き込みが
# 発生しないよう、シンボリックリンクはすべて「イメージビルド時」に作成する。
# リンクの実体側 (EFS 上のディレクトリ) はエントリポイントが起動時に
# EFS マウント (/mnt/logs, /mnt/data) 内へ作成する。
#
# 作成するシンボリックリンク:
#   /webapp/webapp9mf02/logs      -> /mnt/logs/<Component_name>/logs/<Service_Name>
#   /webapp/webapp9mf02/pdf       -> /mnt/data/pdf          ※ intra-web のみ
#   /opt/jboss-eap/standalone/log -> /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current
#     (`current` は EFS 上のリンクで、エントリポイントが起動ごとに
#      mid/<LOG_ID> (起動時刻-ランダム8桁 または ECS タスク ID) へ張り替える
#      2 段リンク構成。current は全タスク共有の「最後に起動したタスク」の目印で、
#      JBoss 自身はエントリポイントが渡す -Djboss.server.log.dir=mid/<LOG_ID>
#      (実体パス) へ直接書き込む。日付変更時のローテーションが他タスクの
#      server.log を rename しないようにするため。docs/LOG_ROTATION.md 参照)
#
# ビルド例 (サービス × コンポーネントごとにイメージを作成する):
#   docker build -t intra-web-front:latest \
#     --build-arg BASE_IMAGE=myapp-base:latest \
#     --build-arg Service_Name=intra-web \
#     --build-arg Component_name=intra-web-front \
#     docker/front
#
#   # 性能試験用 (メトリクス収集を有効にする。タグは本番用と分け、Service_Name /
#   # Component_name は本番と同じ値にする = ログの出力先 (EFS のパス) が本番と同じになる):
#   docker build -t intra-web-front:perf \
#     --build-arg BASE_IMAGE=myapp-base:latest \
#     --build-arg Service_Name=intra-web \
#     --build-arg Component_name=intra-web-front \
#     --build-arg PERF_METRICS_ENABLED=true \
#     docker/front
# =============================================================================
ARG BASE_IMAGE=myapp-base:latest
FROM ${BASE_IMAGE}

# タスク定義に設定される値と同じものをビルド引数として受け取る。
# (タスク定義の environment にも同名で設定し、ビルド値と一致させること)
ARG Service_Name
ARG Component_name

# ビルド引数の指定漏れはここで即座に失敗させる
RUN test -n "${Service_Name}"   || { echo "ERROR: --build-arg Service_Name が未指定です"   >&2; exit 1; } \
    && test -n "${Component_name}" || { echo "ERROR: --build-arg Component_name が未指定です" >&2; exit 1; }

# エントリポイントが参照する値を ENV として焼き込む。
# EFS_LOG_DIR をビルド時に確定させておくことで、タスク定義側の環境変数と
# 万一値がずれても「ビルド時に作ったリンク」と「起動時に作る実体」が
# 必ず同じパスを指すようにしている。
ENV Service_Name=${Service_Name} \
    Component_name=${Component_name} \
    COMPONENT_ROLE=front \
    APP_HOME=/webapp/webapp9mf02 \
    EFS_LOG_DIR=/mnt/logs/${Component_name}/logs/${Service_Name}

USER root

# --- ここでアプリケーション本体を配置する ------------------------------------
# COPY --chown=jboss:jboss webapp9mf02/ /webapp/webapp9mf02/
RUN mkdir -p /webapp/webapp9mf02 /opt/jboss-eap/standalone

# --- 1. アプリログ: /webapp/webapp9mf02/logs -> EFS --------------------------
# 既存の logs ディレクトリ(実体)が配置されていても削除してからリンクを作成
RUN rm -rf /webapp/webapp9mf02/logs \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}" /webapp/webapp9mf02/logs

# --- 2. 帳票 pdf: intra-web のフロントコンテナのみ ---------------------------
# 他サービスではリンク自体を作成しない (要件どおり)。
# EFS 側の /mnt/data/pdf の作成はエントリポイントが起動時に行う。
RUN if [ "${Service_Name}" = "intra-web" ] || [ "${Service_Name}" = "intraweb" ]; then \
        rm -rf /webapp/webapp9mf02/pdf; \
        ln -s /mnt/data/pdf /webapp/webapp9mf02/pdf; \
        echo "pdf symlink created for ${Service_Name}"; \
    else \
        echo "pdf symlink skipped for ${Service_Name}"; \
    fi

# --- 3. ミドルウェア(JBoss EAP)ログ ------------------------------------------
# ビルド時に実体の log ディレクトリを削除し、EFS 上の 2 段リンク入口
# (`.../mid/current`) へ向けたリンクに置き換える。
# 起動ごとの実体 (.../mid/<LOG_ID>) の作成と current の張り替えはエントリポイントが
# EFS 上 (書き込み可) で行うため、readonlyRootFilesystem=true でも動作する。
# JBoss の書き込み先はエントリポイントが実体パスへ固定する (JBOSS_LOG_PIN=on)。
RUN rm -rf /opt/jboss-eap/standalone/log \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}/mid/current" /opt/jboss-eap/standalone/log

# リンクの張り先を確認できるようビルドログへ出力 (ビルド時検証)
RUN ls -l /webapp/webapp9mf02/ /opt/jboss-eap/standalone/ | grep -E ' logs| log| pdf' || true

# --- 4. 性能試験用メトリクス収集 (ビルド引数で有効化 / 無効化) -----------------
#   --build-arg PERF_METRICS_ENABLED=true  : perf-metrics.sh を残し、起動時に収集を始める
#                                           (① jboss-cli ② jstat・jcmd・JFR ③ top・ps ④ CPU 数の判定)。
#   --build-arg PERF_METRICS_ENABLED=false : (既定) perf-metrics.sh を削除する。本番用。
#   --build-arg PERF_INTERVAL=10           : 取得間隔の既定 (秒)。タスク定義の environment
#                                           (PERF_INTERVAL・PERF_CLI_INTERVAL など) でも上書きできる。
#   --build-arg PERF_PROCPS=auto           : top / ps (procps-ng) が無ければ導入を試みる。導入できなく
#                                           てもビルドは続け、③ は /proc から同じ項目を算出する
#                                           (true = 導入できなければ失敗させる、false = 導入しない)。
# 有効かどうかは ENV に焼き込み、エントリポイントが起動時に読む。起動ログ (CloudWatch Logs)
# に「性能試験用メトリクス収集: 有効」の枠が出れば有効になっている。
# 出力先: /mnt/logs/<Component_name>/logs/<Service_Name>/mid/<LOG_ID>/perf/
#         (mid/current/perf から辿れる。readonlyRootFilesystem=true でも書ける EFS 上)
ARG PERF_METRICS_ENABLED=false
ARG PERF_INTERVAL=10
ARG PERF_PROCPS=auto
ENV PERF_METRICS_ENABLED=${PERF_METRICS_ENABLED} \
    PERF_INTERVAL=${PERF_INTERVAL}
RUN case "${PERF_METRICS_ENABLED}" in \
        true) \
            test -f /usr/local/bin/perf-metrics.sh \
                || { echo "ERROR: base イメージに /usr/local/bin/perf-metrics.sh がありません。base を再ビルドしてください" >&2; exit 1; }; \
            PERF_PROCPS="${PERF_PROCPS}" /usr/local/bin/perf-metrics.sh install ;; \
        false) \
            rm -f /usr/local/bin/perf-metrics.sh; \
            echo "perf-metrics: 無効 (PERF_METRICS_ENABLED=false)。perf-metrics.sh を削除しました" ;; \
        *) \
            echo "ERROR: --build-arg PERF_METRICS_ENABLED は true か false で指定してください (指定値: ${PERF_METRICS_ENABLED})" >&2; \
            exit 1 ;; \
    esac

# 実行ユーザーへ戻す (本番ベースイメージのユーザーに合わせること)
# USER jboss

ENTRYPOINT ["/usr/local/bin/efs-entrypoint.sh"]
# 本番と同じ起動方式。eap を渡すと、エントリポイントが standalone.sh を決まった引数
# (-b 0.0.0.0 -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}" ... ${JBOSS_SERVER_OPTS}) で
# 起動する (base の Dockerfile 参照)。eap 以外を渡すと、そのコマンドをそのまま実行する。
CMD ["eap"]

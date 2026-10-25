# syntax=docker/dockerfile:1
# =============================================================================
# バックコンテナ (webapp9mb02) 用 Dockerfile
#
# フロント用との差分:
#   - アプリのホームが /webapp/webapp9mf02 ではなく /webapp/webapp9mb02
#   - 帳票 pdf のシンボリックリンクは「作成しない」(intra-web フロント限定要件のため)
#   - COMPONENT_ROLE=back (エントリポイントの pdf 作成判定にも使用)
#
# 作成するシンボリックリンク:
#   /webapp/webapp9mb02/logs      -> /mnt/logs/<Component_name>/logs/<Service_Name>
#   /opt/jboss-eap/standalone/log -> /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current
#     (`current` は EFS 上のリンクで、エントリポイントが起動ごとに
#      mid/<LOG_ID> (起動時刻-ランダム8桁 または ECS タスク ID) へ張り替える
#      2 段リンク構成。JBoss 自身は -Djboss.server.log.dir=mid/<LOG_ID> の
#      実体パスへ直接書き込む。docs/LOG_ROTATION.md 参照)
#
# ビルド例:
#   docker build -t intra-api-back:latest \
#     --build-arg BASE_IMAGE=myapp-base:latest \
#     --build-arg Service_Name=intra-api \
#     --build-arg Component_name=intra-api-back \
#     docker/back
#
#   # 性能試験用 (メトリクス収集を有効にする。タグは本番用と分け、Service_Name /
#   # Component_name は本番と同じ値にする = ログの出力先 (EFS のパス) が本番と同じになる):
#   docker build -t intra-api-back:perf \
#     --build-arg BASE_IMAGE=myapp-base:latest \
#     --build-arg Service_Name=intra-api \
#     --build-arg Component_name=intra-api-back \
#     --build-arg PERF_METRICS_ENABLED=true \
#     docker/back
# =============================================================================
ARG BASE_IMAGE=myapp-base:latest
FROM ${BASE_IMAGE}

ARG Service_Name
ARG Component_name

RUN test -n "${Service_Name}"   || { echo "ERROR: --build-arg Service_Name が未指定です"   >&2; exit 1; } \
    && test -n "${Component_name}" || { echo "ERROR: --build-arg Component_name が未指定です" >&2; exit 1; }

ENV Service_Name=${Service_Name} \
    Component_name=${Component_name} \
    COMPONENT_ROLE=back \
    APP_HOME=/webapp/webapp9mb02 \
    EFS_LOG_DIR=/mnt/logs/${Component_name}/logs/${Service_Name}

USER root

# --- ここにアプリケーション本体を配置する ------------------------------------
# COPY --chown=jboss:jboss webapp9mb02/ /webapp/webapp9mb02/
RUN mkdir -p /webapp/webapp9mb02 /opt/jboss-eap/standalone

# --- 1. アプリログ: /webapp/webapp9mb02/logs -> EFS --------------------------
RUN rm -rf /webapp/webapp9mb02/logs \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}" /webapp/webapp9mb02/logs

# --- 2. ミドルウェア(JBoss EAP)ログ ------------------------------------------
# フロントと同様、実体ディレクトリを削除して EFS 上の 2 段リンク入口へ向ける。
# `current` の実体 (.../mid/<LOG_ID>) はエントリポイントが起動時に
# EFS 上へ作成・張り替え、JBoss の書き込み先をその実体パスへ固定する。
RUN rm -rf /opt/jboss-eap/standalone/log \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}/mid/current" /opt/jboss-eap/standalone/log

# リンクの張り先を確認できるようビルドログへ出力 (ビルド時検証)
RUN ls -l /webapp/webapp9mb02/ /opt/jboss-eap/standalone/ | grep -E ' logs| log' || true

# --- 3. 性能試験用メトリクス収集 (ビルド引数で有効化 / 無効化) -----------------
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
# 本番と同じ起動方式 (front の Dockerfile・base の Dockerfile 参照)
CMD ["eap"]

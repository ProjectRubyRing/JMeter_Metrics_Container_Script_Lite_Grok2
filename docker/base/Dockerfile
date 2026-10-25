# syntax=docker/dockerfile:1
# =============================================================================
# base イメージ
#
# front / back の各 Dockerfile が FROM で参照する共通ベース。
# サービス名・コンポーネント名に依存する処理は一切ここには置かず、
# 全サービス・全コンポーネントで共通の仕込みだけを行う。
#   - EFS マウントポイント (/mnt/logs, /mnt/data) のディレクトリ作成
#   - readonlyRootFilesystem=true 対応のエントリポイントスクリプト配置
#   - 性能試験用メトリクス収集 perf-metrics.sh の配置 (有効化は front / back のビルド引数)
#   - JBoss EAP の configuration を configuration-seed へ退避 (seed 方式)
#
# ビルド例:
#   docker build -t myapp-base:latest docker/base
#
#   # CI (JBoss 導入済み前提) では seed が空だとビルドを失敗させる:
#   docker build -t myapp-base:latest --build-arg STRICT_SEED=1 docker/base
# =============================================================================
ARG BASE_IMAGE=registry.access.redhat.com/ubi8/openjdk-11:latest
FROM ${BASE_IMAGE}

USER root

ARG JBOSS_HOME=/opt/jboss-eap
ENV JBOSS_HOME=${JBOSS_HOME} \
    JBOSS_CONF_DIR=${JBOSS_HOME}/standalone/configuration \
    JBOSS_CONF_SEED_DIR=${JBOSS_HOME}/standalone/configuration-seed

# front / back の CMD は本番と同じ "eap"。このときエントリポイントは
#   standalone.sh -b 0.0.0.0 -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}"
#     -Djavax.net.ssl.truststore=... -Djavax.net.ssl.trustStorePassword=...
#     -Djavax.net.ssl.trustStoreType=... ${JBOSS_SERVER_OPTS}
# で JBoss を起動する (実体パスへの固定 -Djboss.server.log.dir も付ける)。
# SERVER_CONFIG は本番で使う設定ファイル名に合わせる (タスク定義の environment でも上書き可)。
# EXTRASLB_TRUSTSTORE_PATH / _PASSWORD / _TYPE と JBOSS_SERVER_OPTS はタスク定義で渡す
# (パスワードは secrets = Secrets Manager / SSM パラメータストアを推奨)。
# EXTRASLB_TRUSTSTORE_TYPE だけは既定値を置く。空のまま起動すると
# -Djavax.net.ssl.trustStoreType= (空) が JVM に渡って既定のトラストストアを読めなくなり、
# WildFly 26 では HTTPS の SSL コンテキスト (applicationSSC) が起動に失敗して、
# それに依存する Web のサービスも止まる (アプリが 404。実機で確認)。
# JKS 型は JDK 9 以降、PKCS12 形式の cacerts も読める。
ENV SERVER_CONFIG=standalone.xml \
    EXTRASLB_TRUSTSTORE_TYPE=JKS

# EFS のマウントポイント。ECS がマウントするため空ディレクトリでよいが、
# イメージ内に存在させておくことでローカル起動時 (-v なし) でも
# シンボリックリンク切れの原因を追いやすくする。
RUN mkdir -p /mnt/logs /mnt/data /webapp "${JBOSS_HOME}"

# EFS 上のディレクトリ整備・起動ごとの一意ディレクトリ作成と current 張り替え・
# JBoss ログ出力先の実体パス固定 (pin)・configuration の seed 書き戻しを行う
# エントリポイント。ディレクトリ名は LOG_ID_SOURCE で選ぶ:
#   random (既定) = 起動時刻-ランダム8桁 / taskid = ECS タスク ID (旧方式)
# efs-entrypoint-taskid.sh は LOG_ID_SOURCE=taskid を既定にして
# efs-entrypoint.sh を呼ぶ互換ラッパー。どちらも同じ本体を使うため、
# 方式を切り替えても configuration 復元・fail-fast・pin は必ず効く。
# 切り替えはタスク定義 (environment か entryPoint) で行い、再ビルドは不要。
# entryPoint を上書きするとイメージの CMD (eap) は引き継がれないので、
# その場合はタスク定義の command に ["eap"] も指定すること。
# ※ entrypoint.taskid.sh を efs-entrypoint.sh という名前で COPY しないこと
#   (ラッパーが自分自身を呼ぶため起動時に FATAL で停止する)。
COPY entrypoint.sh        /usr/local/bin/efs-entrypoint.sh
COPY entrypoint.taskid.sh /usr/local/bin/efs-entrypoint-taskid.sh
RUN chmod 0755 /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh \
    # Windows でチェックアウトされた場合の CRLF 混入対策
    && sed -i 's/\r$//' /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh

# 性能試験用メトリクス収集 (perf-metrics.sh)。性能試験用の実装はこの 1 ファイルにまとめてある。
# base では置くだけで動かない。使うかどうかは front / back のビルド引数
# PERF_METRICS_ENABLED で決め、false (既定) なら front / back のビルドで削除する。
# エントリポイントは PERF_METRICS_ENABLED=true のときだけこのファイルを読み込む。
COPY perf-metrics.sh /usr/local/bin/perf-metrics.sh
RUN chmod 0755 /usr/local/bin/perf-metrics.sh \
    # Windows でチェックアウトされた場合の CRLF 混入対策
    && sed -i 's/\r$//' /usr/local/bin/perf-metrics.sh

# ここに JBoss EAP 本体の導入やミドルウェア共通設定など、
# front / back 共通のレイヤーを追加する。
# 例)
# COPY jboss-eap-7.4/ /opt/jboss-eap/
# RUN groupadd -r jboss && useradd -r -g jboss -d /opt/jboss-eap jboss \
#     && chown -R jboss:jboss /opt/jboss-eap /webapp

# =============================================================================
# configuration の seed 退避  ★ 必ず JBoss EAP 導入の「後ろ」に置くこと
# =============================================================================
# readonlyRootFilesystem=true では JBoss が standalone/configuration へ書けない
# (起動時に standalone_xml_history を作るだけで失敗する)。そのためタスク定義で
# configuration に書き込み可能ボリュームを当てるが、**ECS のボリュームは空で
# マウントされ、イメージ内の configuration は覆い隠されて見えなくなる**。
# (Docker Compose の named volume はイメージ内容を自動コピーするため
#  この問題が表面化しない。ECS/Fargate はコピーしない。)
#
# そこでビルド時に configuration の中身を configuration-seed へ丸ごと退避し、
# 起動時に efs-entrypoint.sh が configuration へ書き戻す。
#
# 実装上の注意:
#   - `cp -a "${SRC}/." "${DST}/"` の末尾 `/.` が必須。`${SRC}/*` では
#     ドットファイルを取りこぼし、`${SRC}` では dst/configuration/ が出来る。
#   - ビルド時は root かつ同一 FS なので -a (所有権・時刻保持) で問題ない。
#     所有権を保持しない cp -R を使うのは「起動時」側だけ (EFS アクセス
#     ポイントが uid/gid を強制し chown が失敗するため)。
#   - g+rwX を付与しておく。EFS アクセスポイントで同一 gid・別 uid の
#     タスクが書き戻し先を更新できるようにするため。
#   - standalone_xml_history は起動のたびに JBoss が作り直すので seed からは除く。
ARG STRICT_SEED=0
RUN set -eu; \
    mkdir -p "${JBOSS_HOME}/standalone"; \
    if [ -d "${JBOSS_CONF_DIR}" ] && [ -n "$(ls -A "${JBOSS_CONF_DIR}" 2>/dev/null)" ]; then \
        rm -rf "${JBOSS_CONF_SEED_DIR}"; \
        mkdir -p "${JBOSS_CONF_SEED_DIR}"; \
        cp -a "${JBOSS_CONF_DIR}/." "${JBOSS_CONF_SEED_DIR}/"; \
        rm -rf "${JBOSS_CONF_SEED_DIR}/standalone_xml_history"; \
        chmod -R g+rwX "${JBOSS_CONF_SEED_DIR}"; \
        echo "[base] seeded ${JBOSS_CONF_SEED_DIR}: $(find "${JBOSS_CONF_SEED_DIR}" -type f | wc -l) files"; \
        test -f "${JBOSS_CONF_SEED_DIR}/logging.properties" \
            || { echo "[base] ERROR: seed に logging.properties がありません。これが無いと JBoss は無音で起動失敗します。" >&2; exit 1; }; \
    else \
        mkdir -p "${JBOSS_CONF_SEED_DIR}"; \
        if [ "${STRICT_SEED}" = "1" ]; then \
            echo "[base] ERROR: ${JBOSS_CONF_DIR} が空/未作成です。JBoss EAP の導入 RUN より後ろにこのブロックがあるか確認してください。" >&2; \
            exit 1; \
        fi; \
        echo "[base] WARN: ${JBOSS_CONF_DIR} が空/未作成のため seed をスキップしました (本スケルトンでは正常)。" >&2; \
        echo "[base] WARN: JBoss 導入後は必ず --build-arg STRICT_SEED=1 でビルドし、seed の作成漏れを検出すること。" >&2; \
    fi

# JBoss が起動時に書き込む可変ディレクトリ。ECS では以下に書き込み可能
# ボリュームをマウントする (docs/TROUBLESHOOTING.md 5 章のタスク定義例を参照)。
# マウントポイントをイメージ内に用意しておくことで、所有者が root で
# 作られてしまうのを避け、未マウント時の切り分けもしやすくする。
RUN mkdir -p "${JBOSS_HOME}/standalone/tmp" \
             "${JBOSS_HOME}/standalone/data" \
             "${JBOSS_HOME}/standalone/deployments" \
    && chmod -R g+rwX "${JBOSS_HOME}/standalone/tmp" \
                      "${JBOSS_HOME}/standalone/data" \
                      "${JBOSS_HOME}/standalone/deployments"

# 実行ユーザーは front / back 側 (または本番のベースイメージ) に合わせて設定する
# USER jboss

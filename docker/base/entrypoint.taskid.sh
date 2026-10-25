#!/bin/sh
# =============================================================================
# efs-entrypoint-taskid.sh  【ECS タスク ID 方式の互換ラッパー】
#
# JBoss EAP ミドルウェアログのディレクトリ名に「ECS タスク ID」を使う旧方式は、
# efs-entrypoint.sh の LOG_ID_SOURCE=taskid モードに統合した。本ファイルは
# そのモードを既定にして efs-entrypoint.sh を呼ぶだけのラッパーである。
#
# 統合した理由:
#   以前はタスク ID 方式を別ファイル (旧 entrypoint.taskid.sh) で保守しており、
#     - 「1. configuration の復元 (configuration-seed → configuration)」
#     - die / dump_diag / is_writable による fail-fast と事前検証
#   が入っていなかった。そのまま ECS (readonlyRootFilesystem=true) で使うと
#   configuration が空のまま JBoss が起動し、logging.properties 不在で
#   server.log にも標準出力にも何も出ないまま失敗する。
#   さらに両方式とも `current` 経由で server.log を書いていたため、複数タスクが
#   並走した状態で日付が変わると、旧タスクのローテーションが新タスクの
#   server.log を server.log.<前日> へ rename する (docs/LOG_ROTATION.md)。
#   復元・検証・ログ出力先の固定 (pin) を 1 か所で保守し、方式の違いは
#   「ディレクトリ名の決め方」だけに限定した。
#
# タスク ID 方式に切り替える方法 (どれか 1 つ。イメージの再ビルドは不要):
#   (a) タスク定義の environment に LOG_ID_SOURCE=taskid を設定する (推奨)
#   (b) タスク定義の entryPoint を ["/usr/local/bin/efs-entrypoint-taskid.sh"] にし、
#       command に ["eap"] を指定する (entryPoint を上書きするとイメージの CMD は
#       引き継がれないため。起動コマンドが空なら本体が FATAL で止まる)
#
# 挙動 (efs-entrypoint.sh の LOG_ID_SOURCE=taskid と同一):
#   - ECS メタデータエンドポイント v4 (ECS_CONTAINER_METADATA_URI_V4) の TaskARN
#     からタスク ID を取り出し、/mnt/logs/<Component_name>/logs/<Service_Name>/mid/<タスクID>
#     を作成、current を張り替える。取得できない場合は「起動時刻-ランダム8桁」で代替する。
#   - 同一タスク内のコンテナ再起動 (ECS restartPolicy) では同じディレクトリを再利用する。
#   - JBoss の書き込み先は current ではなく mid/<タスクID> の実体パスへ固定される。
# =============================================================================
set -eu

# base の Dockerfile で本ファイルを efs-entrypoint.sh という名前で COPY すると
# 自分自身を exec し続けてしまうため、二重起動を検出して止める。
if [ -n "${EFS_ENTRYPOINT_TASKID_WRAPPED:-}" ]; then
    echo "[efs-entrypoint-taskid] FATAL: ラッパーが自分自身を呼び出しました。" >&2
    echo "[efs-entrypoint-taskid] FATAL: base の Dockerfile で entrypoint.sh を /usr/local/bin/efs-entrypoint.sh として COPY してください。" >&2
    exit 1
fi
export EFS_ENTRYPOINT_TASKID_WRAPPED=1

export LOG_ID_SOURCE="${LOG_ID_SOURCE:-taskid}"
exec /usr/local/bin/efs-entrypoint.sh "$@"

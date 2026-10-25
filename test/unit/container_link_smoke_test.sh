#!/bin/bash
# =============================================================================
# コンテナ専用リンク方式 (ECS_EFS_Dockerfile_Symboliclink_lite の直下の docker/) に
# patches/container_link_method.patch を当てたエントリポイントの簡易試験。
#
#   python patches/make_patches.py <ECS_EFS_Dockerfile_Symboliclink_lite> <作業ディレクトリ>
#   bash test/unit/container_link_smoke_test.sh <作業ディレクトリ>/container_link
#
# 偽の JBOSS_HOME・EFS を作り、dash / bash --posix / busybox sh でエントリポイントを動かして
#   - PERF_METRICS_ENABLED=true : 起動ログの枠・統計の引数・PREPEND_JAVA_OPTS の JFR・
#                                 perf/ が mid/<LOG_ID> (current ではない実体パス) にできること
#   - PERF_METRICS_ENABLED=false: 何も足さないこと
#   - perf-metrics.sh が無いイメージで true: 警告だけで JBoss (偽の standalone.sh) は起動すること
# を確かめる。収集プロセス自体は PERF_COLLECTORS=none で動かさない。
# =============================================================================
TREE="${1:?usage: container_link_smoke_test.sh <patched tree (has docker/base/entrypoint.sh)>}"
EP="$TREE/docker/base/entrypoint.sh"
PM="$TREE/docker/base/perf-metrics.sh"
if [ ! -f "$EP" ] || [ ! -f "$PM" ]; then echo "not found: $EP / $PM" >&2; exit 2; fi
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass+1)); echo "  PASS $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }
# 出力に含まれない (grep で見つからない) ことを確かめる
absent() { if printf '%s\n' "$1" | grep -q "$2"; then ok 1 "$3"; else ok 0 "$3"; fi; }
shells=("dash" "bash --posix" "busybox sh")
for SHELLCMD in "${shells[@]}"; do
  command -v "${SHELLCMD%% *}" >/dev/null 2>&1 || { echo "== $SHELLCMD (skip: not installed)"; continue; }
  echo "== $SHELLCMD"
  R=$(mktemp -d /tmp/clsmoke.XXXXXX)
  JH=$R/opt/jboss-eap; SD=$JH/standalone; EFS=$R/mnt/logs/intra-api-back/logs/intra-api
  mkdir -p "$SD/configuration" "$SD/configuration-seed" "$SD/tmp" "$SD/data" "$JH/bin" "$R/mnt/logs" "$R/work"
  # shellcheck disable=SC2016  # 書き出すファイルの中身なので展開しない
  printf 'handler.FILE.fileName=${org.jboss.boot.log.file\\:server.log}\n' > "$SD/configuration-seed/logging.properties"
  echo '<server/>' > "$SD/configuration-seed/standalone.xml"
  ln -s "$SD/tmp/jboss-log-target" "$SD/log"
  # shellcheck disable=SC2016  # 偽の standalone.sh: 受け取った引数と PREPEND_JAVA_OPTS を表示する
  printf '#!/bin/sh\necho "PREPEND=[$PREPEND_JAVA_OPTS]"\nfor a in "$@"; do echo "ARG[$a]"; done\n' > "$JH/bin/standalone.sh"
  chmod +x "$JH/bin/standalone.sh"
  run() {
    # shellcheck disable=SC2086
    env -i PATH="$PATH" HOME=/tmp JBOSS_HOME="$JH" EFS_LOG_DIR="$EFS" COMPONENT_ROLE=back Service_Name=intra-api Component_name=intra-api-back \
      PERF_METRICS_SCRIPT="$PM" PERF_WORK_DIR="$R/work" PERF_COLLECTORS=none PERF_JFR=true "$@" \
      $SHELLCMD "$EP" "$JH/bin/standalone.sh" -b 0.0.0.0 2>&1
  }
  out=$(run PERF_METRICS_ENABLED=true); rc=$?
  ok $rc "exit code ($rc)"
  echo "$out" | grep -q '性能試験用メトリクス収集: 有効'; ok $? 'banner shown'
  echo "$out" | grep -q 'ARG\[-Dwildfly.datasources.statistics-enabled=true\]'; ok $? 'statistics args added'
  echo "$out" | grep -q 'ARG\[-b\]'; ok $? 'original args kept'
  echo "$out" | grep -q 'PREPEND=\[-XX:StartFlightRecording'; ok $? 'JFR in PREPEND_JAVA_OPTS'
  d=""
  for _p in "$EFS"/mid/*/perf; do case "$_p" in */current/perf) ;; *) [ -d "$_p" ] && d="$_p" ;; esac; done
  [ -n "$d" ] && [ -f "$d/perf_meta.csv" ]; ok $? "perf/ under the concrete mid/<LOG_ID> ($d)"
  grep -q 'output_dir,".*/mid/[^/]*/perf"' "$d/perf_meta.csv" 2>/dev/null && ! grep -q 'output_dir,".*/current/' "$d/perf_meta.csv"
  ok $? 'output_dir is the concrete path (not current)'
  out=$(run PERF_METRICS_ENABLED=false); rc=$?
  ok $rc "disabled: exit code ($rc)"
  absent "$out" '性能試験用メトリクス収集' 'disabled: no banner'
  absent "$out" 'statistics-enabled' 'disabled: no extra args'
  out=$(run PERF_METRICS_ENABLED=true PERF_METRICS_SCRIPT=/nonexistent); rc=$?
  ok $rc "missing script: JBoss still starts ($rc)"
  echo "$out" | grep -q 'WARN: PERF_METRICS_ENABLED=true ですが'; ok $? 'missing script: warning'
  rm -rf "$R"
done
echo "RESULT: PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]

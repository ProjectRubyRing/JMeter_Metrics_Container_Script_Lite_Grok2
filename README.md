# JMeter 性能試験用メトリクス収集とモノトーン Excel レポート

ECS (Fargate) のコンテナで動く **UBI 9.8 + Red Hat build of OpenJDK 21 + JBoss EAP 8.1** から、
JMeter などの性能試験の間に **CloudWatch Container Insights (拡張) では見えない値だけ** を一定間隔で集め、
Windows 11 の PowerShell で **モノトーンの Excel レポート** にします。

| 区分 | 道具 | 何が分かるか |
|---|---|---|
| ① | jboss-cli | DB 接続プール (使用中・待ち・取得失敗・取得時間・XA)、HTTP リスナー、セッション、IO ワーカー (HTTP 処理スレッド)、EE / EJB スレッドプール、トランザクション、JVM (スレッド・クラス・ヒープ・NIO バッファ・サーバーの状態) |
| ② | jstat / jcmd / JFR | ヒープ各領域・GC の回数と時間・GC の原因・セーフポイント・JIT、G1 のリージョン・メタスペース・コードキャッシュ・ネイティブメモリ、スレッドの状態 (DB 接続待ちを含む)、GC ごとの停止時間、CPU を使ったメソッド、ロック待ち、I/O 待ち |
| ③ | top / ps / proc | プロセス別・JBoss のスレッド別 CPU、JBoss のスレッドの用途別 (HTTP 処理・GC・JIT など) の CPU と状態、FD 数、TCP 接続 (状態・接続先) |
| ④ | ECS メタデータ・cgroup・jcmd | `-XX:ActiveProcessorCount` の要否の判定と根拠 (このコンテナの CPU の取り分 ⇔ JVM が認識した CPU 数)、CPU の待ち・steal・スロットリングの推移 |

Container Insights (拡張) で見られるタスク・コンテナの CPU 使用率 / 使用量・メモリ使用量・ネットワーク / ストレージの転送量・再起動回数は取得しません。

性能試験用の実装は **`docker/base/perf-metrics.sh` の 1 ファイル** にまとめてあります (POSIX sh、3.0.0)。
ビルド引数 `PERF_METRICS_ENABLED=true` でビルドしたイメージだけに入り、エントリポイントが起動時に読み込みます。
`false` (既定) でビルドすると、イメージから削除されて本番と同じ中身になります。

---

## 1. 構成

```
docker/base/perf-metrics.sh        性能試験用の実装 (①②③④ の収集・判定・JFR の CSV 変換・状態確認・まとめ)
docker/base/entrypoint.sh          pin 方式のエントリポイント + 6-B (有効なときだけ perf-metrics.sh を読み込むフック)
docker/base/Dockerfile             perf-metrics.sh を配置 (base では置くだけ)
docker/front/Dockerfile            ビルド引数 PERF_METRICS_ENABLED / PERF_INTERVAL / PERF_PROCPS
docker/back/Dockerfile             同上
report/New-PerfMetricsReport.ps1   Excel レポート (Windows PowerShell 5.1 / PowerShell 7。Excel 不要)
ecs/taskdef-perf.example.jsonc     性能試験用タスク定義の例 (/tmp のボリューム・メモリ・cpu・ECS Exec)
patches/                           元の ECS_EFS_Dockerfile_Symboliclink_lite へ当てるパッチ (pin 方式 / コンテナ専用リンク方式)
docs/EXPLANATION.md                解説 (仕組み・歴史・背景・小学生にもわかる説明)
test/                              試験 (単体・エントリポイント・結合・レポート)
```

`docker/` は元のプロジェクト `ECS_EFS_Dockerfile_Symboliclink_lite/pin_method/docker` (正本・本番と同じ `CMD=eap`) と同じ中身に、
性能試験用の追加だけをしたものです。追加以外の動作は変えていません (元の試験 333 件が変更前後とも合格)。

## 2. 使い方

### 2-1. ビルド

```sh
# base (全サービス共通)
docker build -t myapp-base:latest --build-arg BASE_IMAGE=<UBI 9.8 + OpenJDK 21 + JBoss EAP 8.1 のイメージ> docker/base

# 性能試験用 (タグは本番と分ける。Service_Name / Component_name は本番と同じ値 = ログの出力先が本番と同じ)
docker build -t intra-web-front:perf \
  --build-arg BASE_IMAGE=myapp-base:latest \
  --build-arg Service_Name=intra-web \
  --build-arg Component_name=intra-web-front \
  --build-arg PERF_METRICS_ENABLED=true \
  --build-arg PERF_INTERVAL=10 \
  docker/front

# 本番用 (既定の false。perf-metrics.sh はイメージから削除される)
docker build -t intra-web-front:latest --build-arg BASE_IMAGE=myapp-base:latest \
  --build-arg Service_Name=intra-web --build-arg Component_name=intra-web-front docker/front
```

| ビルド引数 | 既定 | 意味 |
|---|---|---|
| `PERF_METRICS_ENABLED` | `false` | `true` で perf-metrics.sh を残して有効化。`true` / `false` 以外はビルドエラー |
| `PERF_INTERVAL` | `10` | 収集の既定の間隔 (秒)。タスク定義の environment でも上書きできる |
| `PERF_PROCPS` | `auto` | top / ps (procps-ng) が無ければ microdnf / dnf で入れる。入らなくてもビルドは続き、③ は /proc から同じ項目を算出する (`true` = 入らなければ失敗、`false` = 入れない) |

有効なイメージは、起動時のログ (CloudWatch Logs) に次の枠を出します。

```
[perf-metrics] [start] ======================================================================
[perf-metrics] [start]  性能試験用メトリクス収集: 有効  (perf-metrics.sh 3.0.0 / PERF_METRICS_ENABLED=true)
[perf-metrics] [start]  出力先 : /mnt/logs/<Component_name>/logs/<Service_Name>/mid/<LOG_ID>/perf
[perf-metrics] [start]  ① jboss-cli : 10 秒間隔  DB 接続プール・HTTP・セッション・スレッドプール・トランザクション・JVM
[perf-metrics] [start]  ② jstat     : 10 秒間隔  ヒープ・GC・GC 原因・セーフポイント   jcmd: 60 秒間隔  (...)
[perf-metrics] [start]     JFR       : JBoss の起動時から記録 (統計イベント 10 秒間隔、settings=default、最大 24h / 1g)
[perf-metrics] [start]  ③ top / ps  : 10 / 10 秒間隔  ...
[perf-metrics] [start]  ④ CPU 数    : JVM 起動後に ActiveProcessorCount の要否を判定 (cpu_env.csv) ...
[perf-metrics] [start]  ※ Container Insights (拡張) で見られる CPU・メモリ・ネットワーク・ストレージの使用量は取得しません
[perf-metrics] [start] ======================================================================
```

イメージに perf-metrics.sh が無いのに `PERF_METRICS_ENABLED=true` を渡した場合は警告だけを出し、JBoss はそのまま起動します。
収集側で何が起きても JBoss の起動は止めません。

### 2-2. タスク定義

[ecs/taskdef-perf.example.jsonc](ecs/taskdef-perf.example.jsonc) を参照してください。本番との違いは次のとおりです。

- **`/tmp` に書き込めるボリューム** (jstat / jcmd が JVM に接続するため)。フロント / バックで別のボリュームにする
- **メモリの余裕** (収集用の JVM などで RSS 合計 200MB 前後)
- **コンテナの `cpu`** (④ の判定で「このコンテナの取り分」を確実に求めるため。未指定ならタスクの cpu ÷ JVM のコンテナ数)
- **ECS Exec** (状態確認などのコマンドを使う場合。`--enable-execute-command` とタスクロールの `ssmmessages:*` 権限)

### 2-3. 出力先

`readonlyRootFilesystem=true` でも書き込める EFS 上の、JBoss のログと同じタスク専用ディレクトリの下に書きます。

```
/mnt/logs/<Component_name>/logs/<Service_Name>/mid/<LOG_ID>/perf/
  (最後に起動したタスクの分は /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current/perf/ から辿れる)
```

`mid/current` は全タスクが共有して張り替えるリンクなので、書き込みには使いません (pin 方式で server.log を実体パスへ固定しているのと同じ理由)。
FIFO などの作業ファイルは `/tmp/perf-metrics-<Component_name>` に置きます。

### 2-4. 試験中・試験後の操作 (ECS Exec)

```sh
aws ecs execute-command --cluster <クラスター> --task <タスク ID> --container intra-web-front --interactive \
  --command "/usr/local/bin/perf-metrics.sh status"
```

| コマンド | 内容 |
|---|---|
| `perf-metrics.sh status` | 収集プロセスと各 CSV の最終更新、JFR の状態 |
| `perf-metrics.sh cpu-check` | ④ の判定をその場で表示 |
| `perf-metrics.sh threaddump` | スレッドダンプを 1 回取得 (`perf/threaddump/`) |
| `perf-metrics.sh jfr-dump` | 記録中の JFR をファイルに書き出す (`perf/jfr/dump/`) |
| `perf-metrics.sh jfr-csv` | JFR を CSV (`jfr_*.csv`) に変換 (低い優先度で実行。試験の後に実行を推奨) |
| `perf-metrics.sh stop` | 収集を止める (JFR は JBoss 側で記録を続ける) |
| `perf-metrics.sh pack` | jfr-csv の後、perf/ を tar 1 ファイルにまとめる (.jfr は `PERF_PACK_JFR=true` のときだけ含める) |

JBoss を止めると、JFR の記録は `perf/jfr/perf_<pid>_<日時>.jfr` に書き出されます。

### 2-5. Excel レポート (Windows 11 の PowerShell)

perf/ ディレクトリ (または pack の tar) を、EFS をマウントできる環境から Windows にコピーして実行します。

```powershell
# perf/ ディレクトリ 1 つ
powershell -NoProfile -ExecutionPolicy Bypass -File .\report\New-PerfMetricsReport.ps1 D:\perf-results\perf -OutputPath D:\reports

# mid/ や logs/ ごとコピーした場合 (下にある perf/ をすべて探して 1 つずつ作成。mid/current 経由の重複は除く)
.\report\New-PerfMetricsReport.ps1 D:\efs-copy\logs -OutputPath D:\reports

# pack の tar、JMeter の実行時間帯に絞る、作成後に開く
.\report\New-PerfMetricsReport.ps1 .\perf_20261024141140-6jlezcax_20261024_231417.tar -From "2026-10-24 23:12" -To "2026-10-24 23:14" -Open
```

**ファイル名** には、ログの出力先 `/mnt/logs/<コンポーネント>/logs/<サービス>/mid/...` から、コンテナとサービスの名前を入れます。

| 出力先の値 | ファイル名に入る名前 |
|---|---|
| `front` / `back` (`intra-web-front`・`interapi-back` のように末尾が front / back のものも) | `フロントコンテナ` / `バックコンテナ` |
| `intra-web` / `intra-api` / `inter-api` / `sf-api` (`interapi`・`sfapi`・`sf_api` などの表記ゆれも) | `intra-webサービス` / `intra-apiサービス` / `inter-apiサービス` / `sf-apiサービス` |

例: `perf_report_フロントコンテナ_intra-webサービス_20261024141140-6jlezcax.xlsx`

| パラメーター | 内容 |
|---|---|
| `-InputPath` | perf/ ディレクトリ、その親 (mid/・logs/ など)、`.tar` / `.tar.gz` / `.zip` |
| `-OutputPath` | 出力先ディレクトリ (無ければ作成)。`.xlsx` で終わるパスならそのファイル名 (perf/ が 1 つのとき) |
| `-From` / `-To` | この時刻の範囲のデータだけを使う |
| `-UseRecordedTime` | 時刻を PC のタイムゾーンに換算せず、コンテナで記録した時刻のまま表示する |
| `-ConvertJfr` / `-JavaPath` | jfr_*.csv が無いとき、perf/jfr/ の .jfr を PC の JDK 17 以降で変換する (入力に含まれる変換プログラムが perf-metrics.sh 3.0.0 のものと一致するときだけ実行) |
| `-MaxRows` | 1 シートの最大行数 (既定 200000) |
| `-Title` / `-Open` | タイトル / 作成後に Excel で開く |

**シート (最大 29)**: サマリー (所見・④ の判定・主要指標・データソース別・リスナー別) / グラフ (①～④ の 49 グラフ、時間軸は共通) /
①DB接続プール・HTTP・セッション・スレッドプール・IOワーカー・トランザクション・JVM（CLI） /
②ヒープ・GC（jstat）・ヒープ（jcmd）・コードキャッシュ・NMT・スレッド状態・GC（JFR）・JVM統計（JFR）・JFR上位・JFR記録 /
③top概要・topプロセス・topスレッド・ps・JBossスレッド・FD・TCP / ④CPU判定・CPUスケジューリング / 収集ログ・収集情報・凡例。
フォントは Meiryo UI、黒・グレーのモノトーンで、グラフは線の種類で系列を区別します。Excel のインストールは不要です (Office Open XML を直接生成)。

## 3. 出力ファイル

| 区分 | ファイル | 主な列 |
|---|---|---|
| 共通 | `perf_meta.csv` `collector.log` | 収集条件・環境・ECS メタデータ / 収集プロセスのログ |
| ① | `cli_datasource.csv` | データソース別の InUse / Active / Idle / Wait / BlockingFailure / 取得・待ち・使用・作成時間 / XA の commit・rollback・prepare |
| ① | `cli_undertow.csv` `cli_session.csv` | リスナー別のリクエスト数・エラー数・処理時間 / デプロイメント別のセッション数 |
| ① | `cli_io_worker.csv` `cli_threadpool.csv` | IO ワーカーの使用中タスクスレッド・上限・キュー・接続数 / EE・EJB スレッドプール |
| ① | `cli_transactions.csv` `cli_jvm.csv` | コミット・中断・タイムアウト / スレッド・クラス・ヒープ・NIO バッファ・サーバーの状態・処理中のリクエスト |
| ② | `jvm_jstat_gc.csv` | jstat のカスタムオプション perfgc (-gc の全列 + セーフポイント・スレッド・クラス・JIT・直近の GC の原因) |
| ② | `jvm_jcmd_heap.csv` `jvm_codecache.csv` `jvm_thread_states.csv` `jvm_nmt.csv` | GC.heap_info / Compiler.codecache / Thread.print の用途別集計 / VM.native_memory (PERF_NMT=summary) |
| ② | `jfr/*.jfr` → `jfr_gc.csv` `jfr_stats.csv` `jfr_hot_methods.csv` `jfr_contention.csv` `jfr_io.csv` `jfr_vm_operations.csv` `jfr_env.csv` `jfr_summary.csv` | JFR (jfr-csv / pack で CSV に変換) |
| ③ | `os_top_summary.csv` `os_top_process.csv` `os_top_threads.csv` `os_ps.csv` | top の概要・プロセス・JBoss のスレッド上位 / ps |
| ③ | `os_jboss_threads.csv` `os_jboss_proc.csv` | JBoss のスレッドの用途別 CPU・状態 / FD・TCP・RSS |
| ④ | `cpu_env.csv` `cpu_sched.csv` | 判定の材料と結果 / CPU の内訳・実行待ち・PSI・スロットリング・JBoss の用途別 CPU (コア) |

## 4. ④ `-XX:ActiveProcessorCount` の判定

Fargate は CPU を上限 (CFS クォータ) ではなく **CPU シェア** (取り分の比率) で配分します。JVM (JDK 19 以降と、17.0.5・11.0.17 以降の更新版) は
CPU シェアを CPU 数の計算に使わない (JDK-8281181) ため、クォータの無い Fargate では **タスクの VM の CPU 数** をそのまま使います。
すると GC・JIT・Undertow のスレッド数が取り分より多い CPU を前提に作られ、CPU を奪い合います。

perf-metrics.sh は JVM の起動後に、ECS タスクメタデータ v4 から「このコンテナの取り分」を求め、JVM が認識した CPU 数と比べます。

| 取り分の求め方 (上から順に) | |
|---|---|
| コンテナ定義の `cpu` (64 ユニット以上) | ÷ 1024 = vCPU |
| タスクの `cpu` | ÷ JVM を動かすコンテナの数 (サイドカーは名前・イメージで除外。`PERF_JVM_CONTAINERS` で上書き可) |
| cgroup の CPU クォータ | (Fargate 以外) |

| 判定 | 条件 | 推奨値 |
|---|---|---|
| **要** | JVM の CPU 数 > 取り分 (四捨五入、最小 1) | `-XX:ActiveProcessorCount=<取り分>` |
| 要検討 | JVM の CPU 数 < 取り分 | 増やせる |
| 不要 | 一致 | ― |
| 設定済み | すでに指定されている (タスクの vCPU を超えていれば「要確認」) | ― |
| 判定不可 | 取り分または JVM の CPU 数が分からない | ― |

レポートの「④CPU判定」シートには、判定と一緒に、試験中の実測 (JBoss の CPU 使用量と取り分・GC / JIT の CPU・実行待ちのスレッド・
非自発的なコンテキストスイッチ) と、CPU 数から自動で決まる値 (ParallelGCThreads・ConcGCThreads・CICompilerCount・IO スレッド数など) を並べます。
指定する場所は JBoss の JVM オプションです (standalone.conf の `JAVA_OPTS`、またはタスク定義の環境変数 `PREPEND_JAVA_OPTS`)。

## 5. 主な環境変数 (タスク定義で上書き可。全項目は perf-metrics.sh の先頭)

| 変数 | 既定 | 意味 |
|---|---|---|
| `PERF_INTERVAL` | 10 | 各収集の既定の間隔 (秒) |
| `PERF_CLI_INTERVAL` `PERF_JSTAT_INTERVAL` `PERF_JFR_INTERVAL` `PERF_TOP_INTERVAL` `PERF_PS_INTERVAL` `PERF_PROC_INTERVAL` | `PERF_INTERVAL` | 収集ごとの間隔 |
| `PERF_JCMD_INTERVAL` | 60 | jcmd の間隔 (1 回ごとに JVM を起動するため長め) |
| `PERF_COLLECTORS` | `cli jstat jcmd top ps proc` | 動かす収集 (`none` で全停止) |
| `PERF_TZ` | コンテナの TZ | CSV の timestamp 列のタイムゾーン |
| `PERF_ENABLE_STATISTICS` | true | standalone.sh に `-Dwildfly.datasources / undertow / transactions .statistics-enabled=true` を足す |
| `PERF_JFR` / `PERF_JFR_SETTINGS` | true / default | JFR を記録するか / 設定 (default・profile・.jfc) |
| `PERF_NMT` | off | `summary` で Native Memory Tracking (JVM が数 % 重くなる) |
| `PERF_THREADDUMP` | summary | `full` でスレッドダンプの全文も保存 |
| `PERF_TOP_THREADS` | 10 | JBoss のスレッド別 CPU の上位件数 |
| `PERF_JVM_CONTAINERS` | 自動 | ④ タスク内で JVM を動かすコンテナの数 |

## 6. 既存プロジェクトへの適用

元の `ECS_EFS_Dockerfile_Symboliclink_lite` に当てるパッチを用意しています (このリポジトリの docker/ と同じ変更)。

```sh
# 元のリポジトリの直下で
git apply --check --directory=pin_method <このリポジトリ>/patches/pin_method.patch   # pin 方式 (正本)
git apply         --directory=pin_method <このリポジトリ>/patches/pin_method.patch
git apply --check <このリポジトリ>/patches/container_link_method.patch               # 直下の docker/ (コンテナ専用リンク方式)
git apply         <このリポジトリ>/patches/container_link_method.patch
```

パッチは `python patches/make_patches.py <元のリポジトリ>` で作り直せます。

## 7. 試験と結果 (2026-10-25)

| 試験 | 内容 | 結果 |
|---|---|---|
| 元の entrypoint 試験 (pin_method/test/local) | 変更前・変更後のエントリポイントを dash / bash --posix / busybox sh で | **PASS 333 / FAIL 0** (両方) |
| `test/unit/perf_unit_test.sh` | jboss-cli・jcmd・top・ps・ECS メタデータの解析と ④ の判定 (gawk・RHEL 9 の gawk・mawk・busybox awk) | **PASS 224 / FAIL 0** |
| `test/unit/perf_hook_test.sh` | エントリポイントのフック (有効 / 無効 / スクリプト無し / 値が不正 など) × 3 シェル | **PASS 135 / FAIL 0** |
| `test/unit/container_link_smoke_test.sh` | パッチを当てたコンテナ専用リンク方式のエントリポイント × 3 シェル | **PASS 36 / FAIL 0** |
| `test/e2e/run_rootfs_it.sh` | UBI 9.8 の rootfs + Red Hat OpenJDK 21.0.12.1 + WildFly 35.0.1 (EAP 8.1 に近い版) で XA の DB アクセスに負荷をかけ、偽の ECS メタデータ (タスク 1 vCPU・コンテナ 512 ユニット) で全 CSV の列と値を確認 | **すべて OK** (2 回)。④ は「要」(JVM 4 CPU ⇔ 取り分 0.5 vCPU → `ActiveProcessorCount=1`)。JFR 271,081 イベントを CSV 化。収集処理の CPU は平均 1 コアの 1.7% |
| `test/report/Test-PerfMetricsReport.ps1 -Excel` | レポート: ディレクトリ・親ディレクトリ (front / back・mid/current の重複)・名前の表記ゆれ・tar・期間指定、全ブックの XML の構造、Excel で修復なしに開けること | **PASS 32 / FAIL 0** |
| `test/report/check_report_script.py` | レポートの起動部が ASCII・ブロックコメントの終わり記号なし・PerfJfrCsv.java のハッシュが一致 | OK |

レポートの処理時間 (Windows PowerShell 5.1): 2.5 分の試験結果で約 5 秒、約 12 万行 (1 時間の試験の 24 倍相当のデータ) で約 55 秒。

### 試験の流し方

```sh
# 単体・フック (WSL / Linux。dash・busybox・mawk があれば全組み合わせ)
bash test/unit/perf_unit_test.sh gawk mawk "busybox awk"
bash test/unit/perf_hook_test.sh
# パッチを当てたコンテナ専用リンク方式
python patches/make_patches.py <ECS_EFS_Dockerfile_Symboliclink_lite> /tmp/pw
bash test/unit/container_link_smoke_test.sh /tmp/pw/container_link

# 結合試験 (Docker 不要。root 不要の unshare + chroot)
#   rootfs: Red Hat の ubi9/openjdk-21-runtime イメージの中身を展開したもの。Docker が使える場合の例:
#     cid=$(docker create registry.access.redhat.com/ubi9/openjdk-21-runtime:latest)
#     mkdir -p ~/rhjdk21/rootfs && docker export "$cid" | tar -x -C ~/rhjdk21/rootfs && docker rm "$cid"
#   WildFly: https://github.com/wildfly/wildfly/releases/download/35.0.1.Final/wildfly-35.0.1.Final.tar.gz
ROOTFS=~/rhjdk21/rootfs WILDFLY_TGZ=~/wildfly-35.0.1.Final.tar.gz bash test/e2e/run_rootfs_it.sh 120 1 512 /tmp/it-result
```

```powershell
# レポート (Windows PowerShell 5.1。-Excel で Excel に開かせて修復が出ないことも確かめる)
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\report\Test-PerfMetricsReport.ps1 -Excel
python .\test\report\check_report_script.py
```

## 8. 未検証・制約

- **実際の AWS Fargate・JBoss EAP 8.1 の製品版では動かしていません。** 結合試験は WSL 上の UBI 9.8 rootfs (Red Hat OpenJDK 21.0.12.1) と
  WildFly 35.0.1 で行い、ECS タスクメタデータは偽のサーバーで代用しました。Fargate の cgroup・PSI・steal の値の出方は実環境で確認してください。
- 本物の UBI イメージへの procps-ng の導入 (`PERF_PROCPS=auto`) と top / ps の経路は、出力の解析だけを Ubuntu の procps-ng 3.3.17 の出力で試験しました
  (結合試験は top / ps の無い rootfs で /proc の代替経路を使用)。
- Docker の `--read-only` でのコンテナとしての起動試験 (Docker Desktop) は行っていません。
- レポートは Windows PowerShell 5.1 で試験しました (PowerShell 7 は未試験。言語の機能は 5.1 の範囲だけを使っています)。
- Undertow の処理時間は `record-request-start-time=true` のリスナーだけ記録されます (既定は false。応答時間は JMeter の結果で確認)。

## 9. 参考

- AWS Containers Blog「JVM memory, CPU, and classpath best practices for Java containers on AWS」(2026-07-20)
  https://aws.amazon.com/blogs/containers/jvm-memory-cpu-and-classpath-best-practices-for-java-containers-on-aws/
- JDK-8281181「Do not use CPU Shares to compute active processor count」(JDK 19、17.0.5・11.0.17・18.0.2 にバックポート)
  https://bugs.openjdk.org/browse/JDK-8281181
- Container Insights with enhanced observability for Amazon ECS (2024-12-02 提供開始)
  https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/container-insights-detailed-ecs-metrics.html
- Amazon ECS タスクメタデータエンドポイント v4
  https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v4-fargate.html

"""性能試験用メトリクス収集を、元の ECS_EFS_Dockerfile_Symboliclink_lite へ当てるパッチを作る。

  pin_method.patch           : pin 方式 (正本。本番と同じ CMD=eap) の docker/ に対する差分
                               = このリポジトリの docker/ と元の pin_method/docker/ の差分
  container_link_method.patch: コンテナ専用リンク方式 (元リポジトリの直下) の docker/ に対する差分
                               = 直下の docker/ に同じ変更を機械的に当てたもの

使い方 (このリポジトリの直下で):
  python patches/make_patches.py <ECS_EFS_Dockerfile_Symboliclink_lite のパス> [<作業ディレクトリ>]

当て方 (元リポジトリの直下で):
  git apply --check --directory=pin_method <このリポジトリ>/patches/pin_method.patch   # pin_method/ に当てる
  git apply         --directory=pin_method <このリポジトリ>/patches/pin_method.patch
  git apply --check <このリポジトリ>/patches/container_link_method.patch               # 直下の docker/ に当てる
  git apply         <このリポジトリ>/patches/container_link_method.patch
"""
import difflib
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = sys.argv[1]
WORK = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, '_work')
FILES = ['docker/base/Dockerfile', 'docker/base/entrypoint.sh', 'docker/base/perf-metrics.sh',
         'docker/front/Dockerfile', 'docker/back/Dockerfile']
NL = chr(10)


def read(p):
    if not os.path.exists(p):
        return None
    # 元リポジトリは core.autocrlf=true の Windows 作業ツリーだと CRLF になっている。
    # リポジトリの中身 (インデックス) は LF なので、LF にそろえて比較・パッチ化する
    with open(p, encoding='utf-8', newline='') as f:
        return f.read().replace(chr(13) + NL, NL)


def udiff(old_root, new_root, out):
    chunks = []
    for rel in FILES:
        a = read(os.path.join(old_root, rel))
        b = read(os.path.join(new_root, rel))
        if a == b:
            continue
        al = [] if a is None else a.splitlines(keepends=True)
        bl = [] if b is None else b.splitlines(keepends=True)
        fa = '/dev/null' if a is None else 'a/' + rel
        d = list(difflib.unified_diff(al, bl, fa, 'b/' + rel, n=3))
        if a is None:
            chunks.append('diff --git a/%s b/%s%snew file mode 100755%s' % (rel, rel, NL, NL))
        else:
            chunks.append('diff --git a/%s b/%s%s' % (rel, rel, NL))
        for line in d:
            chunks.append(line if line.endswith(NL) else line + NL + '\\ No newline at end of file' + NL)
    with open(out, 'w', encoding='utf-8', newline=NL) as f:
        f.write(''.join(chunks))
    print('wrote', out)


def rep(text, old, new, path):
    if text.count(old) != 1:
        raise SystemExit('挿入位置が見つかりません (%s): %s' % (path, old[:60]))
    return text.replace(old, new)


def between(text, start, end, include_end=False):
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j + (len(end) if include_end else 0)]


# ---- 1. pin 方式 (正本) ----
udiff(os.path.join(SRC, 'pin_method'), ROOT, os.path.join(HERE, 'pin_method.patch'))

# ---- 2. コンテナ専用リンク方式 (直下): 同じ変更を当てる ----
dst = os.path.join(WORK, 'container_link')
if os.path.exists(dst):
    shutil.rmtree(dst)
shutil.copytree(os.path.join(SRC, 'docker'), os.path.join(dst, 'docker'))
for _d, _s, _fs in os.walk(os.path.join(dst, 'docker')):
    for _f in _fs:
        _p = os.path.join(_d, _f)
        _t = read(_p)
        open(_p, 'w', encoding='utf-8', newline=NL).write(_t)
mine = {rel: read(os.path.join(ROOT, rel)) for rel in FILES}

# perf-metrics.sh はそのまま
shutil.copyfile(os.path.join(ROOT, 'docker/base/perf-metrics.sh'), os.path.join(dst, 'docker/base/perf-metrics.sh'))

# base/Dockerfile: エントリポイントの COPY の後ろに perf-metrics.sh の配置
p = os.path.join(dst, 'docker/base/Dockerfile')
t = read(p)
m = mine['docker/base/Dockerfile']
block = between(m, NL + '# 性能試験用メトリクス収集 (perf-metrics.sh)', "&& sed -i 's/\\r$//' /usr/local/bin/perf-metrics.sh" + NL, True)
anchor = "    && sed -i 's/\\r$//' /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh" + NL
t = rep(t, anchor, anchor + block, p)
t = rep(t, '#   - readonlyRootFilesystem=true 対応のエントリポイントスクリプト配置' + NL,
        '#   - readonlyRootFilesystem=true 対応のエントリポイントスクリプト配置' + NL
        + '#   - 性能試験用メトリクス収集 perf-metrics.sh の配置 (有効化は front / back のビルド引数)' + NL, p)
open(p, 'w', encoding='utf-8', newline=NL).write(t)

# front / back の Dockerfile: ビルド例の追記と、実行ユーザーへ戻す直前にビルド引数のブロック
for side in ('front', 'back'):
    m = mine['docker/%s/Dockerfile' % side]
    example = between(m, '#' + NL + '#   # 性能試験用 (メトリクス収集を有効にする', '# ====')
    s0 = m.rindex('# --- ', 0, m.index('性能試験用メトリクス収集 (ビルド引数で有効化 / 無効化)'))
    block = m[s0:m.index('# 実行ユーザーへ戻す')]
    p = os.path.join(dst, 'docker/%s/Dockerfile' % side)
    t = read(p)
    t = rep(t, '# 実行ユーザーへ戻す', block + '# 実行ユーザーへ戻す', p)
    # ビルド例は最初の「# ====」の区切り (ヘッダーの終わり) の直前に足す
    head_end = t.index(NL + '# ====', t.index('docker build')) + 1
    t = t[:head_end] + example + t[head_end:]
    open(p, 'w', encoding='utf-8', newline=NL).write(t)

# entrypoint.sh: 説明の追記と、preflight OK の直前にフック
p = os.path.join(dst, 'docker/base/entrypoint.sh')
t = read(p)
m = mine['docker/base/entrypoint.sh']
hook = m[m.index('# =============================================================================' + NL + '# 6-B. 性能試験用メトリクス収集'):m.index('say "preflight OK. starting: $(mask_args "$@")"')]
t = rep(t, 'say "preflight OK (log-id-mode=', hook + 'say "preflight OK (log-id-mode=', p)
intro = between(m, '#   6-B. (性能試験用イメージのみ)', '#      収集側で何が起きても JBoss の起動は止めない。' + NL, True)
t = rep(t, '#   5. サービスが intra-web かつフロントコンテナの場合のみ、' + NL + '#      EFS 上に /mnt/data/pdf がなければ作成する。' + NL,
        '#   5. サービスが intra-web かつフロントコンテナの場合のみ、' + NL + '#      EFS 上に /mnt/data/pdf がなければ作成する。' + NL + intro, p)
doc = m[m.index('#   PERF_METRICS_ENABLED : false (既定) | true' + NL):m.index('# =============================================================================' + NL + 'set -eu')]
t = rep(t, '#                       へ固定したまま起動する (旧イメージの段階移行用)' + NL,
        '#                       へ固定したまま起動する (旧イメージの段階移行用)' + NL + doc, p)
open(p, 'w', encoding='utf-8', newline=NL).write(t)

udiff(SRC, dst, os.path.join(HERE, 'container_link_method.patch'))
print('container_link tree:', dst)

"""Static checks for report/New-PerfMetricsReport.ps1 (run after editing the report).

  - the bootstrap part (before the program block) is ASCII only, so Windows PowerShell 5.1
    can parse it whatever the file encoding is
  - the program block <#PERFRPT-MAIN ... PERFRPT-MAIN#> does not contain "#>" (it would end the block comment)
  - no tab characters
  - the SHA-256 in $JfrJavaSha256 is the one of the PerfJfrCsv.java that perf-metrics.sh writes
    (perf-metrics.sh: printf '%s\n' "${PM_JFR_JAVA}"), so -ConvertJfr accepts it
  - the file is UTF-8 (BOM) with CRLF line endings

usage: python test/report/check_report_script.py
"""
import hashlib
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPORT = os.path.join(ROOT, 'report', 'New-PerfMetricsReport.ps1')
PERF = os.path.join(ROOT, 'docker', 'base', 'perf-metrics.sh')
problems = []

raw = open(REPORT, 'rb').read()
if not raw.startswith(b'\xef\xbb\xbf'):
    problems.append('report: no UTF-8 BOM')
if raw.count(b'\n') != raw.count(b'\r\n'):
    problems.append('report: not CRLF everywhere (LF=%d CRLF=%d)' % (raw.count(b'\n'), raw.count(b'\r\n')))
s = raw.decode('utf-8-sig').replace('\r\n', '\n')
nl = chr(10)
start = s.index(nl + '<#PERFRPT-MAIN' + nl) + 1
end = s.rindex('PERFRPT-MAIN#>')
boot = s[s.index('#requires'):start]
bad = sorted(set(c for c in boot if ord(c) > 127))
if bad:
    problems.append('report: non-ASCII characters in the bootstrap: %r' % bad[:10])
body = s[start + len('<#PERFRPT-MAIN'):end]
if '#>' in body:
    problems.append('report: "#>" inside the program block at line %d' % (s[:start + len('<#PERFRPT-MAIN') + body.index('#>')].count(nl) + 1))
if '\t' in s:
    problems.append('report: tab character at line %d' % (s[:s.index('\t')].count(nl) + 1))

pm = io.open(PERF, encoding='utf-8').read()
a = pm.index("PM_JFR_JAVA='") + len("PM_JFR_JAVA='")
b = pm.index(nl + "}'" + nl, a) + 2
expect = hashlib.sha256((pm[a:b] + nl).encode('utf-8')).hexdigest().upper()
m = re.search(r"\$JfrJavaSha256 = @\(([^)]*)\)", s)
found = re.findall(r"'([0-9A-F]{64})'", m.group(1)) if m else []
if expect not in found:
    problems.append('report: $JfrJavaSha256 %s does not contain the PerfJfrCsv.java hash %s of perf-metrics.sh' % (found, expect))

for p in problems:
    print('NG ', p)
print('report checks: %s (PerfJfrCsv.java sha256 %s...)' % ('NG' if problems else 'OK', expect[:16]))
sys.exit(1 if problems else 0)

"""検証用の WAR (perftest.war) を作る。

db.jsp  : データソースから接続を取り、指定ミリ秒保持してから返す (接続プールの待ちを起こす)。
          1 リクエストごとに KB 単位のゴミを作って GC を起こし、HTTP セッションも作る。
          パラメーター (すべて任意):
            ms=<保持ミリ秒>   kb=<確保する KB>   xa=1 (XA データソース ExampleXADS を
            UserTransaction の中で使う。XA・トランザクションの統計が増える)
            cpu=<ミリ秒> (CPU を回す)   lock=<ミリ秒> (共有ロックを握る。JFR のロック待ち)
            ex=<回数> (例外を投げて捕まえる)   sock=<ミリ秒> (自分の slow.jsp を HTTP で呼ぶ。
            JFR のソケット読み込み待ち)
slow.jsp: 指定ミリ秒待ってから返す。

使い方: python make_war.py <出力先ディレクトリ>
"""
import os
import sys
import zipfile

DB_JSP = r'''<%@ page import="javax.naming.InitialContext, javax.sql.DataSource, java.sql.*, java.net.*, java.io.*" %><%!
static final Object LOCK = new Object();
static int p(jakarta.servlet.http.HttpServletRequest r, String k, int d) {
    try { return Integer.parseInt(r.getParameter(k)); } catch (Exception e) { return d; }
}
%><%
int ms = p(request, "ms", 50);
int kb = p(request, "kb", 2048);
int cpu = p(request, "cpu", 0);
int lock = p(request, "lock", 0);
int ex = p(request, "ex", 0);
int sock = p(request, "sock", 0);
boolean xa = "1".equals(request.getParameter("xa"));
byte[][] junk = new byte[kb / 64 + 1][];
for (int i = 0; i < junk.length; i++) { junk[i] = new byte[64 * 1024]; }
session.setAttribute("n", junk.length);
long sum = 0;
if (cpu > 0) {
    long end = System.nanoTime() + cpu * 1000000L;
    while (System.nanoTime() < end) { sum += Long.numberOfTrailingZeros(sum + System.nanoTime()); }
}
if (lock > 0) {
    synchronized (LOCK) { Thread.sleep(lock); }
}
for (int i = 0; i < ex; i++) {
    try { throw new IllegalStateException("perftest " + i); } catch (IllegalStateException e) { sum += e.getMessage().length(); }
}
if (sock > 0) {
    URL u = new URL("http://127.0.0.1:" + request.getLocalPort() + request.getContextPath() + "/slow.jsp?ms=" + sock);
    HttpURLConnection hc = (HttpURLConnection) u.openConnection();
    try (InputStream in = hc.getInputStream()) { while (in.read() >= 0) { sum++; } }
}
InitialContext ic = new InitialContext();
if (xa) {
    jakarta.transaction.UserTransaction ut = (jakarta.transaction.UserTransaction) ic.lookup("java:comp/UserTransaction");
    ut.begin();
    try {
        DataSource ds = (DataSource) ic.lookup("java:jboss/datasources/ExampleXADS");
        try (Connection c = ds.getConnection(); PreparedStatement ps = c.prepareStatement("SELECT 1")) {
            ResultSet rs = ps.executeQuery();
            rs.next();
            Thread.sleep(ms);
            sum += rs.getInt(1);
        }
        ut.commit();
    } catch (Exception e) {
        try { ut.rollback(); } catch (Exception ignore) { }
        throw e;
    }
} else {
    DataSource ds = (DataSource) ic.lookup("java:jboss/datasources/ExampleDS");
    try (Connection c = ds.getConnection(); PreparedStatement ps = c.prepareStatement("SELECT 1")) {
        ResultSet rs = ps.executeQuery();
        rs.next();
        Thread.sleep(ms);
        sum += rs.getInt(1);
    }
}
out.println("ok " + junk.length + " " + sum);
%>
'''

SLOW_JSP = r'''<%
int ms = 30;
try { ms = Integer.parseInt(request.getParameter("ms")); } catch (Exception e) { }
Thread.sleep(ms);
out.println("slow " + ms);
%>
'''

out_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
path = os.path.join(out_dir, 'perftest.war')
with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('db.jsp', DB_JSP)
    z.writestr('slow.jsp', SLOW_JSP)
    z.writestr('index.html', '<html><body>perftest</body></html>\n')
print(path)

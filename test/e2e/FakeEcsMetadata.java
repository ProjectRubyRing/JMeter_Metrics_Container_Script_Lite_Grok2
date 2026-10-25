// 検証用: ECS タスクメタデータ v4 の代わり (ECS_CONTAINER_METADATA_URI_V4 / .../task を返す)。
// 使い方: java FakeEcsMetadata.java <port> <task vCPU> <このコンテナの CPU ユニット (0 = 未指定)>
//   ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:<port>/v4/perf-e2e を設定して使う。
// JDK の jdk.httpserver モジュール (Red Hat の OpenJDK 21 runtime イメージにもある) だけで動く。
import com.sun.net.httpserver.HttpServer;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

public class FakeEcsMetadata {
    public static void main(String[] a) throws Exception {
        int port = Integer.parseInt(a[0]);
        String vcpu = a.length > 1 ? a[1] : "1";
        String cu = a.length > 2 ? a[2] : "512";
        String self = "{\"DockerId\":\"e2e\",\"Name\":\"intra-web-front\",\"Image\":\"intra-web-front:perf\","
                + (cu.equals("0") ? "\"Limits\":{\"Memory\":2048}," : "\"Limits\":{\"CPU\":" + cu + ",\"Memory\":2048},")
                + "\"Type\":\"NORMAL\",\"KnownStatus\":\"RUNNING\"}";
        String task = "{\"Cluster\":\"arn:aws:ecs:ap-northeast-1:123456789012:cluster/perf\",\"TaskARN\":\"arn:aws:ecs:ap-northeast-1:123456789012:task/perf/0123456789abcdef\","
                + "\"Family\":\"intra-web-perf\",\"Revision\":\"7\",\"ServiceName\":\"intra-web\",\"LaunchType\":\"FARGATE\",\"AvailabilityZone\":\"ap-northeast-1a\","
                + "\"Limits\":{\"CPU\":" + vcpu + ",\"Memory\":4096},\"Containers\":[" + self + ","
                + "{\"DockerId\":\"e2e-b\",\"Name\":\"intra-web-back\",\"Image\":\"intra-web-back:perf\"," + (cu.equals("0") ? "\"Limits\":{\"Memory\":1536}," : "\"Limits\":{\"CPU\":" + cu + ",\"Memory\":1536},") + "\"Type\":\"NORMAL\"},"
                + "{\"DockerId\":\"e2e-c\",\"Name\":\"cwagent\",\"Image\":\"public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest\",\"Limits\":{\"CPU\":0,\"Memory\":256},\"Type\":\"NORMAL\"}]}";
        HttpServer s = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        s.createContext("/v4/perf-e2e/task", x -> reply(x, task));
        s.createContext("/v4/perf-e2e", x -> reply(x, self));
        s.start();
        System.out.println("fake ECS metadata on " + port);
    }

    static void reply(com.sun.net.httpserver.HttpExchange x, String body) throws java.io.IOException {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        x.getResponseHeaders().add("Content-Type", "application/json");
        x.sendResponseHeaders(200, b.length);
        try (OutputStream o = x.getResponseBody()) { o.write(b); }
    }
}

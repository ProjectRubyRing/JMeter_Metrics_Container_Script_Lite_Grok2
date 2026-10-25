// perf-metrics.sh: JFR (Flight Recorder) recordings -> CSV files for the Excel report.
// Usage: java PerfJfrCsv.java <out-dir> <interval-seconds> <jfr dir or file> [...]
// Needs only the public jdk.jfr.consumer API (JDK 11+; tested with Red Hat OpenJDK 21 and JDK 17).
// Runs as a single-file source program, so it has no package and only one top-level public class.
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.regex.*;
import jdk.jfr.consumer.*;

public class PerfJfrCsv {
    static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    static final ZoneId ZONE = ZoneId.systemDefault();
    static final Pattern MASK = Pattern.compile("(?i)([A-Za-z0-9_.-]*(password|passwd|secret)[A-Za-z0-9_.-]*[=:])[^ ,]*");
    static final Pattern REPO_DIR = Pattern.compile("^\\d{4}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_(\\d+)$");
    static final Pattern DUMP_FILE = Pattern.compile("^perf_(\\d+)_.*\\.jfr$");

    static long interval = 10;
    static final TreeMap<Long, Map<String, Double>> STATS = new TreeMap<>();
    static final Map<Long, double[]> GC_HEAP = new HashMap<>();          // gcId -> before, after, committed (bytes)
    static final List<Object[]> GC_EVENTS = new ArrayList<>();          // epoch, gcId, name, cause, sum, longest, duration
    static final Map<String, Long> HOT = new HashMap<>();
    static long hotTotal = 0;
    static final Map<String, double[]> CONT = new HashMap<>();          // count, total ms, max ms
    static final Map<String, double[]> IO = new HashMap<>();            // count, total ms, max ms, bytes
    static final Map<String, double[]> VMOPS = new HashMap<>();         // count, total ms, max ms
    static final Map<String, long[]> TYPES = new TreeMap<>();           // count, first epoch, last epoch
    static final LinkedHashMap<String, String> ENV = new LinkedHashMap<>();
    static final List<String[]> FILES = new ArrayList<>();

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("usage: java PerfJfrCsv.java <out-dir> <interval-seconds> <jfr dir or file> [...]");
            System.exit(2);
        }
        Path out = Paths.get(args[0]);
        Files.createDirectories(out);
        try { interval = Math.max(1, Long.parseLong(args[1])); } catch (NumberFormatException e) { interval = 10; }
        List<Path> files = pick(Arrays.copyOfRange(args, 2, args.length));
        if (files.isEmpty()) {
            System.err.println("no .jfr files found");
            System.exit(1);
        }
        for (Path f : files) read(f);
        writeAll(out);
        System.out.println("files=" + files.size() + " events=" + TYPES.values().stream().mapToLong(v -> v[0]).sum() + " out=" + out);
    }

    // Select the recordings to read. For each JVM (pid) use the dump written at exit when it
    // exists (it already contains every chunk), otherwise the chunks left in the repository
    // (JVM killed before it could dump). Dumps under a "dump" directory (taken on demand) are
    // copies of the same data, so they are only used when nothing else is available.
    static List<Path> pick(String[] roots) throws IOException {
        Map<String, List<Path>> dumps = new TreeMap<>(), chunks = new TreeMap<>();
        List<Path> others = new ArrayList<>(), ondemand = new ArrayList<>();
        for (String r : roots) {
            Path p = Paths.get(r);
            if (!Files.exists(p)) continue;
            List<Path> all = new ArrayList<>();
            if (Files.isDirectory(p)) {
                try (java.util.stream.Stream<Path> s = Files.walk(p)) {
                    s.filter(x -> Files.isRegularFile(x) && x.getFileName().toString().endsWith(".jfr")).forEach(all::add);
                }
            } else all.add(p);
            for (Path f : all) {
                String name = f.getFileName().toString();
                Path parent = f.getParent();
                String pname = parent == null || parent.getFileName() == null ? "" : parent.getFileName().toString();
                Matcher m = DUMP_FILE.matcher(name), r2 = REPO_DIR.matcher(pname);
                if (pname.equals("dump")) ondemand.add(f);
                else if (m.matches()) dumps.computeIfAbsent(m.group(1), k -> new ArrayList<>()).add(f);
                else if (r2.matches()) chunks.computeIfAbsent(r2.group(1), k -> new ArrayList<>()).add(f);
                else others.add(f);
            }
        }
        List<Path> sel = new ArrayList<>();
        Set<String> pids = new TreeSet<>(dumps.keySet());
        pids.addAll(chunks.keySet());
        for (String pid : pids) {
            List<Path> l = dumps.containsKey(pid) ? dumps.get(pid) : chunks.get(pid);
            Collections.sort(l);
            sel.addAll(l);
        }
        Collections.sort(others);
        sel.addAll(others);
        if (sel.isEmpty()) { Collections.sort(ondemand); sel.addAll(ondemand); }
        return sel;
    }

    static void read(Path f) {
        long n = 0;
        String status = "ok";
        try (RecordingFile rf = new RecordingFile(f)) {
            while (rf.hasMoreEvents()) {
                RecordedEvent e;
                try { e = rf.readEvent(); } catch (EOFException eof) { status = "truncated"; break; }
                n++;
                try { handle(e); } catch (RuntimeException ex) { /* one bad event must not stop the rest */ }
            }
        } catch (Throwable t) {
            status = (n > 0 ? "partial: " : "error: ") + t.getClass().getSimpleName() + " " + String.valueOf(t.getMessage());
        }
        FILES.add(new String[] { f.toString(), String.valueOf(fsize(f)), String.valueOf(n), status });
    }

    static long fsize(Path f) { try { return Files.size(f); } catch (IOException e) { return -1; } }

    static void handle(RecordedEvent e) {
        String type = e.getEventType().getName();
        long ep = e.getStartTime().getEpochSecond();
        long[] t = TYPES.computeIfAbsent(type, k -> new long[] { 0, Long.MAX_VALUE, Long.MIN_VALUE });
        t[0]++; t[1] = Math.min(t[1], ep); t[2] = Math.max(t[2], ep);
        switch (type) {
            case "jdk.CPULoad":
                put(ep, "jvm_user_pct", pct(e, "jvmUser")); put(ep, "jvm_system_pct", pct(e, "jvmSystem")); put(ep, "machine_total_pct", pct(e, "machineTotal"));
                break;
            case "jdk.JavaThreadStatistics":
                put(ep, "threads_active", num(e, "activeCount")); put(ep, "threads_daemon", num(e, "daemonCount"));
                put(ep, "threads_peak", num(e, "peakCount")); put(ep, "threads_accumulated", num(e, "accumulatedCount"));
                break;
            case "jdk.ClassLoadingStatistics":
                put(ep, "classes_loaded", num(e, "loadedClassCount")); put(ep, "classes_unloaded", num(e, "unloadedClassCount"));
                break;
            case "jdk.CompilerStatistics":
                put(ep, "compiles", num(e, "compileCount")); put(ep, "osr_compiles", num(e, "osrCompileCount"));
                put(ep, "bailouts", num(e, "bailoutCount")); put(ep, "invalidated", num(e, "invalidatedCount"));
                put(ep, "compile_time_ms", ms(e, "totalTimeSpent")); put(ep, "nmethod_code_mb", mb(e, "nmethodCodeSize"));
                break;
            case "jdk.CodeCacheStatistics": {
                // one event per code heap segment; summed per interval when written
                String bt = str(e, "codeBlobType");
                put(ep, "cc_free." + bt, mb(e, "unallocatedCapacity")); put(ep, "cc_full." + bt, num(e, "fullCount"));
                break;
            }
            case "jdk.ExceptionStatistics":
                put(ep, "throwables", num(e, "throwables"));
                break;
            case "jdk.ThreadContextSwitchRate":
                put(ep, "ctx_switch_per_sec", num(e, "switchRate"));
                break;
            case "jdk.ResidentSetSize":
                put(ep, "rss_mb", mb(e, "size")); put(ep, "rss_peak_mb", mb(e, "peak"));
                break;
            case "jdk.DirectBufferStatistics":
                put(ep, "direct_buffer_count", num(e, "count")); put(ep, "direct_buffer_used_mb", mb(e, "memoryUsed"));
                break;
            case "jdk.NativeMemoryUsageTotal":
                put(ep, "nmt_reserved_mb", mb(e, "reserved")); put(ep, "nmt_committed_mb", mb(e, "committed"));
                break;
            case "jdk.ContainerCPUThrottling":
                put(ep, "throttled_slices", num(e, "cpuThrottledSlices")); put(ep, "elapsed_slices", num(e, "cpuElapsedSlices"));
                put(ep, "throttled_ms", ms(e, "cpuThrottledTime"));
                break;
            case "jdk.GarbageCollection":
                GC_EVENTS.add(new Object[] { e.getStartTime(), num(e, "gcId"), str(e, "name"), str(e, "cause"),
                        ms(e, "sumOfPauses"), ms(e, "longestPause"), (double) e.getDuration().toNanos() / 1e6 });
                break;
            case "jdk.GCHeapSummary": {
                Double id = num(e, "gcId");
                if (id == null) break;
                double[] h = GC_HEAP.computeIfAbsent(id.longValue(), k -> new double[] { Double.NaN, Double.NaN, Double.NaN });
                Double used = num(e, "heapUsed");
                String when = str(e, "when");
                if (used != null && when != null) { if (when.startsWith("Before")) h[0] = used; else h[1] = used; }
                Object hs = val(e, "heapSpace");
                if (hs instanceof RecordedObject && ((RecordedObject) hs).hasField("committedSize")) h[2] = ((RecordedObject) hs).getLong("committedSize");
                break;
            }
            case "jdk.ExecutionSample": {
                RecordedStackTrace st = e.getStackTrace();
                if (st == null || st.getFrames().isEmpty()) break;
                String m = method(st.getFrames().get(0));
                HOT.merge(m, 1L, Long::sum);
                hotTotal++;
                break;
            }
            case "jdk.JavaMonitorEnter": agg(CONT, "monitor-enter\t" + cls(e, "monitorClass") + "\t" + site(e), e, -1); break;
            case "jdk.ThreadPark": {
                // idle pool threads waiting for work and periodic timers are not contention
                String s = site(e);
                if (!idle(e, s)) agg(CONT, "thread-park\t" + cls(e, "parkedClass") + "\t" + s, e, -1);
                break;
            }
            case "jdk.SocketRead": agg(IO, "socket-read\t" + hostPort(e), e, numOr(e, "bytesRead")); break;
            case "jdk.SocketWrite": agg(IO, "socket-write\t" + hostPort(e), e, numOr(e, "bytesWritten")); break;
            case "jdk.FileRead": agg(IO, "file-read\t" + str(e, "path"), e, numOr(e, "bytesRead")); break;
            case "jdk.FileWrite": agg(IO, "file-write\t" + str(e, "path"), e, numOr(e, "bytesWritten")); break;
            case "jdk.ExecuteVMOperation": agg(VMOPS, "vm-operation\t" + str(e, "operation") + (bool(e, "safepoint") ? " (safepoint)" : ""), e, -1); break;
            case "jdk.SafepointBegin": agg(VMOPS, "safepoint\tsafepoint", e, -1); break;
            case "jdk.ContainerConfiguration":
                for (String k : new String[] { "containerType", "cpuSlicePeriod", "cpuQuota", "cpuShares", "effectiveCpuCount",
                        "memorySoftLimit", "memoryLimit", "swapMemoryLimit", "hostTotalMemory", "hostTotalSwapMemory" })
                    env("container", k, e, k);
                break;
            case "jdk.CPUInformation":
                env("cpu", "cpu", e, "cpu"); env("cpu", "sockets", e, "sockets"); env("cpu", "cores", e, "cores"); env("cpu", "hwThreads", e, "hwThreads");
                break;
            case "jdk.GCConfiguration":
                for (String k : new String[] { "youngCollector", "oldCollector", "parallelGCThreads", "concurrentGCThreads", "usesDynamicGCThreads", "pauseTarget", "gcTimeRatio" })
                    env("gc", k, e, k);
                break;
            case "jdk.GCHeapConfiguration":
                for (String k : new String[] { "minSize", "maxSize", "initialSize", "usesCompressedOops", "heapAddressBits", "objectAlignment" }) env("heap", k, e, k);
                break;
            case "jdk.CompilerConfiguration":
                env("compiler", "threadCount", e, "threadCount"); env("compiler", "tieredCompilation", e, "tieredCompilation");
                break;
            case "jdk.JVMInformation":
                env("jvm", "jvmName", e, "jvmName"); env("jvm", "jvmVersion", e, "jvmVersion"); env("jvm", "pid", e, "pid");
                env("jvm", "jvmStartTime", e, "jvmStartTime"); env("jvm", "jvmFlags", e, "jvmFlags"); env("jvm", "jvmArguments", e, "jvmArguments");
                break;
            case "jdk.OSInformation": env("os", "osVersion", e, "osVersion"); break;
            case "jdk.VirtualizationInformation": env("os", "virtualization", e, "name"); break;
            case "jdk.PhysicalMemory": env("os", "totalSize", e, "totalSize"); break;
            default: break;
        }
    }

    // ---- value helpers (a missing field returns null, so one JDK version difference does not break the rest)
    static Object val(RecordedObject e, String f) { return e.hasField(f) ? e.getValue(f) : null; }
    static Double num(RecordedObject e, String f) {
        Object v = val(e, f);
        if (v instanceof Number) return ((Number) v).doubleValue();
        if (v instanceof Boolean) return ((Boolean) v) ? 1.0 : 0.0;
        return null;
    }
    static double numOr(RecordedObject e, String f) { Double d = num(e, f); return d == null ? -1 : d; }
    static Double pct(RecordedObject e, String f) { Double d = num(e, f); return d == null ? null : d * 100.0; }
    static Double mb(RecordedObject e, String f) { Double d = num(e, f); return d == null ? null : d / 1048576.0; }
    // @Timespan fields: getValue returns the raw number, getDuration converts it with its unit
    static Double ms(RecordedObject e, String f) {
        if (!e.hasField(f)) return null;
        try {
            Duration d = e.getDuration(f);
            if (d.getSeconds() == Long.MIN_VALUE || d.getSeconds() == Long.MAX_VALUE) return null;
            return d.toNanos() / 1e6;
        } catch (RuntimeException ex) { return null; }
    }
    static boolean bool(RecordedObject e, String f) { Object v = val(e, f); return v instanceof Boolean && (Boolean) v; }
    static String str(RecordedObject e, String f) { Object v = val(e, f); return v == null ? null : String.valueOf(v); }
    static String cls(RecordedEvent e, String f) {
        Object v = val(e, f);
        if (v instanceof RecordedClass) return ((RecordedClass) v).getName();
        return v == null ? "" : String.valueOf(v);
    }
    static String hostPort(RecordedEvent e) {
        String h = str(e, "host");
        if (h == null || h.isEmpty()) h = str(e, "address");
        Double p = num(e, "port");
        return (h == null ? "" : h) + ":" + (p == null ? "" : String.valueOf(p.longValue()));
    }
    static String method(RecordedFrame fr) {
        RecordedMethod m = fr.getMethod();
        if (m == null) return "(unknown)";
        RecordedClass c = m.getType();
        return (c == null ? "" : c.getName() + ".") + m.getName();
    }
    // The first frame that is not in the JDK itself (where the application or JBoss waited).
    static String site(RecordedEvent e) {
        RecordedStackTrace st = e.getStackTrace();
        if (st == null || st.getFrames().isEmpty()) return "";
        String first = null;
        for (RecordedFrame fr : st.getFrames()) {
            String m = method(fr);
            if (first == null) first = m;
            if (!(m.startsWith("java.") || m.startsWith("jdk.") || m.startsWith("sun.") || m.startsWith("javax."))) return m;
        }
        return first;
    }
    static final String[] IDLE_FRAMES = { "java.util.concurrent.ThreadPoolExecutor.getTask", "java.util.concurrent.ScheduledThreadPoolExecutor$DelayedWorkQueue.take",
            "java.util.concurrent.ForkJoinPool.awaitWork", "java.util.concurrent.LinkedBlockingQueue.take", "java.util.concurrent.SynchronousQueue",
            "java.util.concurrent.DelayQueue.take", "java.lang.ref.ReferenceQueue.remove" };
    static final String[] IDLE_SITES = { "org.jboss.threads.EnhancedQueueExecutor$ThreadBody.run", "org.jboss.threads.JBossThread.run",
            "jdk.internal.misc.Unsafe.park", "java.lang.Thread.run", "org.jboss.jca.core.connectionmanager.pool.idle.IdleRemover",
            "com.arjuna.ats.internal.arjuna.recovery.PeriodicRecovery", "com.arjuna.ats.internal.arjuna.coordinator.ReaperThread" };
    static boolean idle(RecordedEvent e, String site) {
        if (site != null) for (String p : IDLE_SITES) if (site.startsWith(p)) return true;
        RecordedStackTrace st = e.getStackTrace();
        if (st != null) for (RecordedFrame fr : st.getFrames()) { String m = method(fr); for (String p : IDLE_FRAMES) if (m.startsWith(p)) return true; }
        return false;
    }
    static void put(long ep, String k, Double v) {
        if (v == null || v.isNaN()) return;
        STATS.computeIfAbsent(ep - Math.floorMod(ep, interval), x -> new HashMap<>()).put(k, v);
    }
    static void agg(Map<String, double[]> m, String key, RecordedEvent e, double bytes) {
        double d = e.getDuration().toNanos() / 1e6;
        double[] a = m.computeIfAbsent(key, k -> new double[] { 0, 0, 0, 0 });
        a[0]++; a[1] += d; a[2] = Math.max(a[2], d);
        if (bytes > 0) a[3] += bytes;
    }
    static void env(String cat, String key, RecordedEvent e, String f) {
        Object v = val(e, f);
        if (v == null) return;
        if (v instanceof Number && (((Number) v).longValue() == Long.MIN_VALUE || ((Number) v).longValue() == Long.MAX_VALUE)) return;
        String s = String.valueOf(v);
        if (f.equals("jvmStartTime")) { try { s = ts(e.getInstant(f).getEpochSecond()); } catch (RuntimeException ex) { /* keep the raw value */ } }
        if (f.equals("jvmArguments") || f.equals("jvmFlags")) s = MASK.matcher(s).replaceAll("$1********");
        ENV.put(cat + "\t" + key, s);
    }

    // ---- output
    static String q(String s) {
        if (s == null) return "";
        if (s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")) return "\"" + s.replace("\"", "\"\"") + "\"";
        return s;
    }
    static String n(Double d) {
        if (d == null || d.isNaN() || d.isInfinite()) return "";
        if (d == Math.rint(d) && Math.abs(d) < 1e15) return String.valueOf(d.longValue());
        return String.format(Locale.ROOT, "%.3f", d);
    }
    static String ts(long ep) { return TS.format(Instant.ofEpochSecond(ep).atZone(ZONE)); }
    static PrintWriter open(Path dir, String name) throws IOException {
        return new PrintWriter(new BufferedWriter(new OutputStreamWriter(Files.newOutputStream(dir.resolve(name)), StandardCharsets.UTF_8)));
    }
    static void line(PrintWriter w, String s) { w.print(s); w.print("\n"); }

    static void writeAll(Path dir) throws IOException {
        String[] sc = { "jvm_user_pct", "jvm_system_pct", "machine_total_pct", "threads_active", "threads_daemon", "threads_peak", "threads_accumulated",
                "classes_loaded", "classes_unloaded", "compiles", "osr_compiles", "bailouts", "invalidated", "compile_time_ms", "nmethod_code_mb",
                "code_cache_free_mb", "code_cache_full_count", "throwables", "ctx_switch_per_sec", "rss_mb", "rss_peak_mb",
                "direct_buffer_count", "direct_buffer_used_mb", "nmt_reserved_mb", "nmt_committed_mb", "throttled_slices", "elapsed_slices", "throttled_ms" };
        try (PrintWriter w = open(dir, "jfr_stats.csv")) {
            line(w, "timestamp,epoch," + String.join(",", sc));
            for (Map.Entry<Long, Map<String, Double>> en : STATS.entrySet()) {
                Map<String, Double> v = en.getValue();
                Double free = null, full = null;
                for (Map.Entry<String, Double> x : v.entrySet()) {
                    if (x.getKey().startsWith("cc_free.")) free = (free == null ? 0 : free) + x.getValue();
                    else if (x.getKey().startsWith("cc_full.")) full = (full == null ? 0 : full) + x.getValue();
                }
                if (free != null) v.put("code_cache_free_mb", free);
                if (full != null) v.put("code_cache_full_count", full);
                StringBuilder b = new StringBuilder(ts(en.getKey())).append(",").append(en.getKey());
                for (String k : sc) b.append(",").append(n(v.get(k)));
                line(w, b.toString());
            }
        }
        GC_EVENTS.sort(Comparator.comparing(o -> (Instant) o[0]));
        try (PrintWriter w = open(dir, "jfr_gc.csv")) {
            line(w, "timestamp,epoch,epoch_ms,gc_id,name,cause,sum_of_pauses_ms,longest_pause_ms,duration_ms,heap_before_mb,heap_after_mb,heap_committed_mb");
            for (Object[] g : GC_EVENTS) {
                Instant at = (Instant) g[0];
                Double id = (Double) g[1];
                double[] h = id == null ? null : GC_HEAP.get(id.longValue());
                line(w, ts(at.getEpochSecond()) + "," + at.getEpochSecond() + "," + at.toEpochMilli() + "," + n(id) + "," + q((String) g[2]) + "," + q((String) g[3])
                        + "," + n((Double) g[4]) + "," + n((Double) g[5]) + "," + n((Double) g[6])
                        + "," + (h == null ? "," + "," : n(h[0] / 1048576.0) + "," + n(h[1] / 1048576.0) + "," + n(h[2] / 1048576.0)));
            }
        }
        try (PrintWriter w = open(dir, "jfr_hot_methods.csv")) {
            line(w, "rank,method,samples,pct");
            List<Map.Entry<String, Long>> l = new ArrayList<>(HOT.entrySet());
            l.sort((a, b) -> Long.compare(b.getValue(), a.getValue()));
            int r = 0;
            for (Map.Entry<String, Long> en : l) {
                if (++r > 50) break;
                line(w, r + "," + q(en.getKey()) + "," + en.getValue() + "," + n(hotTotal == 0 ? null : 100.0 * en.getValue() / hotTotal));
            }
        }
        writeAgg(dir, "jfr_contention.csv", "rank,kind,class,site,count,total_ms,max_ms", CONT, 3, false);
        writeAgg(dir, "jfr_io.csv", "rank,kind,target,count,total_ms,max_ms,bytes", IO, 2, true);
        writeAgg(dir, "jfr_vm_operations.csv", "rank,kind,operation,count,total_ms,max_ms", VMOPS, 2, false);
        try (PrintWriter w = open(dir, "jfr_env.csv")) {
            line(w, "category,key,value");
            for (Map.Entry<String, String> en : ENV.entrySet()) {
                String[] k = en.getKey().split("\t", 2);
                line(w, q(k[0]) + "," + q(k[1]) + "," + q(en.getValue()));
            }
        }
        try (PrintWriter w = open(dir, "jfr_summary.csv")) {
            line(w, "kind,name,count,first,last,detail");
            for (String[] f : FILES) line(w, "file," + q(f[0]) + "," + f[2] + ",,," + q("bytes=" + f[1] + " " + f[3]));
            for (Map.Entry<String, long[]> en : TYPES.entrySet())
                line(w, "event," + q(en.getKey()) + "," + en.getValue()[0] + "," + ts(en.getValue()[1]) + "," + ts(en.getValue()[2]) + ",");
        }
    }

    static void writeAgg(Path dir, String name, String header, Map<String, double[]> m, int keyCols, boolean withBytes) throws IOException {
        try (PrintWriter w = open(dir, name)) {
            line(w, header);
            List<Map.Entry<String, double[]>> l = new ArrayList<>(m.entrySet());
            l.sort((a, b) -> Double.compare(b.getValue()[1], a.getValue()[1]));
            int r = 0;
            for (Map.Entry<String, double[]> en : l) {
                if (++r > 100) break;
                String[] k = en.getKey().split("\t", -1);
                StringBuilder b = new StringBuilder().append(r);
                for (int i = 0; i < keyCols; i++) b.append(",").append(q(i < k.length ? k[i] : ""));
                double[] a = en.getValue();
                b.append(",").append(n(a[0])).append(",").append(n(a[1])).append(",").append(n(a[2]));
                if (withBytes) b.append(",").append(a[3] > 0 ? n(a[3]) : "");
                line(w, b.toString());
            }
        }
    }
}

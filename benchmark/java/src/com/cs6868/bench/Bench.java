package com.cs6868.bench;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Locale;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.IntConsumer;

/**
 * Tiny multi-threaded benchmark harness mirroring {@code benchmark/ocaml/bench.ml}.
 *
 * <p>Each benchmark declares a name for the {@code primitive} and the
 * {@code workload}, a thread count, and a per-thread body executing one
 * operation. The harness spawns that many {@link Thread}s, uses a
 * {@link CyclicBarrier} to start them together, then runs a 1-second
 * warm-up (uncounted) followed by a 3-second measurement window.
 *
 * <p>CSV schema matches {@code Bench.csv_header} on the OCaml side:
 *
 * <pre>
 * implementation,primitive,workload,threads,ops,duration_s,
 * throughput_ops_s,mean_latency_ns,repeat
 * </pre>
 *
 * {@code implementation} is always {@code "java"} from this class.
 */
public final class Bench {

    public static final String CSV_HEADER =
        "implementation,primitive,workload,threads,ops,duration_s," +
        "throughput_ops_s,mean_latency_ns,repeat";

    /** One aggregated benchmark observation across all worker threads. */
    public static final class Result {
        public final String primitive;
        public final String workload;
        public final int threads;
        public final long ops;
        public final double durationS;
        public final double throughput;
        public final double meanNs;
        public final int repeat;

        Result(String primitive, String workload, int threads,
               long ops, double durationS, double throughput,
               double meanNs, int repeat) {
            this.primitive = primitive;
            this.workload = workload;
            this.threads = threads;
            this.ops = ops;
            this.durationS = durationS;
            this.throughput = throughput;
            this.meanNs = meanNs;
            this.repeat = repeat;
        }

        public String csvRow() {
            return String.format(Locale.ROOT,
                "java,%s,%s,%d,%d,%.6f,%.2f,%.2f,%d",
                primitive, workload, threads, ops, durationS,
                throughput, meanNs, repeat);
        }

        public void printStdout() {
            System.out.printf(Locale.ROOT,
                "java   %-30s %-16s T=%d  %10d ops  %9.0f ops/s  %7.0f ns/op (repeat %d)%n",
                primitive, workload, threads, ops, throughput, meanNs, repeat);
        }
    }

    /**
     * Run one (primitive, workload, threads) benchmark.
     *
     * @param body called in a tight loop inside each worker thread with
     *             its thread index. One invocation == one logical op.
     */
    public static Result run(String primitive, String workload, int threads,
                             long warmupMs, long measureMs, int repeat,
                             IntConsumer body) throws InterruptedException {
        AtomicBoolean warming = new AtomicBoolean(true);
        AtomicBoolean running = new AtomicBoolean(true);
        long[] counts = new long[threads];
        CyclicBarrier startGate = new CyclicBarrier(threads + 1);

        Thread[] workers = new Thread[threads];
        for (int i = 0; i < threads; i++) {
            final int idx = i;
            workers[i] = new Thread(() -> {
                try { startGate.await(); } catch (Exception e) {
                    throw new RuntimeException(e);
                }
                while (warming.get()) body.accept(idx);
                long c = 0;
                while (running.get()) { body.accept(idx); c++; }
                counts[idx] = c;
            }, "bench-" + primitive + "-" + workload + "-" + i);
            workers[i].start();
        }
        try { startGate.await(); } catch (Exception e) {
            throw new RuntimeException(e);
        }

        Thread.sleep(warmupMs);
        warming.set(false);
        long t0 = System.nanoTime();
        Thread.sleep(measureMs);
        running.set(false);
        long t1 = System.nanoTime();
        for (Thread t : workers) t.join();

        double durationS = (t1 - t0) / 1e9;
        long ops = 0; for (long c : counts) ops += c;
        double throughput = durationS > 0 ? ops / durationS : 0.0;
        double meanNs = ops > 0 ? (t1 - t0) * (double) threads / ops : 0.0;
        return new Result(primitive, workload, threads, ops, durationS,
                          throughput, meanNs, repeat);
    }

    /** Append one row to [path]; write a header first if the file is absent. */
    public static void appendTo(Path path, Result r) throws IOException {
        boolean fresh = !Files.exists(path);
        if (fresh) Files.createDirectories(path.getParent());
        try (BufferedWriter w = Files.newBufferedWriter(path, StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.APPEND)) {
            if (fresh) { w.write(CSV_HEADER); w.newLine(); }
            w.write(r.csvRow()); w.newLine();
        }
    }

    private Bench() {}
}

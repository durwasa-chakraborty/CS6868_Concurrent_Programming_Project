package com.cs6868.bench;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.Semaphore;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Java benchmark driver — mirrors {@code benchmark/ocaml/bench_runner.ml}.
 *
 * <p>Exercises the {@code java.util.concurrent} AQS-backed primitives
 * (Semaphore, ReentrantLock, CountDownLatch, CyclicBarrier,
 * LinkedBlockingQueue, LinkedBlockingDeque) across matched workloads.
 * Appends rows to a shared CSV file so the OCaml and Java numbers can
 * be compared directly.
 *
 * <p>CLI:
 * <pre>
 *   --out PATH             summary CSV destination
 *   --threads 1,2,4,8      thread counts to sweep
 *   --repeats N            repetitions per configuration
 *   --warmup-ms N          warmup duration
 *   --measure-ms N         measurement window
 *   --only Semaphore,...   subset of primitives to run
 * </pre>
 */
public final class BenchRunner {

    public static void main(String[] args) throws Exception {
        Path out = Paths.get("benchmark/results/summary.csv");
        int[] threads = {1, 2, 4, 8};
        int repeats = 3;
        long warmupMs = 1000;
        long measureMs = 2000;
        Set<String> selected = new HashSet<>();

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--out":        out = Paths.get(args[++i]); break;
                case "--threads":    threads = parseInts(args[++i]); break;
                case "--repeats":    repeats = Integer.parseInt(args[++i]); break;
                case "--warmup-ms":  warmupMs = Long.parseLong(args[++i]); break;
                case "--measure-ms": measureMs = Long.parseLong(args[++i]); break;
                case "--only":
                    selected.addAll(Arrays.asList(args[++i].split(",")));
                    break;
                default:
                    System.err.println("Unknown arg: " + args[i]);
                    System.exit(2);
            }
        }

        int cores = Runtime.getRuntime().availableProcessors();
        int[] capped = Arrays.stream(threads).filter(t -> t <= cores).toArray();
        if (capped.length == 0) capped = new int[]{1};

        // Semaphore
        if (wanted(selected, "Semaphore")) {
            for (int t : capped) {
                Semaphore s = new Semaphore(1);
                runMany("Semaphore(1)", "W2_contended", t,
                        warmupMs, measureMs, repeats, out,
                        idx -> { s.acquireUninterruptibly(); s.release(); });
            }
            Semaphore s = new Semaphore(1);
            runMany("Semaphore(1)", "W1_uncontended", 1,
                    warmupMs, measureMs, repeats, out,
                    idx -> { s.acquireUninterruptibly(); s.release(); });
        }

        // Mutex = ReentrantLock
        if (wanted(selected, "Mutex")) {
            for (int t : capped) {
                ReentrantLock m = new ReentrantLock();
                runMany("Mutex", "W2_contended", t,
                        warmupMs, measureMs, repeats, out,
                        idx -> { m.lock(); try {} finally { m.unlock(); } });
            }
            ReentrantLock m = new ReentrantLock();
            runMany("Mutex", "W1_uncontended", 1,
                    warmupMs, measureMs, repeats, out,
                    idx -> { m.lock(); try {} finally { m.unlock(); } });
        }

        // Blocking queue pool
        if (wanted(selected, "BlockingQueuePool")) {
            for (int t : capped) if (t >= 2) {
                LinkedBlockingQueue<Integer> q = new LinkedBlockingQueue<>();
                runMany("BlockingQueuePool", "W3_pc_queue", t,
                        warmupMs, measureMs, repeats, out,
                        idx -> {
                            try {
                                if (idx % 2 == 0) q.put(1);
                                else q.take();
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                            }
                        });
            }
        }

        // Blocking stack pool (LIFO via LinkedBlockingDeque push/takeFirst)
        if (wanted(selected, "BlockingStackPool")) {
            for (int t : capped) if (t >= 2) {
                LinkedBlockingDeque<Integer> d = new LinkedBlockingDeque<>();
                runMany("BlockingStackPool", "W4_pc_stack", t,
                        warmupMs, measureMs, repeats, out,
                        idx -> {
                            try {
                                if (idx % 2 == 0) d.putFirst(1);
                                else d.takeFirst();
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                            }
                        });
            }
        }

        // Count-down latch — fire-and-wake cycles
        if (wanted(selected, "CountDownLatch")) {
            for (int t : capped) if (t >= 2) {
                for (int r = 0; r < repeats; r++) {
                    int cycles = 200;
                    long t0 = System.nanoTime();
                    for (int c = 0; c < cycles; c++) {
                        CountDownLatch l = new CountDownLatch(1);
                        Thread[] waiters = new Thread[t - 1];
                        for (int w = 0; w < waiters.length; w++) {
                            waiters[w] = new Thread(() -> {
                                try { l.await(); } catch (InterruptedException e) {
                                    Thread.currentThread().interrupt();
                                }
                            });
                            waiters[w].start();
                        }
                        Thread.sleep(0, 500_000);  // 0.5 ms so waiters park
                        l.countDown();
                        for (Thread w : waiters) w.join();
                    }
                    long t1 = System.nanoTime();
                    double durS = (t1 - t0) / 1e9;
                    Bench.Result res = new Bench.Result(
                        "CountDownLatch(1)", "W5_latch_fire", t,
                        cycles, durS, cycles / durS,
                        (double) (t1 - t0) / cycles, r);
                    res.printStdout();
                    Bench.appendTo(out, res);
                }
            }
        }

        // Barrier — rendezvous latency
        if (wanted(selected, "Barrier")) {
            for (int t : capped) if (t >= 2) {
                for (int r = 0; r < repeats; r++) {
                    int cycles = 200;
                    long t0 = System.nanoTime();
                    for (int c = 0; c < cycles; c++) {
                        CyclicBarrier b = new CyclicBarrier(t);
                        Thread[] ts = new Thread[t];
                        for (int i = 0; i < t; i++) {
                            ts[i] = new Thread(() -> {
                                try { b.await(); } catch (Exception e) {
                                    throw new RuntimeException(e);
                                }
                            });
                            ts[i].start();
                        }
                        for (Thread th : ts) th.join();
                    }
                    long t1 = System.nanoTime();
                    double durS = (t1 - t0) / 1e9;
                    Bench.Result res = new Bench.Result(
                        "Barrier", "W6_barrier", t,
                        cycles, durS, cycles / durS,
                        (double) (t1 - t0) / cycles, r);
                    res.printStdout();
                    Bench.appendTo(out, res);
                }
            }
        }
    }

    private static void runMany(String primitive, String workload, int threads,
                                long warmupMs, long measureMs, int repeats,
                                Path out, java.util.function.IntConsumer body)
            throws Exception {
        for (int r = 0; r < repeats; r++) {
            Bench.Result res = Bench.run(primitive, workload, threads,
                warmupMs, measureMs, r, body);
            res.printStdout();
            Bench.appendTo(out, res);
        }
    }

    private static boolean wanted(Set<String> selected, String name) {
        return selected.isEmpty() || selected.contains(name);
    }

    private static int[] parseInts(String s) {
        List<Integer> xs = new ArrayList<>();
        for (String tok : s.split(",")) {
            String t = tok.trim();
            if (!t.isEmpty()) xs.add(Integer.parseInt(t));
        }
        int[] out = new int[xs.size()];
        for (int i = 0; i < xs.size(); i++) out[i] = xs.get(i);
        return out;
    }

    private BenchRunner() {}
}

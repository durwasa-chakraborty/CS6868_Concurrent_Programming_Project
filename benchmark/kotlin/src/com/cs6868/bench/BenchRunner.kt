package com.cs6868.bench

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import java.nio.file.Path
import java.nio.file.Paths
import kotlin.system.exitProcess

/**
 * Kotlin benchmark driver — mirrors `benchmark/java/.../BenchRunner.java` and
 * `benchmark/ocaml/bench_runner.ml`.
 *
 * Exercises the `kotlinx.coroutines` SQS-style primitives — `Mutex`, `Semaphore`,
 * and `Channel` — across the same workloads as the Java/OCaml runners.  The CSV
 * row schema is identical so all three implementations land in the same
 * `summary.csv` and the plot can compare them directly.
 *
 * Coverage gaps (relative to Java/OCaml):
 *   - BlockingStackPool: no built-in LIFO suspending channel in kotlinx.coroutines;
 *     omitted to avoid implementing a custom Treiber-stack-with-suspend.
 *   - CountDownLatch / Barrier: not provided by kotlinx.coroutines as suspending
 *     primitives; would require a hand-rolled implementation.  Omitted for now.
 *
 * CLI matches the other runners exactly:
 *   --out PATH --threads 1,2,4,8 --repeats N --warmup-ms N --measure-ms N
 *   --ops N --only Mutex,Semaphore,...
 */
fun main(args: Array<String>) {
    var out: Path = Paths.get("benchmark/results/summary.csv")
    var threads = intArrayOf(1, 2, 4, 8)
    var repeats = 3
    var warmupMs = 1000L
    var measureMs = 2000L
    var opsPerThread = 0L
    val selected = mutableSetOf<String>()

    var i = 0
    while (i < args.size) {
        when (args[i]) {
            "--out"        -> { out = Paths.get(args[++i]) }
            "--threads"    -> { threads = parseInts(args[++i]) }
            "--repeats"    -> { repeats = args[++i].toInt() }
            "--warmup-ms"  -> { warmupMs = args[++i].toLong() }
            "--measure-ms" -> { measureMs = args[++i].toLong() }
            "--ops"        -> { opsPerThread = args[++i].toLong() }
            "--only"       -> { selected.addAll(args[++i].split(",")) }
            else -> {
                System.err.println("Unknown arg: ${args[i]}")
                exitProcess(2)
            }
        }
        i++
    }

    val cores = Runtime.getRuntime().availableProcessors()
    val capped = threads.filter { it <= cores }.ifEmpty { listOf(1) }

    runBlocking {
        // ---------------- Mutex ----------------
        if (wanted(selected, "Mutex")) {
            for (t in capped) {
                val m = Mutex()
                runMany("Mutex", "W2_contended", t,
                    warmupMs, measureMs, opsPerThread, repeats, out) { _ ->
                        m.lock(); m.unlock()
                    }
            }
            val m = Mutex()
            runMany("Mutex", "W1_uncontended", 1,
                warmupMs, measureMs, opsPerThread, repeats, out) { _ ->
                    m.lock(); m.unlock()
                }
        }

        // ---------------- Semaphore ----------------
        if (wanted(selected, "Semaphore")) {
            for (t in capped) {
                val s = Semaphore(1)
                runMany("Semaphore(1)", "W2_contended", t,
                    warmupMs, measureMs, opsPerThread, repeats, out) { _ ->
                        s.acquire(); s.release()
                    }
            }
            val s = Semaphore(1)
            runMany("Semaphore(1)", "W1_uncontended", 1,
                warmupMs, measureMs, opsPerThread, repeats, out) { _ ->
                    s.acquire(); s.release()
                }
        }

        // ---------------- BlockingQueuePool (FIFO Channel) ----------------
        if (wanted(selected, "BlockingQueuePool")) {
            for (t in capped) if (t >= 2) {
                runPoolCycles("BlockingQueuePool", "W3_pc_queue", t,
                    repeats, out, makePool = { Channel<Int>(Channel.UNLIMITED) },
                    put = { ch, v -> ch.send(v) },
                    take = { ch -> ch.receive() })
            }
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
private suspend fun <C> runPoolCycles(
    primitive: String, workload: String, threads: Int,
    repeats: Int, out: Path,
    makePool: () -> C,
    put: suspend (C, Int) -> Unit,
    take: suspend (C) -> Int
) {
    val half = maxOf(1, threads / 2)
    val pairsPerCycle = 300
    val cycles = 40
    val dispatcher = Dispatchers.Default.limitedParallelism(threads)
    for (r in 0 until repeats) {
        val t0 = System.nanoTime()
        for (cy in 0 until cycles) {
            val pool = makePool()
            coroutineScope {
                repeat(half) {
                    launch(dispatcher) {
                        for (k in 0 until pairsPerCycle) put(pool, 1)
                    }
                    launch(dispatcher) {
                        for (k in 0 until pairsPerCycle) take(pool)
                    }
                }
            }
        }
        val t1 = System.nanoTime()
        val totalOps = (cycles * pairsPerCycle * half * 2).toLong()
        val durS = (t1 - t0) / 1e9
        val res = Bench.Result(primitive, workload, threads,
            totalOps, durS, totalOps / durS,
            (t1 - t0).toDouble() / totalOps, r)
        res.printStdout()
        Bench.appendTo(out, res)
    }
}

private suspend fun runMany(
    primitive: String, workload: String, threads: Int,
    warmupMs: Long, measureMs: Long, opsPerThread: Long,
    repeats: Int, out: Path,
    body: suspend (Int) -> Unit
) {
    for (r in 0 until repeats) {
        val res = Bench.run(primitive, workload, threads,
            warmupMs, measureMs, opsPerThread, r, body)
        res.printStdout()
        Bench.appendTo(out, res)
    }
}

private fun wanted(selected: Set<String>, name: String): Boolean =
    selected.isEmpty() || selected.contains(name)

private fun parseInts(s: String): IntArray =
    s.split(",").mapNotNull { it.trim().takeIf(String::isNotEmpty)?.toInt() }.toIntArray()

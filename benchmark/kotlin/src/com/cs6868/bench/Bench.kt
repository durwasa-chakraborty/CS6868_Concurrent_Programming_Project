package com.cs6868.bench

import kotlinx.coroutines.*
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Coroutine-based benchmark harness mirroring `benchmark/java/.../Bench.java`
 * and `benchmark/ocaml/bench.ml`.
 *
 * Each "thread" is a coroutine launched on `Dispatchers.Default.limitedParallelism(threads)`,
 * so worker count == thread count.  This is the closest analog to OCaml's
 * domains/Eio fibres: a fixed worker pool, with cooperative suspension when
 * a primitive parks the caller.
 *
 * CSV schema matches the Java/OCaml side; `implementation` is always `"kotlin"`.
 */
object Bench {
    const val CSV_HEADER =
        "implementation,primitive,workload,threads,ops,duration_s," +
        "throughput_ops_s,mean_latency_ns,repeat"

    data class Result(
        val primitive: String, val workload: String, val threads: Int,
        val ops: Long, val durationS: Double, val throughput: Double,
        val meanNs: Double, val repeat: Int
    ) {
        fun csvRow(): String = String.format(
            Locale.ROOT,
            "kotlin,%s,%s,%d,%d,%.6f,%.2f,%.2f,%d",
            primitive, workload, threads, ops, durationS,
            throughput, meanNs, repeat
        )

        fun printStdout() {
            println(String.format(
                Locale.ROOT,
                "kotlin %-30s %-16s T=%d  %10d ops  %9.0f ops/s  %7.0f ns/op (repeat %d)",
                primitive, workload, threads, ops, throughput, meanNs, repeat
            ))
        }
    }

    /**
     * One (primitive, workload, threads) benchmark.  If [opsPerThread] > 0,
     * fixed-N mode (each coroutine performs exactly that many body invocations
     * after warmup); else time-based (warmup + fixed measurement window).
     */
    suspend fun run(
        primitive: String, workload: String, threads: Int,
        warmupMs: Long, measureMs: Long, opsPerThread: Long, repeat: Int,
        body: suspend (Int) -> Unit
    ): Result =
        if (opsPerThread > 0)
            runFixedN(primitive, workload, threads, warmupMs, opsPerThread, repeat, body)
        else
            runTimed(primitive, workload, threads, warmupMs, measureMs, repeat, body)

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun runTimed(
        primitive: String, workload: String, threads: Int,
        warmupMs: Long, measureMs: Long, repeat: Int,
        body: suspend (Int) -> Unit
    ): Result = coroutineScope {
        val warming = AtomicBoolean(true)
        val running = AtomicBoolean(true)
        val counts  = LongArray(threads)
        val ready   = AtomicInteger(0)
        val dispatcher = Dispatchers.Default.limitedParallelism(threads)

        val workers = (0 until threads).map { i ->
            launch(dispatcher) {
                ready.incrementAndGet()
                while (warming.get()) body(i)
                var c = 0L
                while (running.get()) { body(i); c++ }
                counts[i] = c
            }
        }
        while (ready.get() < threads) yield()
        delay(warmupMs)
        val t0 = System.nanoTime()
        warming.set(false)
        delay(measureMs)
        running.set(false)
        val t1 = System.nanoTime()
        workers.forEach { it.join() }

        val durationS  = (t1 - t0) / 1e9
        val ops        = counts.sum()
        val throughput = if (durationS > 0) ops / durationS else 0.0
        val meanNs     = if (ops > 0) (t1 - t0) * threads.toDouble() / ops else 0.0
        Result(primitive, workload, threads, ops, durationS, throughput, meanNs, repeat)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun runFixedN(
        primitive: String, workload: String, threads: Int,
        warmupMs: Long, opsPerThread: Long, repeat: Int,
        body: suspend (Int) -> Unit
    ): Result = coroutineScope {
        val warming = AtomicBoolean(true)
        val ready   = AtomicInteger(0)
        val dispatcher = Dispatchers.Default.limitedParallelism(threads)

        val workers = (0 until threads).map { i ->
            launch(dispatcher) {
                ready.incrementAndGet()
                while (warming.get()) body(i)
                var k = 0L
                while (k < opsPerThread) { body(i); k++ }
            }
        }
        while (ready.get() < threads) yield()
        delay(warmupMs)
        val t0 = System.nanoTime()
        warming.set(false)
        workers.forEach { it.join() }
        val t1 = System.nanoTime()

        val ops        = opsPerThread * threads
        val durationS  = (t1 - t0) / 1e9
        val throughput = if (durationS > 0) ops / durationS else 0.0
        val meanNs     = if (ops > 0) (t1 - t0) * threads.toDouble() / ops else 0.0
        Result(primitive, workload, threads, ops, durationS, throughput, meanNs, repeat)
    }

    fun appendTo(path: Path, r: Result) {
        val fresh = !Files.exists(path)
        if (fresh) Files.createDirectories(path.parent)
        Files.newBufferedWriter(path, Charsets.UTF_8,
            StandardOpenOption.CREATE, StandardOpenOption.APPEND).use { w ->
            if (fresh) { w.write(CSV_HEADER); w.newLine() }
            w.write(r.csvRow()); w.newLine()
        }
    }
}

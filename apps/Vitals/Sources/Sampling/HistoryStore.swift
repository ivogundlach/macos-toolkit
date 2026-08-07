import Foundation
import SQLite3

/// Durable sample history, so "what drained the battery overnight?" is answerable
/// after the fact. Both the app and the background sampler write here; SQLite's
/// WAL mode lets them do that concurrently.
final class HistoryStore {
    static let defaultURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/vitals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }()

    /// A machine-level column recorded in `samples`.
    enum Series: String {
        case systemWatts, cpuWatts, gpuWatts, battery, cpuLoad, memoryUsed, gpuUtilization

        var column: String {
            switch self {
            case .systemWatts: return "system_w"
            case .cpuWatts: return "cpu_w"
            case .gpuWatts: return "gpu_w"
            case .battery: return "battery"
            case .cpuLoad: return "cpu_load"
            case .memoryUsed: return "mem_used"
            case .gpuUtilization: return "gpu_util"
            }
        }
    }

    /// One hour or one day of a series, already aggregated.
    struct Bucket {
        var index: Int
        var average: Double
        var peak: Double
        var minimum: Double
        var samples: Int
    }

    /// Which recorded per-process column a retrospective view ranks by.
    enum Metric: String {
        case energy, cpu, gpu, memory

        var column: String {
            switch self {
            case .energy: return "energy_mw"
            case .cpu: return "cpu"
            case .gpu: return "gpu"
            case .memory: return "mem"
            }
        }

        /// Zero is a real reading for CPU and power, but noise for GPU and memory:
        /// a process with no GPU work should not dilute the ranking.
        var positiveOnly: Bool { self == .gpu || self == .memory }

        /// Memory is a level, not a flow — a process holding 2 GB for one minute did
        /// not "use" less memory than one holding it all day, so rank it by average
        /// rather than by average × time.
        var rankByAverage: Bool { self == .memory }
    }

    /// A process's contribution to one metric over some window.
    struct Contribution: Identifiable {
        var id: String { name }
        var name: String
        /// Mean of the metric in its native unit: mW, percent, or bytes.
        var average: Double
        var peak: Double
        /// Energy only; meaningless for the other metrics.
        var energyJoules: Double
        /// Fraction of the window this process was actually observed (0...1).
        var coverage: Double
        var samples: Int
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.ivogundlach.vitals.history")
    /// Keep the per-process table bounded: only the biggest consumers matter.
    private let processesPerSample = 15

    init?(url: URL = HistoryStore.defaultURL) {
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS samples (
              ts REAL PRIMARY KEY, system_w REAL, cpu_w REAL, gpu_w REAL,
              battery REAL, charging INTEGER, cpu_load REAL, mem_used INTEGER, gpu_util REAL
            );
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS proc_samples (
              ts REAL, name TEXT, energy_mw REAL, cpu REAL, gpu REAL, wakeups REAL,
              mem INTEGER DEFAULT 0
            );
            """)
        // Databases created before the Memory tab existed lack `mem`. ALTER fails
        // harmlessly once the column is there, which is the whole migration.
        exec("ALTER TABLE proc_samples ADD COLUMN mem INTEGER DEFAULT 0;")
        exec("CREATE INDEX IF NOT EXISTS idx_proc_ts ON proc_samples(ts);")
        exec("CREATE INDEX IF NOT EXISTS idx_proc_name ON proc_samples(name);")
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: - Writing

    func record(_ snapshot: Snapshot) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let ts = snapshot.at.timeIntervalSince1970

            var stmt: OpaquePointer?
            let sql = """
                INSERT OR REPLACE INTO samples
                (ts, system_w, cpu_w, gpu_w, battery, charging, cpu_load, mem_used, gpu_util)
                VALUES (?,?,?,?,?,?,?,?,?);
                """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, ts)
                sqlite3_bind_double(stmt, 2, snapshot.power.systemWatts)
                sqlite3_bind_double(stmt, 3, snapshot.power.cpuWatts)
                sqlite3_bind_double(stmt, 4, snapshot.power.gpuWatts)
                sqlite3_bind_double(stmt, 5, snapshot.battery.percent)
                sqlite3_bind_int(stmt, 6, snapshot.battery.externalConnected ? 1 : 0)
                sqlite3_bind_double(stmt, 7, snapshot.system.cpuUsage)
                sqlite3_bind_int64(stmt, 8, Int64(snapshot.system.memory.used))
                sqlite3_bind_double(stmt, 9, snapshot.gpu.deviceUtilization)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            // Rank by energy, but keep anything notable on GPU, wakeups, CPU or
            // memory too — each retrospective tab ranks by its own column, so a
            // process that only stands out on one of them still has to be recorded.
            var keep = snapshot.topEnergy(self.processesPerSample)
            for extra in [snapshot.topGPU(5), snapshot.topWakeups(5),
                          snapshot.topCPU(5), snapshot.topMemory(5)] {
                for row in extra where !keep.contains(where: { $0.pid == row.pid }) {
                    keep.append(row)
                }
            }

            sqlite3_exec(db, "BEGIN;", nil, nil, nil)
            var pstmt: OpaquePointer?
            let psql = """
                INSERT INTO proc_samples (ts,name,energy_mw,cpu,gpu,wakeups,mem)
                VALUES (?,?,?,?,?,?,?);
                """
            if sqlite3_prepare_v2(db, psql, -1, &pstmt, nil) == SQLITE_OK {
                for row in keep {
                    sqlite3_reset(pstmt)
                    sqlite3_bind_double(pstmt, 1, ts)
                    // SQLITE_TRANSIENT: Swift's String buffer dies before step runs.
                    sqlite3_bind_text(pstmt, 2, row.name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_double(pstmt, 3, row.energyMilliwatts)
                    sqlite3_bind_double(pstmt, 4, row.cpuPercent)
                    sqlite3_bind_double(pstmt, 5, row.gpuPercent)
                    sqlite3_bind_double(pstmt, 6, row.idleWakeupsPerSec)
                    sqlite3_bind_int64(pstmt, 7, Int64(bitPattern: row.counters.footprint))
                    sqlite3_step(pstmt)
                }
            }
            sqlite3_finalize(pstmt)
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    /// Drop samples older than the retention window.
    func prune(retaining days: Int) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            for table in ["samples", "proc_samples"] {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE ts < ?;", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_double(stmt, 1, cutoff)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Reading

    /// Aggregate one machine-level series into fixed-width buckets.
    ///
    /// The grouping happens in SQL: a month of samples is ~86,000 rows, and the
    /// retrospective tabs only ever draw 30 bars from them. Buckets with no samples
    /// are simply absent from the result, so callers can tell a gap from a zero.
    /// `since` should already sit on a bucket boundary.
    func bucketedSeries(_ series: Series, since: Date, until: Date = Date(),
                        bucketSeconds: TimeInterval, positiveOnly: Bool = false) -> [Bucket] {
        queue.sync {
            guard let db, bucketSeconds > 0 else { return [] }
            let column = series.column
            let filter = positiveOnly ? "AND \(column) > 0" : ""
            var stmt: OpaquePointer?
            let sql = """
                SELECT CAST((ts - ?) / ? AS INTEGER) AS bucket,
                       AVG(\(column)), MAX(\(column)), MIN(\(column)), COUNT(*)
                FROM samples WHERE ts >= ? AND ts <= ? \(filter)
                GROUP BY bucket ORDER BY bucket;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            let start = since.timeIntervalSince1970
            sqlite3_bind_double(stmt, 1, start)
            sqlite3_bind_double(stmt, 2, bucketSeconds)
            sqlite3_bind_double(stmt, 3, start)
            sqlite3_bind_double(stmt, 4, until.timeIntervalSince1970)

            var out: [Bucket] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Bucket(index: Int(sqlite3_column_int(stmt, 0)),
                                  average: sqlite3_column_double(stmt, 1),
                                  peak: sqlite3_column_double(stmt, 2),
                                  minimum: sqlite3_column_double(stmt, 3),
                                  samples: Int(sqlite3_column_int(stmt, 4))))
            }
            return out
        }
    }

    /// Oldest and newest reading of a series inside a window — how much the battery
    /// moved over a night, rather than how it averaged.
    func edgeValues(_ series: Series, since: Date, until: Date = Date())
        -> (first: Double, last: Double)? {
        queue.sync {
            guard let db else { return nil }
            func read(_ direction: String) -> Double? {
                var stmt: OpaquePointer?
                let sql = """
                    SELECT \(series.column) FROM samples WHERE ts >= ? AND ts <= ?
                    ORDER BY ts \(direction) LIMIT 1;
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                return sqlite3_column_double(stmt, 0)
            }
            guard let first = read("ASC"), let last = read("DESC") else { return nil }
            return (first, last)
        }
    }

    /// Which processes actually accounted for a metric over a window.
    ///
    /// Flow metrics are averaged per sample and multiplied by the window length, so a
    /// process that ran briefly at high power ranks below one that ran steadily.
    /// Metric columns come from a fixed enum, never from user input.
    func topContributors(_ metric: Metric, since: Date, until: Date = Date(),
                         limit: Int = 15) -> [Contribution] {
        queue.sync {
            guard let db else { return [] }
            let column = metric.column
            let order = metric.rankByAverage ? "AVG(\(column))" : "AVG(\(column)) * COUNT(*)"
            let filter = metric.positiveOnly ? "AND \(column) > 0" : ""
            var stmt: OpaquePointer?
            let sql = """
                SELECT name, AVG(\(column)), MAX(\(column)), COUNT(*)
                FROM proc_samples WHERE ts >= ? AND ts <= ? \(filter)
                GROUP BY name ORDER BY \(order) DESC LIMIT ?;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            // Measure presence against the instants actually recorded, not against
            // the theoretical one-per-30s rate: whenever the app and the background
            // recorder both run, the real rate is roughly double and every process
            // would otherwise look permanently present.
            let instants = Double(recordedInstants(since: since, until: until))
            let window = until.timeIntervalSince(since)
            var out: [Contribution] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let avg = sqlite3_column_double(stmt, 1)
                let count = Int(sqlite3_column_int(stmt, 3))
                // Scale by observed fraction of the window so sparse processes
                // are not credited with energy they did not spend.
                let coverage = min(1.0, Double(count) / max(1.0, instants))
                out.append(Contribution(name: name,
                                        average: avg,
                                        peak: sqlite3_column_double(stmt, 2),
                                        energyJoules: avg / 1000.0 * window * coverage,
                                        coverage: coverage,
                                        samples: count))
            }
            return out
        }
    }

    /// How many distinct moments `proc_samples` holds for a window. Callers already
    /// hold the queue.
    private func recordedInstants(since: Date, until: Date) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(DISTINCT ts) FROM proc_samples WHERE ts >= ? AND ts <= ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Fraction of a window that has any recording behind it at all.
    ///
    /// Counts distinct 30-second slots rather than rows, so two recorders running
    /// concurrently cannot disguise a gap as full coverage.
    func coverage(since: Date, until: Date = Date()) -> Double {
        queue.sync {
            guard let db else { return 0 }
            let span = until.timeIntervalSince(since)
            guard span > 0 else { return 0 }
            var stmt: OpaquePointer?
            let sql = """
                SELECT COUNT(DISTINCT CAST(ts / 30 AS INTEGER)) FROM samples
                WHERE ts >= ? AND ts <= ?;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return min(1, Double(sqlite3_column_int(stmt, 0)) / (span / 30))
        }
    }

    /// Oldest sample on record, for showing how far history reaches.
    func earliestSample() -> Date? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MIN(ts) FROM samples;", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

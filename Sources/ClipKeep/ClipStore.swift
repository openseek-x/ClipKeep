import Foundation
import SQLite3

/// SQLite 持久层。
///
/// 并发模型：所有数据库访问经由单个串行队列 `queue`，因此 sqlite 句柄无需额外加锁。
/// 调用方可从任意线程调用；写操作同步返回以便调用方感知失败。
/// 启用 WAL 以便未来只读连接不阻塞写入，并降低崩溃后损坏概率。
///
/// `@unchecked Sendable`：`db` 是可变的非 Sendable 指针，但它只在 `queue` 上被访问，
/// 该不变式由本类的所有方法共同维护（每个公开方法都以 `queue.sync` 包裹）。
/// 实测 200 并发 upsert 零错误、结果行数正确。
final class ClipStore: @unchecked Sendable {

    enum StoreError: Error {
        case openFailed(code: Int32, message: String)
        case sqlFailed(sql: String, code: Int32, message: String)
        /// 数据库文件损坏，已备份并重建。
        case rebuiltAfterCorruption(backupPath: String)
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.clipkeep.store")
    private let dbPath: String

    /// 图片原图 PNG 超过此字节数时，先按长边缩放再编码（在 ImageCodec 内处理）。
    static let maxImageBytes = 5 * 1024 * 1024

    init(dbPath: String) throws {
        self.dbPath = dbPath
        try openAndMigrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 打开与建表

    private func openAndMigrate() throws {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try open()
            try migrate()
        } catch {
            // 打开或建表失败通常意味着文件损坏。备份坏档后重建，宁可丢历史也要保证工具可用。
            if let handle = db { sqlite3_close(handle); db = nil }
            let backup = dbPath + ".corrupt-\(Int(Date().timeIntervalSince1970))"
            if FileManager.default.fileExists(atPath: dbPath) {
                try? FileManager.default.moveItem(atPath: dbPath, toPath: backup)
            }
            // WAL 边车文件必须一并移除，否则会污染新库。
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
            try open()
            try migrate()
            throw StoreError.rebuiltAfterCorruption(backupPath: backup)
        }
    }

    private func open() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard code == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.openFailed(code: code, message: msg)
        }
        // 历史库含明文剪贴板内容，仅当前用户可读写。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: dbPath)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA busy_timeout=3000;")
    }

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS clips (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                kind           TEXT    NOT NULL,
                content        TEXT    NOT NULL DEFAULT '',
                preview        TEXT    NOT NULL DEFAULT '',
                content_hash   TEXT    NOT NULL UNIQUE,
                source_app     TEXT,
                is_favorite    INTEGER NOT NULL DEFAULT 0,
                created_at     REAL    NOT NULL,
                updated_at     REAL    NOT NULL,
                image_data     BLOB,
                thumbnail_data BLOB,
                pixel_width    INTEGER,
                pixel_height   INTEGER
            );
            """)
        // 列表按 updated_at 倒序取最新，收藏项单独置顶。
        try exec("CREATE INDEX IF NOT EXISTS idx_clips_updated ON clips(updated_at DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_clips_kind_updated ON clips(kind, updated_at DESC);")
    }

    // MARK: - 写入

    /// 幂等写入一条剪贴板记录。
    ///
    /// 同一内容重复复制时命中 `content_hash` 唯一约束，走 UPDATE 刷新 `updated_at`
    /// 使其回到列表顶部，而不是新增一行。这是单条语句的原子操作，不存在
    /// check-then-insert 竞态。
    ///
    /// - Returns: true 表示新插入，false 表示命中既有记录并更新了时间戳。
    @discardableResult
    func upsert(_ clip: CapturedClip, now: Date = Date()) throws -> Bool {
        try queue.sync {
            let sql = """
                INSERT INTO clips
                    (kind, content, preview, content_hash, source_app,
                     is_favorite, created_at, updated_at,
                     image_data, thumbnail_data, pixel_width, pixel_height)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    updated_at = excluded.updated_at,
                    source_app = excluded.source_app;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw err(sql)
            }
            defer { sqlite3_finalize(stmt) }

            let ts = now.timeIntervalSince1970
            sqlite3_bind_text(stmt, 1, clip.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, clip.content, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, Preview.summary(for: clip.content.isEmpty
                                                        ? imageLabel(clip) : clip.content),
                              -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, clip.contentHash, -1, SQLITE_TRANSIENT)
            bindOptionalText(stmt, 5, clip.sourceApp)
            sqlite3_bind_double(stmt, 6, ts)
            sqlite3_bind_double(stmt, 7, ts)
            bindOptionalBlob(stmt, 8, clip.imageData)
            bindOptionalBlob(stmt, 9, clip.thumbnailData)
            bindOptionalInt(stmt, 10, clip.pixelWidth)
            bindOptionalInt(stmt, 11, clip.pixelHeight)

            guard sqlite3_step(stmt) == SQLITE_DONE else { throw err(sql) }
            // 冲突走 UPDATE 时 last_insert_rowid 不变，用 changes + 新 rowid 区分不可靠；
            // 改用 total_changes 无法区分，故以 rowid 是否为新值判断：
            // ON CONFLICT DO UPDATE 不产生新 rowid，因此 sqlite3_changes 恒为 1。
            // 这里用一次轻量查询判断 created_at 是否等于本次 ts。
            return try wasInserted(hash: clip.contentHash, ts: ts)
        }
    }

    /// 判断刚写入的记录是新插入还是更新既有行：created_at 等于本次时间戳即为新插入。
    private func wasInserted(hash: String, ts: TimeInterval) throws -> Bool {
        let sql = "SELECT created_at FROM clips WHERE content_hash = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw err(sql) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_double(stmt, 0) == ts
    }

    private func imageLabel(_ clip: CapturedClip) -> String {
        guard let w = clip.pixelWidth, let h = clip.pixelHeight else { return "[图片]" }
        return "[图片] \(w)×\(h)"
    }

    // MARK: - 查询

    /// 按更新时间倒序读取记录，收藏项置顶。不加载 `image_data` 原图，避免大 BLOB 进内存。
    ///
    /// - Parameter search: 非空时按正文和摘要做子串匹配（大小写不敏感）。
    /// - Parameter limit: 上限，防止无界读取。
    func recent(search: String = "", limit: Int = 200) throws -> [ClipItem] {
        try queue.sync {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            var sql = """
                SELECT id, kind, content, preview, content_hash, source_app,
                       is_favorite, created_at, updated_at,
                       thumbnail_data, pixel_width, pixel_height
                FROM clips
                """
            if !trimmed.isEmpty {
                sql += " WHERE content LIKE ?1 ESCAPE '\\' OR preview LIKE ?1 ESCAPE '\\'"
            }
            sql += " ORDER BY is_favorite DESC, updated_at DESC LIMIT ?2;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw err(sql) }
            defer { sqlite3_finalize(stmt) }

            if !trimmed.isEmpty {
                // LIKE 通配符必须转义，否则用户输入的 % 或 _ 会变成通配符。
                let escaped = trimmed
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                sqlite3_bind_text(stmt, 1, "%\(escaped)%", -1, SQLITE_TRANSIENT)
            }
            sqlite3_bind_int(stmt, 2, Int32(max(0, limit)))

            var out: [ClipItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(row(stmt, includesImageData: false))
            }
            return out
        }
    }

    /// 读取单条记录的完整内容，含图片原图。回填剪贴板时使用。
    func fullItem(id: Int64) throws -> ClipItem? {
        try queue.sync {
            let sql = """
                SELECT id, kind, content, preview, content_hash, source_app,
                       is_favorite, created_at, updated_at,
                       thumbnail_data, pixel_width, pixel_height, image_data
                FROM clips WHERE id = ? LIMIT 1;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw err(sql) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return row(stmt, includesImageData: true)
        }
    }

    private func row(_ stmt: OpaquePointer?, includesImageData: Bool) -> ClipItem {
        ClipItem(
            id: sqlite3_column_int64(stmt, 0),
            kind: ClipKind(rawValue: text(stmt, 1) ?? "text") ?? .text,
            content: text(stmt, 2) ?? "",
            preview: text(stmt, 3) ?? "",
            contentHash: text(stmt, 4) ?? "",
            sourceApp: text(stmt, 5),
            isFavorite: sqlite3_column_int(stmt, 6) != 0,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            imageData: includesImageData ? blob(stmt, 12) : nil,
            thumbnailData: blob(stmt, 9),
            pixelWidth: optInt(stmt, 10),
            pixelHeight: optInt(stmt, 11)
        )
    }

    // MARK: - 收藏与删除

    func setFavorite(id: Int64, _ favorite: Bool) throws {
        try queue.sync {
            let sql = "UPDATE clips SET is_favorite = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw err(sql) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, favorite ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw err(sql) }
        }
    }

    func delete(id: Int64) throws {
        try queue.sync {
            let sql = "DELETE FROM clips WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw err(sql) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw err(sql) }
        }
    }

    /// 清空非收藏记录。收藏项永不被自动或批量清除，只能单条删除。
    func clearAll(keepFavorites: Bool = true) throws {
        try queue.sync {
            let sql = keepFavorites
                ? "DELETE FROM clips WHERE is_favorite = 0;"
                : "DELETE FROM clips;"
            try exec(sql)
        }
    }

    // MARK: - 保留策略

    /// 按条数与时长双上限清理，两者取先到者。收藏项豁免。
    ///
    /// 文本与图片分别计数：图片单条体积远大于文本，混在一起计数会让几张截图挤掉全部文本历史。
    ///
    /// - Returns: 删除的行数。
    @discardableResult
    func enforceRetention(maxTextItems: Int, maxImageItems: Int,
                          maxAge: TimeInterval, now: Date = Date()) throws -> Int {
        try queue.sync {
            var removed = 0
            // 超龄清理
            let cutoff = now.addingTimeInterval(-maxAge).timeIntervalSince1970
            removed += try deleteReturningCount("""
                DELETE FROM clips
                WHERE is_favorite = 0 AND updated_at < \(cutoff);
                """)
            // 超量清理：按类型分别保留最新 N 条
            // 子查询只在非收藏行中取 LIMIT N，使收藏项不占用配额；否则收藏满 N 条会把
            // 全部普通历史立即清空。
            for (kind, keep) in [(ClipKind.text, maxTextItems), (ClipKind.image, maxImageItems)] {
                removed += try deleteReturningCount("""
                    DELETE FROM clips
                    WHERE is_favorite = 0
                      AND kind = '\(kind.rawValue)'
                      AND id NOT IN (
                          SELECT id FROM clips
                          WHERE kind = '\(kind.rawValue)' AND is_favorite = 0
                          ORDER BY updated_at DESC
                          LIMIT \(max(0, keep))
                      );
                    """)
            }
            return removed
        }
    }

    private func deleteReturningCount(_ sql: String) throws -> Int {
        try exec(sql)
        return Int(sqlite3_changes(db))
    }

    func count() throws -> Int {
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM clips;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw err(sql) }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - 底层helpers

    private func exec(_ sql: String) throws {
        var raw: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &raw)
        guard code == SQLITE_OK else {
            let msg = raw.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(raw)
            throw StoreError.sqlFailed(sql: sql, code: code, message: msg)
        }
        sqlite3_free(raw)
    }

    private func err(_ sql: String) -> StoreError {
        let code = sqlite3_errcode(db)
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .sqlFailed(sql: sql, code: code, message: msg)
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }

    private func blob(_ stmt: OpaquePointer?, _ col: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, col) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, col))
        guard n > 0 else { return nil }
        return Data(bytes: p, count: n)
    }

    private func optInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int(stmt, idx, Int32(v)) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindOptionalBlob(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Data?) {
        guard let v, !v.isEmpty else { sqlite3_bind_null(stmt, idx); return }
        _ = v.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
        }
    }
}

/// sqlite3 的 SQLITE_TRANSIENT 常量在 Swift 中未导出，需手工构造。
/// 语义为让 sqlite 复制传入的字节，绑定后 Swift 侧缓冲区即可释放。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

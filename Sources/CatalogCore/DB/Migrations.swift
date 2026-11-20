import GRDB

extension Database {
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.eraseDatabaseOnSchemaChange = false
    migrator.registerMigration("v1_initial") { database in
      try database.execute(sql: Self.initialSchema)
    }
    // Favourites and Finder colour labels are catalog
    // data, never object-store data. Archiving needs nothing new: it is the
    // existing `asset.state`.
    migrator.registerMigration("v2_favorite_label") { database in
      try database.execute(sql: Self.favoriteLabelSchema)
    }
    // The durable deletion queue. A tombstone holds the whole deleted row
    // so it can be put back, and its (backend, key) so `reindex` never
    // resurrects it. Machine-local: not in backups.
    migrator.registerMigration("v3_pending_deletion") { database in
      try database.execute(sql: Self.pendingDeletionSchema)
    }
    // A project's object key template. NULL is
    // the default template, which renders the keys Pinax always has.
    migrator.registerMigration("v4_project_key_template") { database in
      try database.execute(sql: "ALTER TABLE project ADD COLUMN key_template TEXT")
    }
    // Rewrite and migration runs with their
    // structured events. Machine-local: not in backups, restore leaves them.
    migrator.registerMigration("v5_run") { database in
      try database.execute(sql: Self.runSchema)
    }
    return migrator
  }

  private static let runSchema = """
    CREATE TABLE run (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      backend_id INTEGER REFERENCES backend(id) ON DELETE SET NULL,
      state TEXT NOT NULL,
      dry_run INTEGER NOT NULL,
      from_run_id INTEGER REFERENCES run(id) ON DELETE SET NULL,
      pid INTEGER,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      params TEXT NOT NULL,
      summary TEXT
    );
    CREATE TABLE run_event (
      id INTEGER PRIMARY KEY,
      run_id INTEGER NOT NULL REFERENCES run(id) ON DELETE CASCADE,
      seq INTEGER NOT NULL,
      at TEXT NOT NULL,
      level TEXT NOT NULL,
      type TEXT NOT NULL,
      data TEXT NOT NULL
    );
    CREATE UNIQUE INDEX ux_run_event ON run_event(run_id, seq);
    CREATE INDEX ix_run_started ON run(started_at);
    """

  private static let pendingDeletionSchema = """
    CREATE TABLE pending_deletion (
      id INTEGER PRIMARY KEY,
      backend_id INTEGER NOT NULL REFERENCES backend(id),
      key TEXT NOT NULL,
      sha256 TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      keep_remote INTEGER NOT NULL DEFAULT 0 CHECK (keep_remote IN (0, 1)),
      phase TEXT NOT NULL DEFAULT 'staged'
        CHECK (phase IN ('staged', 'refused', 'delete_sent', 'kept')),
      snapshot TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      requested_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (backend_id, key)
    );
    """

  private static let favoriteLabelSchema = """
    ALTER TABLE asset ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX ix_asset_favorite ON asset(favorite) WHERE favorite = 1;

    CREATE TABLE asset_label (
      asset_id INTEGER NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
      label TEXT NOT NULL
        CHECK (label IN ('red', 'orange', 'yellow', 'green', 'blue', 'purple', 'gray')),
      PRIMARY KEY (asset_id, label)
    );
    CREATE INDEX ix_asset_label_label ON asset_label(label);
    """

  private static let initialSchema = """
    CREATE TABLE backend (
      id INTEGER PRIMARY KEY,
      slug TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL,
      endpoint TEXT NOT NULL,
      bucket TEXT NOT NULL,
      region TEXT NOT NULL DEFAULT 'auto',
      url_prefix TEXT NOT NULL,
      keychain_ref TEXT NOT NULL,
      meta TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE backend_prefix_history (
      id INTEGER PRIMARY KEY,
      backend_id INTEGER NOT NULL REFERENCES backend(id) ON DELETE CASCADE,
      url_prefix TEXT NOT NULL,
      retired_at TEXT NOT NULL
    );
    CREATE INDEX ix_prefix_hist_backend ON backend_prefix_history(backend_id);

    CREATE TABLE asset (
      id INTEGER PRIMARY KEY,
      sha256 TEXT NOT NULL,
      backend_id INTEGER NOT NULL REFERENCES backend(id),
      key TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      width INTEGER,
      height INTEGER,
      mime TEXT NOT NULL,
      orig_filename TEXT,
      state TEXT NOT NULL DEFAULT 'active',
      pinned INTEGER NOT NULL DEFAULT 0,
      note TEXT,
      meta TEXT NOT NULL DEFAULT '{}',
      uploaded_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE UNIQUE INDEX ux_asset_sha ON asset(backend_id, sha256);
    CREATE UNIQUE INDEX ux_asset_key ON asset(backend_id, key);
    CREATE INDEX ix_asset_state ON asset(state);

    CREATE TABLE project (
      id INTEGER PRIMARY KEY,
      slug TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      key_prefix TEXT NOT NULL DEFAULT '',
      backend_id INTEGER REFERENCES backend(id),
      last_scan_id INTEGER REFERENCES scan(id),
      note TEXT,
      meta TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE asset_project (
      asset_id INTEGER NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
      project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      added_at TEXT NOT NULL,
      PRIMARY KEY (asset_id, project_id)
    );
    CREATE INDEX ix_asset_project_project ON asset_project(project_id);

    CREATE TABLE tag (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE
    );

    CREATE TABLE asset_tag (
      asset_id INTEGER NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
      tag_id INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
      PRIMARY KEY (asset_id, tag_id)
    );

    CREATE TABLE scan (
      id INTEGER PRIMARY KEY,
      project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      source_rev TEXT,
      coverage TEXT NOT NULL DEFAULT '[]',
      found_count INTEGER
    );
    CREATE INDEX ix_scan_project ON scan(project_id, started_at);

    CREATE TABLE usage (
      id INTEGER PRIMARY KEY,
      project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      asset_id INTEGER REFERENCES asset(id) ON DELETE SET NULL,
      raw_url TEXT NOT NULL,
      source_ref TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'markdown',
      first_seen TEXT NOT NULL,
      last_seen TEXT NOT NULL,
      last_scan_id INTEGER REFERENCES scan(id)
    );
    CREATE UNIQUE INDEX ux_usage ON usage(project_id, source_ref, raw_url, kind);
    CREATE INDEX ix_usage_asset ON usage(asset_id);

    -- This view is a lower bound on live usage. It must never authorize destructive action.
    CREATE VIEW asset_live_usage AS
    SELECT u.asset_id, u.project_id, COUNT(*) AS n
    FROM usage u
    JOIN project p ON p.id = u.project_id
    WHERE u.asset_id IS NOT NULL
      AND u.last_scan_id IS NOT NULL
      AND u.last_scan_id = p.last_scan_id
    GROUP BY u.asset_id, u.project_id;
    """
}

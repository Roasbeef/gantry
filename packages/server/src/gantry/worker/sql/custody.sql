-- name: WorkerIdentity :many
SELECT worker FROM identity LIMIT 2;

-- name: RegisterWorker :exec
INSERT INTO identity(worker) VALUES (?);

-- name: PendingAttempts :many
SELECT name, assignment, receipt, started FROM attempts WHERE acknowledged = 0 LIMIT 2;

-- name: FindAttempt :many
SELECT name, assignment FROM attempts
WHERE CAST(json_extract(assignment, '$.lease.serial') AS INTEGER) = CAST(sqlc.arg(serial) AS INTEGER)
  AND CAST(json_extract(assignment, '$.run') AS TEXT) = CAST(sqlc.arg(run) AS TEXT)
  AND CAST(json_extract(assignment, '$.task.action.name') AS TEXT) = CAST(sqlc.arg(action) AS TEXT)
LIMIT 2;

-- name: InsertAttempt :exec
INSERT INTO attempts(name, assignment, started) VALUES (?, ?, 0);

-- name: ReopenAttempt :exec
UPDATE attempts SET acknowledged = 0 WHERE name = ?;

-- name: MarkStarted :exec
UPDATE attempts SET started = 1 WHERE name = ?;

-- name: SpoolBlob :exec
INSERT OR IGNORE INTO blobs(sha, data) VALUES (?, ?);

-- name: SaveReceipt :exec
UPDATE attempts SET receipt = ? WHERE name = ?;

-- name: PendingDigests :many
SELECT sha FROM blobs;

-- name: LoadBlob :many
SELECT data FROM blobs WHERE sha = ?;

-- name: AcknowledgeAttempt :exec
UPDATE attempts SET acknowledged = 1 WHERE name = ?;

-- name: ClearSpool :exec
DELETE FROM blobs;

-- name: WorkerIdentity :many
SELECT worker FROM identity LIMIT 2;

-- name: RegisterWorker :exec
INSERT INTO identity(worker) VALUES (?);

-- name: PendingAttempts :many
SELECT name, assignment, receipt, started FROM attempts LIMIT 2;

-- name: InsertAttempt :exec
INSERT INTO attempts(name, assignment, started) VALUES (?, ?, 0);

-- name: MarkStarted :exec
UPDATE attempts SET started = 1 WHERE name = ?;

-- name: SpoolBlob :exec
INSERT OR IGNORE INTO blobs(sha, data) VALUES (?, ?);

-- name: SaveReceipt :exec
UPDATE attempts SET receipt = ? WHERE name = ?;

-- name: LoadBlob :many
SELECT data FROM blobs WHERE sha = ?;

-- name: DeleteAttempt :exec
DELETE FROM attempts WHERE name = ?;

-- name: DeleteAcknowledgedAttempts :exec
DELETE FROM attempts WHERE acknowledged = 1;

-- name: ClearSpool :exec
DELETE FROM blobs;

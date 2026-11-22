#!/usr/bin/env node
// Linux controller benchmark. Start isolated voters and send real worker-protocol traffic.
import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const launcher = process.argv.slice(2)
assert(launcher.length, 'usage: node scripts/bench-controller.mjs CONTROLLER [ARGS...]')

function setting(name, fallback, max) {
  const value = Number(process.env[name] ?? fallback)
  assert(Number.isInteger(value) && value > 0 && value <= max, name)
  return value
}

const runs = setting('GANTRY_BENCH_RUNS', 32, 512)
const workers = setting('GANTRY_BENCH_WORKERS', 4, 32)
const polls = setting('GANTRY_BENCH_POLLS', 120, 10000)
const voters = setting('GANTRY_BENCH_VOTERS', 1, 3)
const port = setting('GANTRY_BENCH_PORT', 18972, 65533)
const schedulers = setting('GANTRY_BENCH_SCHEDULERS', 2, 32)
assert(voters === 1 || voters === 3, 'use one or three voters')

const root = mkdtempSync(join(tmpdir(), 'gantry-bench-'))
const nodes = []
const token = randomBytes(24).toString('hex')
const workerToken = randomBytes(24).toString('hex')
const submitToken = randomBytes(24).toString('hex')
const cookie = randomBytes(20).toString('hex')
const nodeName = (i) => `gantry_bench_${process.pid}_${i}@127.0.0.1`
const origin = (i) => `http://127.0.0.1:${port + i}`
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex')
const image = 'alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f'
const artifact = 'report.txt'
const expected = 'fixture output\n'
const expectedLog = 'fixture log\n'
const action = { name: 'short', argv: ['sh', '-ec', "printf '%s\\n' 'fixture output' > report.txt; printf '%s\\n' 'fixture log'"], inputs: [], outputs: [artifact], timeout: 10 }
const contention = JSON.stringify({ error: 'queue contention exceeded retry budget' })
let contentionRetries = 0

async function git(...args) {
  return (await exec('git', args, { cwd: root })).stdout.trim()
}

async function request(node, path, { method = 'GET', authorization = token, data, bytes } = {}) {
  const headers = { authorization: `Bearer ${authorization}` }
  const body = bytes ?? (data === undefined ? undefined : JSON.stringify(data))
  if (data !== undefined) headers['content-type'] = 'application/json'
  for (let attempt = 0; ; attempt++) {
    const response = await fetch(origin(node) + path, { method, headers, body, signal: AbortSignal.timeout(30_000) })
    const result = Buffer.from(await response.arrayBuffer())
    // Only the explicit CAS contention reply proves the operation never committed.
    if (attempt < 4 && response.status === 503 && result.toString() === contention) {
      contentionRetries++
      await sleep(2 ** attempt)
      continue
    }
    assert(response.ok, `${method} ${path}: ${response.status} ${result}`)
    return result
  }
}

async function post(node, path, data, authorization) {
  const result = await request(node, path, { method: 'POST', authorization, data })
  return result.length ? JSON.parse(result) : null
}

async function startNode(i) {
  const config = join(root, `node-${i}.toml`)
  const log = join(root, `node-${i}.log`)
  writeFileSync(config, `data_dir = "${root}/data-${i}"
blob_dir = "${root}/blobs"
port = ${port + i}
seed = "${i === 0 ? '' : nodeName(0)}"

[[repository]]
name = "fixture/project"
local_remote = "${root}/remote.git"
branch = "main"
target = "check"
pool = "default"
image = "${image}"
`)
  const fd = openSync(log, 'w')
  const controller = spawn(launcher[0], launcher.slice(1), {
    stdio: ['ignore', fd, fd],
    env: {
      ...process.env,
      ERL_FLAGS: `+S ${schedulers}:${schedulers} -name ${nodeName(i)} -setcookie ${cookie}`,
      GANTRY_CONFIG: config, GANTRY_TOKEN: token, GANTRY_WORKER_TOKEN: workerToken, GANTRY_SUBMIT_TOKEN: submitToken,
    },
  })
  closeSync(fd)
  nodes.push(controller)
  let spawnError
  controller.once('error', (error) => { spawnError = error })
  const deadline = performance.now() + 20_000
  while (performance.now() < deadline) {
    if (spawnError) throw spawnError
    assert(controller.exitCode === null, readFileSync(log, 'utf8'))
    try {
      const health = JSON.parse(await request(i, '/health'))
      if (health.status === 'ok') return
    } catch {
      await sleep(100)
    }
  }
  assert.fail(`controller ${i} health timed out: ${readFileSync(log, 'utf8')}`)
}

function usage() {
  let ticks = 0
  let rssKiB = 0
  for (const node of nodes) {
    const stat = readFileSync(`/proc/${node.pid}/stat`, 'utf8')
    const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ')
    ticks += Number(fields[11]) + Number(fields[12])
    const status = readFileSync(`/proc/${node.pid}/status`, 'utf8')
    rssKiB += Number(status.match(/^VmRSS:\s+(\d+) kB$/m)?.[1])
    assert.equal(status.match(/^Name:\s+(\S+)$/m)?.[1], 'beam.smp', 'launcher must exec BEAM')
  }
  assert(Number.isFinite(ticks) && Number.isFinite(rssKiB))
  return { ticks, rssKiB }
}

function quantile(sorted, fraction) {
  return sorted[Math.ceil(sorted.length * fraction) - 1]
}

const clockTicks = Number((await exec('getconf', ['CLK_TCK'])).stdout)
async function measure(id, parallel, workload) {
  const before = usage()
  const retriesBefore = contentionRetries
  let peakRssKiB = before.rssKiB
  const samplingFailure = Promise.withResolvers()
  const timer = setInterval(() => {
    try {
      peakRssKiB = Math.max(peakRssKiB, usage().rssKiB)
    } catch (error) {
      samplingFailure.reject(error)
    }
  }, 25)
  const start = performance.now()
  try {
    const latencies = (await Promise.race([workload(), samplingFailure.promise])).sort((a, b) => a - b)
    const wallMs = performance.now() - start
    const after = usage()
    const cpuMs = (after.ticks - before.ticks) * 1000 / clockTicks
    return {
      id, parallel, voters, schedulers, runs, count: latencies.length, wallMs,
      throughput: latencies.length * 1000 / wallMs, p50Ms: quantile(latencies, 0.5), p95Ms: quantile(latencies, 0.95),
      cpuMs, cpuPercent: 100 * cpuMs / wallMs, cpuMsPerOp: cpuMs / latencies.length,
      peakRssKiB: Math.max(peakRssKiB, after.rssKiB), startRssKiB: before.rssKiB,
      contentionRetries: contentionRetries - retriesBefore,
    }
  } finally {
    clearInterval(timer)
  }
}

async function runLanes(count, lanes, transfer) {
  let cursor = 0
  return (await Promise.all(Array.from({ length: lanes }, async (_, lane) => {
    const durations = []
    while (cursor < count) {
      const index = cursor++
      const start = performance.now()
      await transfer(index, lane)
      durations.push(performance.now() - start)
    }
    return durations
  }))).flat()
}

async function stage(node, bytes) {
  const id = digest(bytes)
  const response = await request(node, `/v1/blobs/${id}`, { method: 'PUT', authorization: workerToken, bytes })
  assert.equal(JSON.parse(response).digest, id)
  return id
}

async function benchmark() {
  await git('init', '-q', '--bare', '--initial-branch=main', 'remote.git')
  await git('init', '-q', '--initial-branch=main', 'fixture')
  writeFileSync(join(root, 'fixture', 'README'), 'Pinned Gantry load fixture\n')
  await git('-C', 'fixture', 'add', '.')
  await git('-C', 'fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'user.name=Fixture', 'commit', '-qm', 'fixture')
  await git('-C', 'fixture', 'push', '-q', join(root, 'remote.git'), 'HEAD:refs/heads/main')
  const revision = await git('-C', 'fixture', 'rev-parse', 'HEAD')
  for (let i = 0; i < voters; i++) await startNode(i)
  usage()
  const workDirs = Array.from({ length: workers }, (_, lane) => {
    const dir = join(root, `work-${lane}`)
    mkdirSync(dir)
    return dir
  })

  const runId = (index) => `build-${index}`
  const enrollment = await measure('enrollment', workers, () => runLanes(runs, workers, async (index, lane) => {
    const id = runId(index)
    const enrolled = await post(lane % voters, '/v1/runs', { id, repo: 'fixture/project', revision, target: 'check', action })
    assert.equal(enrolled.id, id)
    assert.equal(enrolled.revision, revision)
    assert.equal(enrolled.work.length, 1)
  }))

  const claimed = new Set()
  const queue = await measure('queue-drain', workers, () => runLanes(runs, workers, async (_, lane) => {
    const worker = `worker-${lane}`
    const node = lane % voters
    const offer = await post(node, '/v1/claims', { worker, pool: 'default' }, workerToken)
    assert(offer, 'pending action was not claimed')
    assert(!claimed.has(offer.run), `duplicate claim for ${offer.run}`)
    claimed.add(offer.run)
    assert.equal(offer.lease.worker, worker)
    assert.deepEqual(offer.task.action.argv, action.argv)
    const source = await request(node, `/v1/blobs/${offer.task.source}`, { authorization: workerToken })
    assert.equal(digest(source), offer.task.source)
    const { stdout } = await exec(offer.task.action.argv[0], offer.task.action.argv.slice(1), { cwd: workDirs[lane] })
    const output = readFileSync(join(workDirs[lane], artifact))
    assert.equal(output.toString(), expected)
    assert.equal(stdout, expectedLog)
    const files = [{ path: artifact, digest: await stage(node, output) }]
    const logId = await stage(node, Buffer.from(stdout))
    const finished = await post(node, '/v1/results', {
      run: offer.run, action: offer.task.action.name, worker, serial: offer.lease.serial,
      completion: { kind: 'succeeded', files, log: logId },
    }, workerToken)
    assert.equal(finished.accepted, true)
  }))

  const polling = await measure('empty-polls', workers, () => runLanes(polls, workers, async (_, lane) => {
    assert.equal(await post(lane % voters, '/v1/claims', { worker: `worker-${lane}`, pool: 'default' }, workerToken), null)
  }))

  // Check durable evidence independently of the timed worker result.
  for (let i = 0; i < runs; i++) {
    const run = JSON.parse(await request(i % voters, `/v1/runs/${runId(i)}`))
    assert.equal(run.phase, 'passed')
    assert.equal(run.work.length, 1)
    assert.equal(run.work[0].step.kind, 'passed')
    assert.deepEqual(run.work[0].step.proof.files, [{ path: artifact, digest: digest(expected) }])
    assert.equal(run.work[0].step.proof.log, digest(expectedLog))
  }
  const output = await request(0, `/v1/blobs/${digest(expected)}`)
  assert.equal(output.toString(), expected)
  for (const result of [enrollment, queue, polling]) process.stdout.write(JSON.stringify(result) + '\n')
}

let passed = false
try {
  await benchmark()
  passed = true
} finally {
  for (const node of nodes) node.kill()
  await Promise.all(nodes.map(async (node) => {
    if (node.pid && node.exitCode === null && node.signalCode === null) {
      await new Promise((resolve) => node.once('exit', resolve))
    }
  }))
  if (passed) rmSync(root, { recursive: true, force: true })
  else process.stderr.write(`Retained benchmark files in ${root}\n`)
}

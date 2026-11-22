import { writeFileSync } from 'node:fs'
import { createServer, request } from 'node:http'

const [port, origin, directory] = process.argv.slice(2)
let dropped = false
let replayed = false

// Forward the receipt and wait for the controller to accept it before
// withholding the response. The worker still owns its local spool.
const server = createServer(async (incoming, outgoing) => {
  try {
    const resultRequest = incoming.method === 'POST' && incoming.url === '/v1/results'
    const chunks = []
    if (resultRequest) {
      for await (const chunk of incoming) chunks.push(chunk)
    }
    const body = Buffer.concat(chunks)
    const fault = resultRequest && JSON.parse(body).run === 'lost-ack'
    if (replayed && incoming.method === 'POST' && incoming.url === '/v1/claims') {
      writeFileSync(directory + '/poll-after-replay', '')
    }

    const upstream = request(origin + incoming.url, {
      method: incoming.method,
      headers: incoming.headers,
    }, async (reply) => {
      try {
        if (fault) {
          const parts = []
          for await (const chunk of reply) parts.push(chunk)
          const response = Buffer.concat(parts)
          if (!dropped && reply.statusCode === 200 && JSON.parse(response).accepted) {
            dropped = true
            writeFileSync(directory + '/committed-receipt.json', body)
            return
          }
          if (dropped && reply.statusCode === 409 &&
              JSON.parse(response).error === 'attempt is no longer active') {
            writeFileSync(directory + '/replayed-receipt.json', body)
            replayed = true
          }
          outgoing.writeHead(reply.statusCode, reply.headers).end(response)
        } else {
          reply.pipe(outgoing.writeHead(reply.statusCode, reply.headers))
        }
      } catch (error) {
        outgoing.destroy(error)
      }
    })
    upstream.on('error', () => outgoing.destroy())
    if (resultRequest) upstream.end(body)
    else incoming.pipe(upstream)
  } catch (error) {
    outgoing.destroy(error)
  }
})

server.listen(Number(port), '127.0.0.1')

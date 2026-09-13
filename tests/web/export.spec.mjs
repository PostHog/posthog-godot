import { test, expect } from '@playwright/test'

const api = 'http://127.0.0.1:47836'
let nextCommand = 0
const runtimeErrors = new WeakMap()

async function command(page, name, data = {}) {
  const id = ++nextCommand
  await page.evaluate(
    ({ id, name, data }) =>
      window.posthogTestCommand(id, name, JSON.stringify(data)),
    { id, name, data },
  )
  await page.waitForFunction(
    (id) => Object.hasOwn(window.posthogTestResults ?? {}, id),
    id,
  )
  return page.evaluate((id) => window.posthogTestResults[id], id)
}

async function open(page, variant = 'stack-on') {
  await page.goto(`/${variant}/index.html`)
  await page.waitForFunction(() => window.posthogTestReady === true)
}

async function ledger(request) {
  return (await request.get(`${api}/__requests`)).json()
}

function events(requests) {
  return requests
    .filter((item) => item.method === 'POST' && item.path.endsWith('/batch/'))
    .flatMap((item) => item.body.batch)
}

async function diskFiles(page, filename) {
  return page.evaluate(async (filename) => {
    const files = []
    for (const info of await indexedDB.databases()) {
      if (!info.name.startsWith('/userfs')) continue
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open(info.name)
        request.onsuccess = () => resolve(request.result)
        request.onerror = () => reject(request.error)
      })
      try {
        if (!db.objectStoreNames.contains('FILE_DATA')) continue
        await new Promise((resolve, reject) => {
          const transaction = db.transaction('FILE_DATA', 'readonly')
          const request = transaction.objectStore('FILE_DATA').openCursor()
          request.onsuccess = () => {
            const cursor = request.result
            if (!cursor) return
            if (
              String(cursor.key).endsWith(`/${filename}`) &&
              cursor.value.contents
            ) {
              files.push(
                JSON.parse(new TextDecoder().decode(cursor.value.contents)),
              )
            }
            cursor.continue()
          }
          transaction.oncomplete = resolve
          transaction.onerror = () => reject(transaction.error)
        })
      } finally {
        db.close()
      }
    }
    return files
  }, filename)
}

test.beforeEach(async ({ request, page }) => {
  const errors = []
  runtimeErrors.set(page, errors)
  page.on('pageerror', (error) => errors.push(error.message))
  page.on('console', (message) => {
    if (/SCRIPT ERROR:|Parse Error:/.test(message.text()))
      errors.push(message.text())
  })
  await request.get(`${api}/__reset`)
})

test.afterEach(async ({ page }) => {
  expect(runtimeErrors.get(page)).toEqual([])
})

test('release autoload sends analytics and flags through real CORS preflight', async ({
  page,
  request,
}) => {
  await open(page)
  expect(await command(page, 'snapshot')).toMatchObject({
    initialized: true,
    editor: false,
    debug: false,
    persistent: true,
  })
  await command(page, 'capture', {
    event: 'browser_delivered',
    properties: { unicode: 'Hedgehog 🦔' },
  })
  expect(await command(page, 'flush')).toEqual({ success: true })
  expect(await command(page, 'flags')).toEqual({
    success: true,
    value: 'browser',
  })
  const requests = await ledger(request)
  expect(
    requests.some(
      (item) =>
        item.method === 'OPTIONS' &&
        item.headers.origin === 'http://127.0.0.1:47835',
    ),
  ).toBe(true)
  expect(events(requests)).toHaveLength(1)
  expect(events(requests)[0]).toMatchObject({
    event: 'browser_delivered',
    properties: {
      unicode: 'Hedgehog 🦔',
      $lib: 'posthog-godot',
      $godot_environment: 'export_release',
    },
  })
  const flags = requests.find(
    (item) => item.method === 'POST' && item.path.includes('/flags/'),
  )
  expect(flags.body.distinct_id).toBe(events(requests)[0].distinct_id)
  expect(flags.body.person_properties.$godot_environment).toBe('export_release')
})

test('identity, super properties, and unsent event UUIDs survive reload', async ({
  page,
  request,
}) => {
  await open(page)
  const initial = await command(page, 'snapshot')
  await command(page, 'register', { key: 'level', value: 7 })
  const captured = await command(page, 'capture', {
    event: 'persisted_browser_event',
  })
  const id = captured.events[0].uuid
  await expect
    .poll(async () => (await diskFiles(page, `${id}.json`)).length)
    .toBe(1)
  await page.reload()
  await page.waitForFunction(() => window.posthogTestReady === true)
  const restored = await command(page, 'snapshot')
  expect(restored.distinct_id).toBe(initial.distinct_id)
  expect(restored.events).toHaveLength(1)
  expect(restored.events[0]).toMatchObject({
    uuid: id,
    event: 'persisted_browser_event',
    properties: { level: 7 },
  })
  expect(await command(page, 'flush')).toEqual({ success: true })
  expect(events(await ledger(request))[0].uuid).toBe(id)
  await expect
    .poll(async () => (await diskFiles(page, `${id}.json`)).length)
    .toBe(0)
  await page.reload()
  await page.waitForFunction(() => window.posthogTestReady === true)
  expect((await command(page, 'snapshot')).events).toEqual([])
})

test('opt-out and opt-in persist across reloads without sending discarded events', async ({
  page,
  request,
}) => {
  await open(page)
  await command(page, 'identify', { id: 'browser-player' })
  const captured = await command(page, 'capture', { event: 'must_not_send' })
  await command(page, 'opt_out')
  await expect
    .poll(async () =>
      (await diskFiles(page, 'state.json')).some(
        (state) => state.data.opted_out === true,
      ),
    )
    .toBe(true)
  for (const event of captured.events) {
    await expect
      .poll(async () => (await diskFiles(page, `${event.uuid}.json`)).length)
      .toBe(0)
  }
  await page.reload()
  await page.waitForFunction(() => window.posthogTestReady === true)
  expect(await command(page, 'snapshot')).toMatchObject({
    opted_out: true,
    distinct_id: 'browser-player',
    events: [],
  })
  await command(page, 'capture', { event: 'also_must_not_send' })
  expect(await command(page, 'flush')).toEqual({ success: false })
  expect(await command(page, 'flags')).toEqual({ success: false, value: null })
  expect(await ledger(request)).toEqual([])
  await command(page, 'opt_in')
  await expect
    .poll(async () =>
      (await diskFiles(page, 'state.json')).some(
        (state) => state.data.opted_out === false,
      ),
    )
    .toBe(true)
  await page.reload()
  await page.waitForFunction(() => window.posthogTestReady === true)
  expect((await command(page, 'snapshot')).opted_out).toBe(false)
  await command(page, 'capture', { event: 'after_consent' })
  expect(await command(page, 'flush')).toEqual({ success: true })
  expect(events(await ledger(request)).map((event) => event.event)).toEqual([
    'after_consent',
  ])
})

test('browser blocks ingestion without CORS permission and retains the queue', async ({
  page,
  request,
}) => {
  await open(page)
  await command(page, 'setup', { host: `${api}/denied` })
  await command(page, 'capture', { event: 'cors_blocked' })
  expect(await command(page, 'flush')).toEqual({ success: false })
  expect((await command(page, 'snapshot')).events).toHaveLength(1)
  const requests = await ledger(request)
  expect(
    requests.some(
      (item) => item.method === 'OPTIONS' && item.path === '/denied/batch/',
    ),
  ).toBe(true)
  expect(requests.some((item) => item.method === 'POST')).toBe(false)
})

for (const enabled of [true, false]) {
  test(`release error stacktraces with tracking ${enabled ? 'enabled' : 'disabled'}`, async ({
    page,
    request,
  }) => {
    await open(page, enabled ? 'stack-on' : 'stack-off')
    expect((await command(page, 'snapshot')).debug).toBe(false)
    expect(await command(page, 'error')).toEqual({ success: true })
    const [error] = events(await ledger(request))
    expect(error).toMatchObject({
      event: '$exception',
      properties: {
        $exception_message: 'Expected export error',
        $godot_environment: 'export_release',
      },
    })
    const frames = error.properties.$exception_list[0].stacktrace.frames
    for (const frame of frames) {
      expect(frame).toMatchObject({ platform: 'custom', lang: 'godot', resolved: true })
    }
    const scriptFrames = frames.filter(
      (frame) => frame.filename === 'res://main.gd',
    )
    expect(scriptFrames.length > 0).toBe(enabled)
    if (enabled)
      expect(
        scriptFrames.some(
          (frame) => frame.function === '_export_error' && frame.lineno > 0,
        ),
      ).toBe(true)
  })
}

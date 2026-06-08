# rpc-tree contract

`rpc-tree` is a backend contract for RPC clients that want to navigate Pi's session tree without depending on the interactive TUI `/tree` UI.

## Command

```text
/rpc-tree [--all]
/rpc-tree --id <entry-id-or-unique-prefix> [--summary|--no-summary] [--custom <instructions>] [--replace-instructions] [--label <label>]
/rpc-tree <entry-id-or-unique-prefix>
/rpc-tree --help
```

## Terminal event invariant

Every non-help `/rpc-tree` invocation emits exactly one terminal machine-readable notification:

```text
rpc-tree:event <json>
```

The JSON object always includes:

```json
{
  "version": 1,
  "kind": "navigated | cancelled | error | noop",
  "phase": "parse | preflight | ui | picker | summary | navigation"
}
```

`oldLeafId` and `newLeafId` are included when known. `newLeafId` may be `null`; that means Pi's current leaf is the root.

`/rpc-tree --help` is intentionally human-only and does not emit a terminal event.

## Event kinds

### navigated

Navigation succeeded and Pi's session leaf is now `newLeafId`.

```json
{
  "version": 1,
  "kind": "navigated",
  "phase": "navigation",
  "targetId": "81743d07",
  "targetType": "message",
  "oldLeafId": "72594b08",
  "newLeafId": "81743d07",
  "summarize": false,
  "summarized": false,
  "editorTextRestored": true
}
```

If `--summary` produced a branch summary, `summaryEntryId` is present and `summarized` is true.

### cancelled

The user or client cancelled a picker, summary choice, or Pi navigation flow.

```json
{
  "version": 1,
  "kind": "cancelled",
  "phase": "picker",
  "oldLeafId": "72594b08",
  "newLeafId": "72594b08",
  "message": "No RPC UI response or tree selection cancelled. Use /rpc-tree --id <entry-id>."
}
```

### error

The command or navigation failed.

```json
{
  "version": 1,
  "kind": "error",
  "phase": "parse",
  "oldLeafId": "72594b08",
  "newLeafId": "72594b08",
  "message": "--id requires a value"
}
```

```json
{
  "version": 1,
  "kind": "error",
  "phase": "preflight",
  "targetId": "notfound",
  "oldLeafId": "72594b08",
  "newLeafId": "72594b08",
  "summarize": false,
  "message": "No unique tree entry matches: notfound"
}
```

### noop

The command completed without navigation because no change was needed.

```json
{
  "version": 1,
  "kind": "noop",
  "phase": "picker",
  "targetId": "72594b08",
  "oldLeafId": "72594b08",
  "newLeafId": "72594b08",
  "message": "Already at this point"
}
```

## Phases

| Phase | Meaning |
| --- | --- |
| `parse` | Argument parsing failed. |
| `preflight` | The command was valid but session state or target resolution failed. |
| `ui` | A fallback UI was required but unavailable. |
| `picker` | The fallback picker failed, cancelled, or no-oped. |
| `summary` | The fallback summary prompt was cancelled. |
| `navigation` | Pi's `ctx.navigateTree()` was attempted and succeeded, cancelled, or threw. |

## Client guidance

- Treat `rpc-tree:event` as authoritative.
- Do not treat the RPC `prompt` response success as navigation success. It only means the slash command was accepted/handled.
- Use `newLeafId`, not `targetId`, as the post-navigation leaf.
- Preserve `newLeafId: null`; it means root, not unknown.
- Human companion notifications may follow the event. Clients may suppress them.

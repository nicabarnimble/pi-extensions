# rpc-tree

`rpc-tree` is a Pi extension that exposes session-tree navigation as an RPC-friendly backend contract.

It intentionally does **not** replace Pi's built-in TUI `/tree` product. Instead it registers a separate command:

```text
/rpc-tree
```

Rich clients such as Emacs can render their own tree UI, send `/rpc-tree --id <entry-id>`, and consume structured `rpc-tree:event` notifications to learn the authoritative navigation result.

## Install

From the collection repo:

```bash
pi install git:github.com/nicabarnimble/pi-extensions@v0.1.1
```

Load only this extension via package filtering:

```json
{
  "packages": [
    {
      "source": "git:github.com/nicabarnimble/pi-extensions@v0.1.1",
      "extensions": ["rpc-tree/index.ts"],
      "skills": [],
      "prompts": [],
      "themes": []
    }
  ]
}
```

Local development:

```bash
pi install /path/to/pi-extensions/rpc-tree
# or temporary:
pi --extension /path/to/pi-extensions/rpc-tree/index.ts
```

Do not keep another active copy at `~/.pi/agent/extensions/rpc-tree.ts` while this package is installed.

## Usage

```text
/rpc-tree --help
/rpc-tree --id <entry-id>
/rpc-tree --id <entry-id> --summary
/rpc-tree --id <entry-id> --no-summary
/rpc-tree --id <entry-id> --label <label>
/rpc-tree --all
```

With no `--id`, the extension shows a simple fallback picker for RPC clients that support extension UI. This fallback is intentionally dumb; full product UI should live in the client.

## Event contract

All non-help invocations emit a terminal machine event via notification:

```text
rpc-tree:event {"version":1,"kind":"navigated",...}
```

See [CONTRACT.md](./CONTRACT.md) for the full schema and examples.

## Emacs client

A rich Emacs client lives at:

```text
clients/emacs/pi-rpc-tree.el
```

It renders the session JSONL as a visual tree and uses `/rpc-tree` only as the navigation backend.

Doom/straight install:

```elisp
(package! pi-rpc-tree
  :recipe (:host github
           :repo "nicabarnimble/pi-extensions"
           :files ("rpc-tree/clients/emacs/pi-rpc-tree.el")))
```

Then load it from config:

```elisp
(require 'pi-rpc-tree)
(global-set-key (kbd "C-c p t") #'pi-rpc-tree-open)
```

## Test

From the repository root:

```bash
npm test
```

From this directory:

```bash
python3 tests/smoke-rpc-tree.py
emacs --batch -Q -l clients/emacs/pi-rpc-tree.el --eval '(message "pi-rpc-tree.el loads")'
```

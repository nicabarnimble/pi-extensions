# Emacs client for rpc-tree

`pi-rpc-tree.el` is the first-class Emacs client for the `/rpc-tree` Pi extension.

It is not loaded by Pi. It is loaded by Emacs and controls an active Pi RPC session by:

- reading the active Pi session JSONL
- rendering a native Emacs tree buffer
- sending `/rpc-tree --id ...` for navigation
- consuming `rpc-tree:event ...` notifications as the authoritative outcome

## Doom install

Add to `~/.config/doom/packages.el`:

```elisp
(package! pi-rpc-tree
  :recipe (:host github
           :repo "nicabarnimble/pi-extensions"
           :files ("rpc-tree/clients/emacs/pi-rpc-tree.el")))
```

Run:

```bash
doom sync
```

Load from your Doom config:

```elisp
(require 'pi-rpc-tree)
```

Bind wherever you prefer, for example:

```elisp
(map! :leader :desc "pi tree" "o t" #'pi-rpc-tree-open)
```

## Runtime requirement

The Pi process you are controlling must have the `rpc-tree` extension installed and loaded. Check with:

```text
/rpc-tree --help
```

## Notes

This client uses Pi's Emacs RPC integration functions from `pi-coding-agent.el`. It is intended as a reusable client for Doom/Emacs users, while the TypeScript extension remains the universal RPC navigation backend.

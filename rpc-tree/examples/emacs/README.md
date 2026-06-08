# Emacs example for rpc-tree

`pi-rpc-tree.el` is a rich Emacs client for the `/rpc-tree` Pi extension.

It is not loaded by Pi. It is an optional RPC client integration that:

- reads the active Pi session JSONL
- renders a native Emacs tree buffer
- sends `/rpc-tree --id ...` for navigation
- consumes `rpc-tree:event ...` notifications as the authoritative outcome

## Load

```elisp
(load-file "/path/to/pi-extensions/rpc-tree/examples/emacs/pi-rpc-tree.el")
(global-set-key (kbd "C-c p t") #'pi-rpc-tree-open)
```

For Doom Emacs, load the file from your private config and bind `pi-rpc-tree-open` in your preferred leader map.

## Runtime requirement

The Pi process you are controlling must have the `rpc-tree` extension installed and loaded. Check with:

```text
/rpc-tree --help
```

## Notes

This example uses Pi's internal Emacs RPC functions from `pi-coding-agent.el`, so it is intentionally an example/client rather than a stable ELPA package.

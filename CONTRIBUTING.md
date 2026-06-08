# Contributing

This is a small Pi extension collection. Contributions should keep the same shape:

- each extension is a standalone directory with its own `package.json`
- each extension documents its command/tool contract
- examples are optional clients, not required runtime files
- tests should be runnable without private local configuration

Before sending changes, run:

```bash
npm test
```

If you add a new extension, update the root `README.md` and root `package.json` `pi.extensions` list only when the extension is ready to be installed as part of the full collection.

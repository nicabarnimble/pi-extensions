# Pi Extensions

A public collection of Pi coding-agent extensions by [NicabarNimble](https://github.com/nicabarnimble).

This repository is a monorepo: each extension can stand alone, while the root package can install the whole collection.

> Security: Pi extensions run with your full local permissions. Review source before installing any extension package.

## Extensions

| Extension | Status | Description |
| --- | --- | --- |
| [`rpc-tree`](./rpc-tree) | beta | RPC session-tree navigation backend plus a first-class Emacs client. |

## Install the whole collection

Pinned tag install:

```bash
pi install git:github.com/nicabarnimble/pi-extensions@v0.1.2
```

Development branch install:

```bash
pi install git:github.com/nicabarnimble/pi-extensions@main
```

Local checkout install:

```bash
pi install /path/to/pi-extensions
```

## Install only one extension from the collection

Pi package filters let you install the monorepo but load only the resources you want. Add an object package entry to `~/.pi/agent/settings.json` or `.pi/settings.json`:

```json
{
  "packages": [
    {
      "source": "git:github.com/nicabarnimble/pi-extensions@v0.1.2",
      "extensions": ["rpc-tree/index.ts"],
      "skills": [],
      "prompts": [],
      "themes": []
    }
  ]
}
```

For local development of one extension:

```bash
pi install /path/to/pi-extensions/rpc-tree
```

The root package and each extension directory are intentionally valid Pi packages.

## Repository layout

```text
.
├── package.json              # collection Pi package
├── rpc-tree/
│   ├── package.json          # standalone rpc-tree Pi package
│   ├── index.ts              # extension entrypoint
│   ├── CONTRACT.md           # machine-readable event contract
│   ├── README.md
│   ├── clients/
│   │   └── emacs/
│   │       └── pi-rpc-tree.el
│   └── tests/
│       └── smoke-rpc-tree.py
└── README.md
```

## Development

Run the smoke tests:

```bash
npm test
```

Try a local extension without installing it:

```bash
pi --extension ./rpc-tree/index.ts
```

If you install this package, do not keep another active copy of the same extension in `~/.pi/agent/extensions/`, or Pi may register duplicate slash commands such as `/rpc-tree` and `/rpc-tree:1`.

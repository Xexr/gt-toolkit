# gt-toolkit

A collection of formulas, configurations, workflow documents, and other useful resources for [Gas Town](https://github.com/steveyegge/gastown).

## What's here

| Directory | Contents |
|-----------|----------|
| `formulas/` | `.formula.toml` files — spec pipeline and plan writing formulas for `gt sling`. Includes wrapper formulas required until [beads#1903](https://github.com/steveyegge/beads/pull/1903) lands. See [formulas/README.md](formulas/README.md) for details. |
| `configs/` | Example configuration files and templates |
| `docs/` | Workflow guides, tips, and reference material |

## Installing formulas

Copy any formula files you want into your town-level formulas directory:

```bash
cp formulas/*.formula.toml ~/gt/.beads/formulas/
```

Or for a single formula:

```bash
cp formulas/my-formula.formula.toml ~/gt/.beads/formulas/
```

Town-level formulas (`~/gt/.beads/formulas/`) are available across all rigs. Alternatively, copy to a specific rig's `.beads/formulas/` directory for project-scoped use.

## Contributing

Issues and PRs welcome. If you have a formula or workflow that's been useful, feel free to share it.

## License

MIT

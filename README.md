<!--- This file is synced from hanakai-rb/repo-sync -->

[actions]: https://github.com/dry-rb/dry-transformer/actions
[chat]: https://discord.gg/naQApPAsZB
[forum]: https://discourse.hanakai.org
[rubygem]: https://rubygems.org/gems/dry-transformer

# dry-transformer [![Gem Version](https://badge.fury.io/rb/dry-transformer.svg)][rubygem] [![CI Status](https://github.com/dry-rb/dry-transformer/workflows/CI/badge.svg)][actions]

[![Forum](https://img.shields.io/badge/Forum-dc360f?logo=discourse&logoColor=white)][forum]
[![Chat](https://img.shields.io/badge/Chat-717cf8?logo=discord&logoColor=white)][chat]

## Links

- [User documentation](https://dry-rb.org/gems/dry-transformer)
- [API documentation](http://rubydoc.info/gems/dry-transformer)
- [Forum](https://discourse.dry-rb.org)

## Incremental sessions

Use `Pipe#incremental_session` with stable row IDs to maintain a previous
result and receive `inserted`, `updated`, and `deleted` deltas for insert,
update, and delete events.

Supported declarative steps are `map_array`, `filter_array`/`filter`,
`rename_keys`, `group`, and retractable `aggregate` count/sums. A `Proc`
cannot be safely updated incrementally and raises
`Dry::Transformer::Incremental::UnsupportedTransformationError`.

## License

See `LICENSE` file.

# Swift/libtorrent transfer comparison

[Owned upload wire buffers](wire-groups-results-2026-11-12.md) reduce seeding
CPU 2.2–4.3%, but the first version raises concurrent download peak RSS 1.5%
[0.8–7.4%]. This form is disqualified by the no-cost requirement; a revision
must remove that regression before the change can be retained.

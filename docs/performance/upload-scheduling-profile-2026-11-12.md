# Upload scheduling profile before grouped workers

Production `1d414f9`, evidence revision `b22b213`, is profiled in Release for
single-file v1 seeding with the pinned native counterpart. Both engines pass
the independent digest and saved-state reopening checks. These two instrumented
trials are diagnostic only and do not replace timing acceptance.

Time Profiler attaches to the tested process while both roles are ready; the
Instruments notification gates transfer start. Capture stops after durable
completion. Exports retain Running samples for that PID, including unavailable
backtrace weights. The native counterpart is not instrumented; its raw phase
CPU remains separately available. Source/build/machine/fixture hashes and XML
exports are in [`raw/upload-groups-baseline-profile`](raw/upload-groups-baseline-profile).

Swift has 3,202 running samples. Upload task work is 11.1% inclusive,
`buildUpload` 9.5%, global task enqueue 5.7%, request admission 4.2%, and shared
cache access 2.4%. Inclusive weights overlap and must not be added. Flat SHA1
is 13.6%, worker-thread startup 13.0%, Mach messages 7.2%, worker-thread return
5.4%, copying 5.2%, send 4.4% and read 3.0%. These are sampled costs, not a
guarantee that removing a task saves its entire inclusive weight.

Native has 1,636 running samples. Its leading flat costs are mutex wait 20.2%,
read 14.7%, send 14.3%, mutex drop 10.8%, condition wait 8.4% and kevent 5.5%.
Raw phase CPU through durable completion is Swift 1.900 user/1.359 system
seconds and native 0.375 user/1.389 system seconds for the 1 GiB fixture.
Kernel waits attributed to a Running sample are preserved, not relabelled as
idle time. Instruments overhead makes these durations unsuitable as ordinary
benchmark samples.

The next experiment groups pending blocks for one peer/piece into one payload
worker, retaining the existing per-block tokens, queue/resource bounds and
independent cancellation. It must flush available work without waiting for a
full group, and must not share cancellation of one peer's load with another.

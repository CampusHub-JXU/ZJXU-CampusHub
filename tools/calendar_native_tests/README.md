# Calendar native channel host tests

`python tools/calendar_native_tests/run.py` compiles the production
`CalendarSyncChannelHandler.kt` with small Android / Flutter API stubs and an
in-memory provider-store stub. It runs on the host JVM and never installs an
APK or touches a device.

The tests exercise actual handler calls through a serial background task queue:
registration, provider thread affinity and ordering, permission request
handoff/reentrant completion, and error mapping. This harness is a focused
handler test; it does not validate Android Calendar Provider behavior.

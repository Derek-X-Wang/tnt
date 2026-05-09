// Memory Store: durable user state (preferences, corrections, agents,
// session_events, vocabulary). Server-future side of the Future Server
// Boundary — v0 ships `protocol MemoryStore` + `SQLiteMemoryStore` at
// `~/.tnt/memory.sqlite`; v1 adds `RemoteMemoryStore`. See docs/adr/0003.

public enum TNTMemoryModule {}

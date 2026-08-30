import Config

config :attesto_mcp_server,
  protocol_versions: ["2026-07-28", "2025-11-25", "2025-06-18"],
  max_json_bytes: 2_000_000,
  max_concurrency: 64,
  per_principal_concurrency: 16,
  request_timeout: 30_000,
  max_request_timeout: 120_000,
  cursor_ttl: 300_000,
  session_idle_timeout: 1_800_000,
  session_absolute_timeout: 86_400_000,
  stream_keepalive_ms: 15_000,
  stream_queue_size: 128

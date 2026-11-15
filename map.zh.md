# 视频大纲（19:42:46，24 集）

按章节切好的地图。`起`/`止` 直接喂给 `tools/lecture.sh`。

优先级：**先看** > 必看 > 选看 > 按需（按需 = 跟着敲代码时才看）

| 集 | 起 | 时长 | 优先级 | 主题 | 分支 |
|---|---|---|---|---|---|
| 1 | 0:00:00 | 36 分 | 选看 | Build a Production-Grade Payments Backend | `ep01` |
| 2 | 0:36:29 | 41 分 | 必看 | Designing a Double-Entry Ledger | `ep02` |
| 3 | 1:17:49 | 47 分 | 按需 | Type-Safe SQL with sqlc + pgx | `ep03` |
| 4 | 2:05:17 | 49 分 | 按需 | Config, Logging & Errors | `ep04` |
| 5 | 2:55:15 | 45 分 | 按需 | The Wallet API | `ep05` |
| 6 | 3:41:13 | 46 分 | 必看 | Moving Money Safely | `ep06` |
| 7 | 4:27:23 | 47 分 | 必看 | Idempotency Keys | `ep07` |
| 8 | 5:15:08 | 53 分 | 按需 | The Auth Service | `ep08` |
| 9 | 6:08:47 | 52 分 | 按需 | gRPC Between Services | `ep09` |
| 10 | 7:01:26 | 53 分 | 按需 | The API Gateway | `ep10` |
| 11 | 7:54:50 | 50 分 | 先看 | Events with NATS JetStream | `ep11` |
| 12 | 8:45:12 | 57 分 | 必看 | Transfer Service & Sagas | `ep12` |
| 13 | 9:43:02 | 48 分 | 必看 | Notification Service | `ep13` |
| 14 | 10:31:32 | 54 分 | 选看 | Observability | `ep14` |
| 15 | 11:25:37 | 48 分 | 按需 | Testing Like a Pro | `ep15` |
| 16 | 12:13:44 | 47 分 | 按需 | Shipping It | `ep16` |
| 17 | 13:00:54 | 52 分 | 选看 | Outbound Webhooks | `ep17` |
| 18 | 13:53:37 | 52 分 | 必看 | Multi-currency & FX | `ep18` |
| 19 | 14:45:53 | 53 分 | 选看 | Fraud & Risk Checks | `ep19` |
| 20 | 15:39:43 | 50 分 | 必看 | Reconciliation & Reporting | `ep20` |
| 21 | 16:30:03 | 54 分 | 必看 | Security Hardening | `ep21` |
| 22 | 17:24:50 | 49 分 | 选看 | Performance | `ep22` |
| 23 | 18:13:52 | 45 分 | 按需 | Kubernetes | `ep23` |
| 24 | 18:59:46 | 43 分 | 选看 | Chaos & the Final Demo | `ep24` |

## 各集小节目录

### 1. Build a Production-Grade Payments Backend  `0:00:00 – 0:36:29` （36 分）

- `:00:24` — The finished system
- `:11:09` — Why Go, why microservices
- `:19:49` — Local infrastructure
- `:27:32` — Graceful shutdown

### 2. Designing a Double-Entry Ledger  `0:36:29 – 1:17:49` （41 分）

- `:52:53` — Accounts
- `:01:27` — Append-only & derived balances
- `:08:34` — Trying to break it

### 3. Type-Safe SQL with sqlc + pgx  `1:17:49 – 2:05:17` （47 分）

- `:19:18` — Why sqlc
- `:35:14` — pgx and connection pooling
- `:46:14` — Atomic transactions
- `:56:12` — Integration tests

### 4. Config, Logging & Errors  `2:05:17 – 2:55:15` （49 分）

- `:09:02` — Configuration
- `:17:59` — Request IDs
- `:26:41` — Errors and JSON
- `:36:49` — Unit tests
- `:43:49` — Wiring up the wallet

### 5. The Wallet API  `2:55:15 – 3:41:13` （45 分）

- `:02:32` — Where deposits come from
- `:12:27` — The service layer
- `:22:12` — HTTP handlers
- `:33:14` — Handler tests

### 6. Moving Money Safely  `3:41:13 – 4:27:23` （46 分）

- `:48:22` — A naive transfer
- `:01:47` — Deadlocks
- `:09:20` — Retries with jitter

### 7. Idempotency Keys  `4:27:23 – 5:15:08` （47 分）

- `:31:59` — The idempotency key pattern
- `:43:19` — Claiming a key
- `:55:01` — Redis as a fast path
- `:01:35` — Tests
- `:08:50` — Live demo

### 8. The Auth Service  `5:15:08 – 6:08:47` （53 分）

- `:23:52` — Hashing passwords
- `:30:28` — Signing keys and JWTs
- `:46:37` — Refresh token rotation
- `:01:33` — Live demo

### 9. gRPC Between Services  `6:08:47 – 7:01:26` （52 分）

- `:14:36` — The contract
- `:24:39` — Interceptors
- `:32:49` — The wallet speaks gRPC
- `:52:41` — Live demo with grpcurl

### 10. The API Gateway  `7:01:26 – 7:54:50` （53 分）

- `:04:41` — Wallets that belong to someone
- `:23:03` — JSON in, gRPC out
- `:34:51` — CORS, limits and timeouts
- `:46:34` — Live demo in the REST Client

### 11. Events with NATS JetStream  `7:54:50 – 8:45:12` （50 分）

- `:57:32` — NATS and JetStream
- `:11:05` — The transactional outbox
- `:22:22` — The relay
- `:36:25` — Tests on real NATS and Postgres

### 12. Transfer Service & Sagas  `8:45:12 – 9:43:02` （57 分）

- `:49:57` — Holds in the wallet
- `:01:38` — The transfer service's database
- `:08:58` — Storing transfers
- `:15:58` — The orchestrator
- `:22:23` — The transfer API
- `:29:19` — Live: transfers through the gateway
- `:35:39` — Testing the saga

### 13. Notification Service  `9:43:02 – 10:31:32` （48 分）

- `:51:33` — Messages, senders and addresses
- `0:02:10` — Retries and dead letters
- `0:13:39` — Live: real emails
- `0:23:27` — Testing the consumer

### 14. Observability  `10:31:32 – 11:25:37` （54 分）

- `0:46:04` — HTTP, gRPC and logs
- `0:53:10` — Across the async hops
- `1:05:05` — Wiring every service
- `1:12:53` — Live: metrics and dashboards

### 15. Testing Like a Pro  `11:25:37 – 12:13:44` （48 分）

- `1:37:14` — Every package on its own containers
- `1:52:11` — The race detector
- `2:02:00` — Load testing with k6

### 16. Shipping It  `12:13:44 – 13:00:54` （47 分）

- `2:15:42` — Liveness and readiness
- `2:24:40` — Wiring the services
- `2:35:34` — A multi-stage Dockerfile
- `2:41:47` — GitHub Actions
- `2:48:45` — The whole system, in Compose

### 17. Outbound Webhooks  `13:00:54 – 13:53:37` （52 分）

- `3:15:46` — Endpoints, and SSRF
- `3:25:32` — The delivery worker
- `3:37:09` — Wiring the service
- `3:44:35` — Webhooks, live

### 18. Multi-currency & FX  `13:53:37 – 14:45:53` （52 分）

- `3:54:36` — Why FX is hard
- `4:08:46` — Table tests for money
- `4:23:13` — Posting a conversion
- `4:37:14` — Converting, live

### 19. Fraud & Risk Checks  `14:45:53 – 15:39:43` （53 分）

- `5:00:53` — Testing the rules
- `5:11:00` — Screening in the saga
- `5:18:55` — The review API
- `5:27:20` — Risk checks, live

### 20. Reconciliation & Reporting  `15:39:43 – 16:30:03` （50 分）

- `5:48:21` — Leader election
- `5:56:27` — Reconciling the ledger
- `6:05:28` — Statements as CSV
- `6:19:17` — Reports, live

### 21. Security Hardening  `16:30:03 – 17:24:50` （54 分）

- `6:37:50` — mTLS in Go
- `6:45:20` — Wiring it in
- `6:53:04` — Least-privilege database roles
- `7:05:15` — An audit log
- `7:17:11` — Attacking our own system

### 22. Performance  `17:24:50 – 18:13:52` （49 分）

- `7:25:44` — A load test that tells the truth
- `7:34:56` — pprof on live services
- `7:47:21` — Postgres: the right index
- `7:59:45` — Connection pools

### 23. Kubernetes  `18:13:52 – 18:59:46` （45 分）

- `8:17:23` — A cluster on this laptop
- `8:27:12` — One Helm chart, six services
- `8:50:29` — Autoscaling

### 24. Chaos & the Final Demo  `18:59:46 – 19:42:46` （43 分）

- `9:08:30` — A steady stream of transfers
- `9:16:16` — Faults on demand
- `9:23:23` — From watching to proving
- `9:42:46` — What we did

